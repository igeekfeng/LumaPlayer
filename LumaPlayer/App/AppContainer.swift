import Foundation

/// 组合根:装配 CredentialStore / ServerRegistry / AppState,
/// 并承载跨视图的服务器管理动作(添加 / 切换 / 编辑 / 删除 / 会话恢复)。
///
/// View 与 ViewModel 不直接拼 URL、不直接碰凭据存储
/// (ARCHITECTURE.md 6.3 架构约束)。
@MainActor
final class AppContainer {
    let credentials: CredentialStore
    let registry: ServerRegistry
    let state = AppState()
    /// 接口响应缓存:所有服务器共用一个实例,按 serverID 隔离。
    /// 注入给每台服务器的 `ServerConnection`,登录重建连接后缓存仍有效。
    let responseCache = EmbyResponseCache()
    /// 「同一部剧沿用同一个倍速」的内存记录(`PlaybackSpeedStore`)。
    /// 放在组合根上是刻意的:换视频 / 换集都会新建播放页的状态对象,
    /// 记在那里面跨不过去;而记在这里就恰好是「本次运行」的寿命。
    let playbackSpeeds = PlaybackSpeedStore()
    /// 字幕外观偏好(`SubtitleStyleStore`,UserDefaults 持久化)。设置窗口改、播放窗口读,
    /// 必须是同一个实例,播放中改设置才能即时生效。
    let subtitleStyles: SubtitleStyleStore
    /// 播放偏好(`PlaybackPreferences`,UserDefaults 持久化):起播默认值与播放期开关。
    /// 与字幕外观同样的理由必须是同一个实例 —— 设置里改了步长 / 默认倍速,
    /// 下一次起播就要用上。
    let preferences: PlaybackPreferences
    /// 所有服务器连接共用的 URLSession。测试注入 `MockEmbyURLProtocol` 的会话
    private let session: URLSession

    init(
        registry: ServerRegistry,
        credentials: CredentialStore,
        session: URLSession = .shared,
        preferences: UserDefaults = .standard
    ) {
        self.registry = registry
        self.credentials = credentials
        self.session = session
        self.subtitleStyles = SubtitleStyleStore(defaults: preferences)
        self.preferences = PlaybackPreferences(defaults: preferences)
    }

    /// 生产组装:沙盒容器里的凭据文件 + UserDefaults(.standard)。
    /// 服务器列表损坏时不静默吞掉:按空列表降级启动,
    /// 并把 `AppError.serverListCorrupted` 挂到 state 由 RootView 提示
    /// (不允许静默 try? 吞错)。
    convenience init() {
        // 测试跑在宿主 App 进程里、共享真实沙盒容器(见 NetworkDiagnostics 同名判断)。
        // 宿主用一次性的临时文件、不做钥匙串导入:否则每跑一次测试都弹一轮授权窗,
        // 而且宿主里生成的 DeviceId 一旦写进真实文件,会压过钥匙串里那个旧值。
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let storage = isTestHost
            ? CredentialFileStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appending(path: "LumaPlayer-testhost-\(UUID().uuidString)", directoryHint: .isDirectory)
                    .appending(path: "credentials.json", directoryHint: .notDirectory)
            )
            : CredentialFileStore(
                fileURL: CredentialFileStore.defaultFileURL,
                legacyImport: CredentialStore.legacyKeychainImport()
            )
        let credentials = CredentialStore(storage: storage)
        var startupError: AppError?
        let registry: ServerRegistry
        do {
            registry = try ServerRegistry(credentials: credentials)
        } catch {
            startupError = .serverListCorrupted
            registry = ServerRegistry(profiles: [], credentials: credentials)
        }
        self.init(registry: registry, credentials: credentials)
        state.startupError = startupError
    }

    // MARK: - 服务器连接

    /// 一台服务器一个连接实例、一个 `EmbyAPIClient`,token 不共享
    /// (ARCHITECTURE.md 6.3)。
    func makeConnection(
        for profile: ServerProfile,
        schemeWasInferred: Bool = false
    ) -> ServerConnection {
        ServerConnection(
            profile: profile,
            credentials: credentials,
            schemeWasInferred: schemeWasInferred,
            session: session,
            responseCache: responseCache
        )
    }

    /// 这台服务器能否免输入进入:本地有 token,或记住了密码。false = 需要用户重新登录。
    func canResumeSession(for server: ServerProfile) async throws -> Bool {
        try await makeConnection(for: server).canAuthenticateWithoutPrompt()
    }

    // MARK: - 浏览用连接与图片缓存

    /// 浏览用的连接实例按服务器缓存:`ServerConnection` 持有该服务器的
    /// token 与 `/emby` 前缀状态,浏览期间必须复用同一个实例
    /// (ARCHITECTURE.md 6.3:每台服务器一个 `EmbyAPIClient`,token 不共享)。
    ///
    /// 登录 / 探测仍是 `makeConnection` 新建 —— 那条路径要带
    /// `schemeWasInferred`,且失败就不该留下半成品状态。
    private var connections: [UUID: ServerConnection] = [:]

    func connection(for server: ServerProfile) -> ServerConnection {
        if let existing = connections[server.id] { return existing }
        let fresh = makeConnection(for: server)
        connections[server.id] = fresh
        return fresh
    }

    func profile(id: UUID) async -> ServerProfile? {
        await registry.all().first { $0.id == id }
    }

    /// 海报图片的内存 + 磁盘缓存与加载器(图片请求带认证头,见 `PosterImageStore`)。
    private(set) lazy var posters = PosterImageStore(
        loader: PosterImageLoader(container: self),
        disk: PosterDiskCache()
    )

    /// 手动刷新(工具栏「刷新」按钮)时作废这台服务器的接口缓存:
    /// 用户按刷新就是要最新数据,不吃 TTL 内的缓存
    /// (浏览路径仍吃缓存,只有显式刷新走这里,见 docs/DECISIONS/local-cache.md)。
    func invalidateResponses(for server: ServerProfile) async {
        await responseCache.invalidate(serverID: server.id)
    }

    /// 已有服务器重新登录(token 失效或未登录)。保留地址与用户名
    /// (ARCHITECTURE.md 7.3)。
    func login(
        to server: ServerProfile,
        username: String,
        password: String,
        rememberPassword: Bool = false
    ) async throws -> ServerProfile {
        let result = try await makeConnection(for: server).login(
            username: username,
            password: password,
            rememberPassword: rememberPassword
        )
        try await registry.update(result.profile)
        // 缓存的浏览连接还拿着旧档案 / 旧 token 状态,换一个新的
        connections.removeValue(forKey: result.profile.id)
        if state.currentServer?.id == result.profile.id {
            state.currentServer = result.profile
        }
        state.serverNeedingLogin = nil
        return result.profile
    }

    /// 登出:远程吊销 + 清本地 token;档案保留(地址与用户名还在)。
    func logout(of server: ServerProfile) async throws {
        try await makeConnection(for: server).logout()
    }

    // MARK: - 服务器管理动作

    /// 添加服务器:地址规范化 → 探测 → 登录 → **成功后才入库**
    /// (ARCHITECTURE.md 6.2 的顺序)。
    ///
    /// 登录失败不落库:否则会留下一条「存在但用不了」的服务器。
    /// 抛 ServerURLError / ServerLoginError / EmbyAPIError / CredentialFileError / KeychainError /
    /// ServerRegistryError,由调用方转成用户文案。
    func addServer(
        address: String,
        displayName: String,
        username: String,
        password: String,
        rememberPassword: Bool = false
    ) async throws -> ServerProfile {
        let normalized = try normalizeServerURL(address)
        let deviceID = try await credentials.deviceID()
        let pending = ServerProfile(
            displayName: resolvedName(displayName, for: normalized.url),
            baseURL: normalized.url,
            deviceID: deviceID,
            lastUsedAt: Date()
        )
        let connection = makeConnection(for: pending, schemeWasInferred: normalized.schemeWasInferred)
        let result = try await connection.login(
            username: username,
            password: password,
            rememberPassword: rememberPassword
        )
        var profile = result.profile
        if isBlank(displayName), let serverName = result.compatibility.serverName, !isBlank(serverName) {
            // 用户没填名称:用服务器自报的 ServerName(探测时 /System/Info/Public 已拿到),
            // 比主机名好认;服务器没报名称才退回主机名
            profile.displayName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if Task.isCancelled {
            // 用户在登录完成的瞬间点了取消:不入库,也不留下孤立凭证
            try? await connection.logout()
            throw CancellationError()
        }
        try await registry.add(profile)
        state.serverListRevision += 1
        state.currentServer = profile
        state.serverNeedingLogin = nil
        state.route = .browse
        return profile
    }

    // MARK: - 播放

    /// 请播放器窗口播放 `item`。窗口由调用方(视图)用 `openWindow` 唤起 ——
    /// 这里只写请求,不碰 AppKit。正在播别的内容时,旧播放页随请求替换而
    /// 拆除,收尾上报照常发出(ARCHITECTURE.md 6.6)。
    func play(_ item: EmbyItem, on server: ServerProfile, fromBeginning: Bool = false) {
        state.nowPlaying = PlaybackRequest(server: server, item: item, startFromBeginning: fromBeginning)
    }

    /// 结束属于 `serverID` 的播放(切换 / 删除服务器时)。
    /// UI_DESIGN.md 7.1:正在播放时切服务器,先结束旧播放会话再切换 ——
    /// 否则播放器窗口里还是上一台的内容,上报也继续打到上一台。
    private func stopPlayback(unlessOn serverID: UUID) {
        guard let playing = state.nowPlaying, playing.server.id != serverID else { return }
        state.nowPlaying = nil
    }

    /// 切换当前服务器。切换时清除当前服务器的临时内容与播放器状态
    /// (ARCHITECTURE.md 7.3)。
    func switchCurrent(to server: ServerProfile) async throws {
        stopPlayback(unlessOn: server.id)
        try await registry.markUsed(id: server.id, at: Date())
        // 回读库内现值:传进来的 server 可能是列表视图的旧快照,
        // 直接赋值会让 currentServer 的 lastUsedAt 停在切换之前
        state.currentServer = await registry.all().first { $0.id == server.id } ?? server
    }

    /// 编辑服务器(显示名 / 地址)。地址变了就先重新探测:`/emby` 前缀与局域网
    /// http 回退都跟着地址走(API_CONTRACT.md 1.4),直接存会留下一个用不了的地址
    /// (例如不写 scheme 的局域网地址被补成 https)。探测不通就抛错、不保存。
    /// 只改名称时不发任何请求。
    ///
    /// 抛 ServerURLError / ServerLoginError / ServerRegistryError。
    func editServer(_ server: ServerProfile, displayName: String, address: String) async throws {
        let normalized = try normalizeServerURL(address)
        var updated = server
        updated.displayName = displayName
        if normalized.url != server.baseURL {
            var candidate = updated
            candidate.baseURL = normalized.url
            let probe = try await makeConnection(
                for: candidate,
                schemeWasInferred: normalized.schemeWasInferred
            ).probeServer()
            updated.baseURL = probe.baseURL
            updated.apiPathPrefix = probe.compatibility.apiPathPrefix
            updated.serverVersion = probe.compatibility.serverVersion
            updated.compatibility = probe.compatibility
            if let probedID = probe.serverID {
                if let oldID = server.serverID, oldID != probedID {
                    // 新地址是另一台 Emby:缓存 key 不含 host(同一台内外网切换要复用),
                    // 旧服务器的列表不能端给新地址
                    await responseCache.invalidate(serverID: server.id)
                }
                updated.serverID = probedID
            }
        }
        try await updateServer(updated)
    }

    /// 保存档案。若是当前服务器,同步刷新 currentServer。
    func updateServer(_ profile: ServerProfile) async throws {
        try await registry.update(profile)
        state.serverListRevision += 1
        // 缓存的浏览连接还拿着旧地址 / 旧前缀,换一个新的(否则要重启 App 才生效)
        connections.removeValue(forKey: profile.id)
        if state.currentServer?.id == profile.id {
            // 同上:update 是合并式的,库内结果未必等于传入值(lastUsedAt 被保留)
            state.currentServer = await registry.all().first { $0.id == profile.id } ?? profile
        }
    }

    /// 删除服务器(含其本地 token);若删的是当前服务器,
    /// 切到剩余里最近使用的一台;一台不剩则回引导页。
    func removeServer(id: UUID) async throws {
        if state.nowPlaying?.server.id == id {
            state.nowPlaying = nil
        }
        try await registry.remove(id: id)
        state.serverListRevision += 1
        // 连接实例跟着服务器一起走:留着会持有一个已不存在的服务器的 token 状态
        connections.removeValue(forKey: id)
        // 本地缓存也一起走:接口响应与图片磁盘目录都不留在盘上
        await responseCache.invalidate(serverID: id)
        await posters.purgeDisk(serverID: id)
        if state.currentServer?.id == id {
            state.currentServer = await registry.mostRecentlyUsed()
        }
        if await registry.all().isEmpty {
            state.route = .onboarding
        }
    }

    // MARK: - 会话恢复

    /// 启动时恢复最近一次使用的服务器
    /// (ARCHITECTURE.md 4.1「重新启动后自动恢复最近一次可用会话」;
    /// 7.3「token 无效时返回登录界面,但保留地址和用户名」)。
    ///
    /// 有服务器就直接进主窗口的首页;
    /// 缺 token 时由 `BrowseView` 的登录 sheet 兜住(不静默重登,ARCHITECTURE.md 7.3)。
    ///
    /// 这里**不发网络请求**:只判断本地有没有 token。token 是否仍然有效
    /// 由第一次鉴权请求决定,401 时回登录页(API_CONTRACT.md 2.5)。
    func restoreSession() async {
        guard !state.didRestoreSession else { return }
        state.didRestoreSession = true
        guard let recent = await registry.mostRecentlyUsed() else {
            state.route = .onboarding
            return
        }
        state.currentServer = recent
        state.route = .browse
        do {
            if try await !canResumeSession(for: recent) {
                state.serverNeedingLogin = recent
            }
        } catch is KeychainError {
            // 首次访问凭据时才做旧版钥匙串导入,这里是它最早被触发的地方
            state.startupError = .credentialMigrationFailed
        } catch {
            // 读不到就不知道要不要登录 —— 如实挂到 state 上,不静默放过
            state.startupError = .credentialReadFailed
        }
    }

    // MARK: - 私有

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 显示名留空时的临时名称 host[:port]。登录成功后若服务器报了 ServerName,
    /// `addServer` 会改用它
    private func resolvedName(_ displayName: String, for url: URL) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        guard let host = url.host() else {
            return url.absoluteString
        }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}
