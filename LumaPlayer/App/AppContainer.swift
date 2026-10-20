import Foundation

/// 组合根:装配 CredentialStore / ServerRegistry / AppState,
/// 并承载跨视图的服务器管理动作(添加 / 切换 / 编辑 / 删除 / 会话恢复)。
///
/// View 与 ViewModel 不直接拼 URL、不直接碰凭据存储
/// (CLAUDE.md「架构主线」)。
@MainActor
final class AppContainer {
    let credentials: CredentialStore
    let registry: ServerRegistry
    let state = AppState()
    /// 接口响应缓存:所有服务器共用一个实例,按 serverID 隔离。
    /// 注入给每台服务器的 `ServerConnection`,登录重建连接后缓存仍有效。
    let responseCache = EmbyResponseCache()
    /// 「同一部剧沿用同一个倍速」的内存记录(`PlaybackSpeedStore`)。
    /// 放在组合根上是刻意的:换视频 / 换集都会新建 `PlayerViewModel`,
    /// 记在 ViewModel 里跨不过去;而记在这里就恰好是「本次运行」的寿命。
    let playbackSpeeds = PlaybackSpeedStore()
    /// 本地续播库。**百度来源用它**:百度没有播放进度上报接口
    /// (`docs/BAIDU_PAN_API.md`),进度只能记在本地;Emby 来源仍然上报到服务端。
    let watchProgress: WatchProgressStore
    /// 本地「隐藏条目」库:用户不想再看到、但**网盘上还留着**的条目。
    /// 与 `watchProgress` 同一套做法(JSON 文件,不用服务端),因为百度没有这类标记接口。
    let hiddenItems: HiddenItemsStore
    /// 本地「手动片头 / 片尾」库:服务端检测不出片头片尾时用户自己标的。
    /// 与 `hiddenItems` 同一套做法(JSON 文件)—— Emby 没有写回章节标记的接口,
    /// 只能记在本地。键是「同一部剧」的范围键(见 `ManualMarkersScope`)。
    let manualMarkers: ManualMarkersStore
    /// 百度网盘来源的连接。与 `ServerProfile` 无关 —— 一个 App 只对应开放平台
    /// 上的一个应用、一个授权,所以它是**全 App 一份**(不像 `connections` 按服务器分)。
    private var baiduConnectionInstance: BaiduPanConnection?
    /// 字幕外观偏好(`SubtitleStyleStore`,UserDefaults 持久化)。设置窗口改、播放窗口读,
    /// 必须是同一个实例,播放中改设置才能即时生效。
    let subtitleStyles: SubtitleStyleStore
    /// 播放偏好(`PlaybackPreferences`,UserDefaults 持久化):起播默认值与播放期开关。
    /// 与字幕外观同样的理由必须是同一个实例 —— 设置里改了步长 / 默认倍速,
    /// 下一次起播就要用上。
    let preferences: PlaybackPreferences
    /// 首页外观偏好(`HomeAppearancePreferences`,UserDefaults):要不要显示顶部 hero 推荐。
    /// 设置窗口改、首页读,必须是同一个实例,改完回到首页立即生效。
    let homeAppearance: HomeAppearancePreferences
    /// 弹幕外观偏好(`DanmakuSettingsStore`,UserDefaults)。理由同 `subtitleStyles`:
    /// 设置窗口与播放窗口必须共用同一个实例。
    let danmakuSettings: DanmakuSettingsStore
    /// 弹幕编排(弹弹play)。**全 App 一份**:它带作品剧集列表的进程内记忆,
    /// 绑定库 / 弹幕缓存也只该有一个写入方。凭据在用时向 `credentials` 取 —— 设置页刚填就生效。
    let danmaku: DanmakuService
    /// 所有服务器连接共用的 URLSession。测试注入 `MockEmbyURLProtocol` 的会话。
    ///
    /// 非 private:弹幕指纹(`PlayerViewModel.mediaFingerprint`)要对直连流补一次
    /// `Range` 请求,必须走**同一个**会话 —— 测试里换掉它,那条请求才不会真的发出去。
    let session: URLSession

    init(
        registry: ServerRegistry,
        credentials: CredentialStore,
        session: URLSession = .shared,
        preferences: UserDefaults = .standard,
        watchProgress: WatchProgressStore? = nil,
        hiddenItems: HiddenItemsStore? = nil,
        manualMarkers: ManualMarkersStore? = nil,
        danmaku: DanmakuService? = nil
    ) {
        self.registry = registry
        self.credentials = credentials
        self.session = session
        self.subtitleStyles = SubtitleStyleStore(defaults: preferences)
        self.preferences = PlaybackPreferences(defaults: preferences)
        self.homeAppearance = HomeAppearancePreferences(defaults: preferences)
        self.watchProgress = watchProgress
            ?? WatchProgressStore(fileURL: WatchProgressStore.defaultFileURL)
        self.hiddenItems = hiddenItems
            ?? HiddenItemsStore(fileURL: HiddenItemsStore.defaultFileURL)
        self.manualMarkers = manualMarkers
            ?? ManualMarkersStore(fileURL: ManualMarkersStore.defaultFileURL)
        self.danmakuSettings = DanmakuSettingsStore(defaults: preferences)
        self.danmaku = danmaku ?? DanmakuService(
            credentials: credentials,
            bindings: DanmakuBindingStore(fileURL: DanmakuBindingStore.defaultFileURL),
            cache: DanmakuCommentCache(directory: DanmakuCommentCache.defaultDirectory))
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

    // MARK: - 来源(来源无关)

    /// 全部来源(Emby / 百度网盘 / …)。来源列表与工具栏切换菜单用它。
    func sources() async -> [SourceProfile] {
        await registry.allSources()
    }

    func source(id: UUID) async -> SourceProfile? {
        await registry.allSources().first { $0.id == id }
    }

    /// 百度网盘连接(全 App 一份,见属性注释)。
    func baiduConnection() -> BaiduPanConnection {
        if let existing = baiduConnectionInstance { return existing }
        let fresh = BaiduPanConnection(credentials: credentials)
        baiduConnectionInstance = fresh
        return fresh
    }

    /// 在线刮削(TMDB)。**全 App 一份**是刻意的:`BaiduPanMetadataScraper` 带一层
    /// 「问过的标题」缓存,每次列目录都新建一个就等于每次都重新问一遍 TMDB。
    /// token 由它自己在用时向 `credentials` 取 —— 设置页刚填的 token 立刻生效。
    private var metadataScraperInstance: BaiduPanMetadataScraper?

    func metadataScraper() -> BaiduPanMetadataScraper {
        if let existing = metadataScraperInstance { return existing }
        let fresh = BaiduPanMetadataScraper(credentials: credentials)
        metadataScraperInstance = fresh
        return fresh
    }

    /// 添加一个百度网盘来源:先存配置 → 再落库。
    ///
    /// ## 为什么可以有多条
    ///
    /// 百度开放平台的授权是**应用级**的:一个 AppKey 只有一份 token
    /// (`docs/BAIDU_PAN_API.md` §6 第 3 条 —— 第二次申请会让第一次失效),
    /// 所以多个百度来源**共用同一份授权与密钥**,只是各自记住自己的片库根。
    /// 新增来源不会重新扫码 —— 已经授权过就直接落库,没授权过由调用方先走扫码
    /// (`BaiduPanAddView` 的流程)。
    ///
    /// ⚠️ 应用目录名 / AppKey 变了会让**所有**来源的片库根失效,这里一并清掉。
    ///
    /// 抛 `BaiduPanError`(配置不全等)与 `ServerRegistryError`。
    @discardableResult
    func addBaiduSource(
        displayName: String = "",
        appKey: String,
        secretKey: String,
        folderName: String
    ) async throws -> BaiduPanSource {
        let applicationChanged = try await baiduConnection().saveConfiguration(
            appKey: appKey, secretKey: secretKey, folderName: folderName)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = BaiduPanSource(
            displayName: trimmedName.isEmpty ? await uniqueBaiduDisplayName() : trimmedName,
            folderName: folderName)
        try await registry.add(.baiduPan(source))
        if applicationChanged {
            await discardAllBaiduLibraryRoots()
        }
        state.serverListRevision += 1
        // ⛔ 不要再写 `state.currentServer = nil` —— 那个 setter 会把 currentSource
        // 一并置空(它就是 currentSource 的派生访问器),刚设好的来源立刻被抹掉。
        state.currentSource = .baiduPan(source)
        state.route = .browse
        return source
    }

    /// 百度来源的添加收尾:配置在扫码前已经存过了,这里只按现值落库并切换过去。
    ///
    /// 之所以不复用 `addBaiduSource(appKey:secretKey:folderName:)`:那条路要求调用方
    /// 手上还攥着三串明文,而扫码屏只有加密后的凭据文件 —— 从文件回读才是唯一真相。
    @discardableResult
    func registerBaiduSource() async throws -> BaiduPanSource {
        let configuration = try await baiduConnection().appConfiguration()
        return try await addBaiduSource(
            appKey: configuration.appKey,
            secretKey: configuration.secretKey,
            folderName: configuration.folderName)
    }

    /// 库里所有的百度来源(按添加顺序)。
    func baiduSources() async -> [BaiduPanSource] {
        await registry.allSources().compactMap(\.baiduPanSource)
    }

    /// 清掉**所有**百度来源的片库根 —— 应用目录变了之后它们全部失效。
    ///
    /// ⚠️ 是**落一个「没有」**而不是删键:删键会让旧版兼容(`baidu-library-root`)
    /// 把这些片库根又继承回来,应用目录已经变了,继承回来的路径必然是废的。
    private func discardAllBaiduLibraryRoots() async {
        for source in await baiduSources() {
            try? await credentials.saveBaiduPanLibraryRoot(nil, for: source.id)
        }
    }

    /// 新百度来源的默认名:已有同名时往后编号(「百度网盘 2」「百度网盘 3」…),
    /// 免得来源列表与工具栏菜单里出现两个一模一样的条目分不清。
    private func uniqueBaiduDisplayName() async -> String {
        let existing = Set(await baiduSources().map(\.displayName))
        guard existing.contains("百度网盘") else { return "百度网盘" }
        var index = 2
        while existing.contains("百度网盘 \(index)") { index += 1 }
        return "百度网盘 \(index)"
    }

    // MARK: - 百度片库根

    /// 某个百度来源的片库根(**已校验**:落在应用目录之内;失效则当作没设)。
    /// nil = 没设,进来时落在应用目录。
    func libraryRoot(for source: BaiduPanSource) async throws -> BaiduPanLibraryRoot? {
        try await baiduConnection().libraryRoot(for: source.id)
    }

    /// 写入某个来源的片库根(nil = 清除,回到应用目录)。越界路径会抛 `BaiduPanError`。
    func setLibraryRoot(_ path: String?, for source: BaiduPanSource) async throws {
        try await baiduConnection().setLibraryRoot(path, for: source.id)
        state.serverListRevision += 1
    }

    /// 改某个百度来源的显示名(名称留空则回到「百度网盘」)。
    func renameBaiduSource(_ source: BaiduPanSource, displayName: String) async throws {
        var updated = source
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.displayName = trimmed.isEmpty ? "百度网盘" : trimmed
        try await registry.update(.baiduPan(updated))
        state.serverListRevision += 1
        if state.currentSource?.id == source.id {
            state.currentSource = .baiduPan(updated)
        }
    }

    /// 解除百度授权(清本机保存的 token)。
    ///
    /// ⚠️ 授权是**所有百度来源共用**的,所以这一下对所有百度来源生效 ——
    /// AppKey / 密钥 / 片库根都保留,重新扫码即可恢复。
    /// (入口在设置 →「来源」→ 百度网盘 → 编辑…,见 `BaiduPanSourceSettingsView`。)
    func signOutBaidu() async throws {
        try await baiduConnection().signOut()
        state.serverListRevision += 1
    }

    /// 切换当前来源。切换时清除旧来源的临时内容与播放器状态(CLAUDE.md「架构主线」)。
    func switchCurrent(to source: SourceProfile) async throws {
        stopPlayback(unlessOn: source.id)
        try await registry.markUsed(id: source.id, at: Date())
        // 回读库内现值:传进来的可能是列表视图的旧快照,
        // 直接赋值会让 lastUsedAt 停在切换之前
        state.currentSource = await registry.allSources().first { $0.id == source.id } ?? source
    }

    // MARK: - 服务器连接

    /// 一台服务器一个连接实例、一个 `EmbyAPIClient`,token 不共享
    /// (CLAUDE.md「架构主线」)。
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
    /// (CLAUDE.md「架构主线」:每台服务器一个 `EmbyAPIClient`,token 不共享)。
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

    /// 海报图片的内存 + 磁盘缓存与加载器(Emby 图带认证头、百度图走 `dlink`,
    /// 见 `ImageDescriptor`)。会话与接口请求共用同一个 —— 测试注入的
    /// `MockEmbyURLProtocol` 才能把图片请求也拦住。
    private(set) lazy var posters = PosterImageStore(
        loader: PosterImageLoader(container: self, session: session),
        disk: PosterDiskCache()
    )

    /// 手动刷新(菜单「Reload」,⌘R)时作废这台服务器的接口缓存:
    /// 用户按刷新就是要最新数据,不吃 TTL 内的缓存
    /// (浏览路径仍吃缓存,只有显式刷新走这里,见 `EmbyResponseCache`)。
    func invalidateResponses(for server: ServerProfile) async {
        await responseCache.invalidate(serverID: server.id)
    }

    /// 已有服务器重新登录(token 失效或未登录)。保留地址与用户名。
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
    /// (API_CONTRACT.md 1.4 的顺序)。
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
    /// 拆除,收尾上报照常发出(API_CONTRACT.md 5.4)。
    func play(_ item: EmbyItem, on server: ServerProfile, fromBeginning: Bool = false) {
        state.nowPlaying = PlaybackRequest(server: server, item: item, startFromBeginning: fromBeginning)
    }

    /// 播百度网盘里的一个文件。
    ///
    /// ⚠️ 百度来源与「当前 Emby 服务器」无关,所以切 Emby 服务器**不会**打断它
    /// (见 `stopPlayback(unlessOn:)`)。
    ///
    /// ⛔ 与 Emby 那条一样:**调用方(视图)必须自己 `openWindow`**。这里只写请求,
    /// 窗口不会因为 `nowPlaying` 有值自己出现 —— 漏了它表现为「点了播放没反应」。
    ///
    /// - Parameter episodeQueue: 同剧兄弟集(浏览页在起播那一刻用**当前目录已列条目**装配)。
    ///   没有(单条视频 / 「继续观看」卡片)就传 nil —— 播放页据此不显示换集入口。
    func play(
        _ file: BaiduPanFile,
        episodeQueue: EpisodeQueue? = nil,
        fromBeginning: Bool = false
    ) {
        state.nowPlaying = PlaybackRequest(
            baiduFile: file, startFromBeginning: fromBeginning, episodeQueue: episodeQueue)
    }

    /// 播一个**已经装配好的**请求(播放页换集用)。
    ///
    /// 与上面两条的分工:那两条从「一项内容」现搭请求,这条直接采纳调用方搭好的请求 ——
    /// 换集时队列必须**原样带过去**(百度的兄弟集只在这一次请求里,丢了就得再列网盘)。
    func play(_ request: PlaybackRequest) {
        state.nowPlaying = request
    }

    /// 记下「这条百度内容在「继续观看」里长什么样」:标题 + 定位 + 封面快照。
    ///
    /// 由浏览页在**起播那一刻**调用 —— 此刻 `SourceItem` 刚合成过,标题与封面
    /// 都在手上。⛔ 不要在渲染续播区时回头再列一遍网盘:配额见 §7
    /// (`docs/BAIDU_PAN_API.md`)。
    ///
    /// 写盘失败不抛给调用方:展示信息是**尽力而为**,失败不该打断播放 ——
    /// 与进度上报同一处置(见 `LocalResumeReporting`)。两者写同一个文件,
    /// 真正的写失败会由上报器的 `lastFailureDescription` 如实留下。
    func rememberResumeCard(item: SourceItem, file: BaiduPanFile) async {
        do {
            try await watchProgress.rememberDisplay(
                fileID: String(file.fsID),
                display: WatchProgressStore.Display(item: item, file: file)
            )
        } catch {}
    }

    /// 百度来源**播完一集**之后的本地收尾:① 这一集落成「已看」 ② 续播卡指向下一集没看的。
    ///
    /// ## 为什么需要它
    ///
    /// Emby 的续播卡是服务端算出来的(「第一集没看的」),百度没有服务端 ——
    /// 两件事都得自己记,而且必须是**同一个动作**:只做 ② 不做 ① 的话,刚看完的
    /// 那一集还留在「看到 99%」,按 `oneCardPerSeries`「看到一半压过下一集占位」
    /// 的规则,占位根本出不来,整部剧还是停在上一集(用户报的)。
    ///
    /// ① 之所以不能交给进度上报的比例判定:百度列表不给时长,`duration` 拿不到时
    /// 比例算不出来(见 `WatchProgressStore.markFinished`)。
    ///
    /// ⚠️ 只认**播放队列里**的兄弟集(起播那一刻装配好的,零请求):队列里没有的
    /// (别的季、没列过的目录)⛔ 不猜。
    /// ⚠️ 跳过已看的集:队列里的下一集可能早就标过已看,那就该指向再下一集。
    ///
    /// - Parameters:
    ///   - endedAt: 收尾那一刻的位置(秒)。播到文件末尾 = 这一集到此为止。
    ///   - durationSeconds: 已知总时长;百度来源常常是 nil。
    func finishBaiduEpisode(
        _ finished: PlaybackEpisode,
        in queue: EpisodeQueue,
        endedAt positionSeconds: Double,
        durationSeconds: Double?
    ) async {
        guard let file = finished.source.baiduFile else { return }
        do {
            try await watchProgress.markFinished(
                fileID: finished.id,
                display: finished.resumeItem.map {
                    WatchProgressStore.Display(item: $0, file: file)
                },
                endedAt: positionSeconds,
                durationSeconds: durationSeconds
            )
        } catch {
            // 写盘失败不该影响播放页收尾(与进度上报同一处置):下次播完再补。
            // 不往下写占位 —— 上一集没落成已看时,占位也出不来(见上)。
            return
        }
        guard let start = queue.episodes.firstIndex(where: { $0.id == finished.id }) else { return }
        for episode in queue.episodes[(start + 1)...] {
            guard let nextFile = episode.source.baiduFile,
                  let item = episode.resumeItem else { continue }
            guard await watchProgress.watchState(forFileID: episode.id) != .watched else { continue }
            do {
                try await watchProgress.setUpNext([
                    WatchProgressStore.PlayedMark(
                        fileID: episode.id,
                        display: WatchProgressStore.Display(item: item, file: nextFile))
                ])
            } catch {
                return
            }
            return
        }
    }

    /// 结束属于 `sourceID` 的播放(切换 / 删除来源时)。
    ///
    /// DesignTokens.swift「界面规则」:正在播放时切服务器,先结束旧播放会话再切换 ——
    /// 否则播放器窗口里还是上一台的内容,上报也继续打到上一台。
    /// ⛔ 百度来源不属于任何 Emby 服务器:切服务器不该打断它。
    private func stopPlayback(unlessOn sourceID: UUID) {
        guard let playing = state.nowPlaying else { return }
        guard case .emby(let server, _) = playing.source else { return }
        guard server.id != sourceID else { return }
        state.nowPlaying = nil
    }

    /// 切换当前服务器(Emby 便利入口)。
    func switchCurrent(to server: ServerProfile) async throws {
        try await switchCurrent(to: .emby(server))
    }

    // MARK: - 播放会话装配

    /// 按来源装配「会话准备」实现。播放页只认 `PlaybackSessionPreparing`,
    /// ⛔ 不认 Emby / 百度 —— 新增来源时改的是这里,不是播放页。
    func makeSessionPreparer(for request: PlaybackRequest) -> any PlaybackSessionPreparing {
        switch request.source {
        case .emby(let server, let item):
            return PlaybackSessionCoordinator(
                connection: connection(for: server),
                itemID: item.id
            )
        case .baiduPan(let file):
            return BaiduPanSessionPreparer(connection: baiduConnection(), file: file)
        }
    }

    /// 按来源装配「进度出口」:Emby → 服务端上报;百度 → 本地续播库。
    func makeReporter(for request: PlaybackRequest) -> any PlaybackReporting {
        switch request.source {
            // 上报走缓存的连接实例(与浏览同一个 `EmbyAPIClient`,token 不重取)。
            // ⛔ 闭包是 `@Sendable`,不能在它里面调 `connection(for:)`
            // (那是 MainActor 方法);连接实例本身是 actor,先取出来再捕获。
        case .emby(let server, _):
            let connection = connection(for: server)
            return PlaybackProgressReporter { endpoint in
                try await connection.reportPlayback(endpoint)
            }
        case .baiduPan:
            return LocalResumeReporting(store: watchProgress)
        }
    }

    /// 起播位置(秒)。Emby 读服务端 `UserData`,百度读本地续播库 ——
    /// 两边都是「来源自己知道的事」,播放页不关心它从哪来。
    /// 「从头播放」显式忽略它(返回 0,`API_CONTRACT.md` 8.1 禁止填假默认值)。
    func resumeSeconds(for request: PlaybackRequest, fromBeginning: Bool) async -> Double {
        guard !fromBeginning else { return 0 }
        switch request.source {
        case .emby(_, let item):
            return item.userData?.playbackPositionTicks
                .flatMap { TickConverter.seconds(fromTicks: $0) } ?? 0
        case .baiduPan(let file):
            return await watchProgress.resumeSeconds(forFileID: String(file.fsID)) ?? 0
        }
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

    /// 删除来源(含其本地凭据);若删的是当前来源,
    /// 切到剩余里最近使用的一个;一个不剩则回引导页。
    func removeSource(id: UUID) async throws {
        if state.nowPlaying?.source.embyServer?.id == id {
            state.nowPlaying = nil
        }
        let target = await registry.allSources().first { $0.id == id }
        if let baidu = target?.baiduPanSource {
            // 这个来源自己的片库根先清掉(它是按来源存的)
            try? await credentials.deleteBaiduPanLibraryRoot(for: baidu.id)
            // 授权与密钥是**所有百度来源共用**的:只有删掉最后一个才清 ——
            // 否则会把还在用的其它来源一起弄成「需要重新授权」。
            let remaining = await baiduSources().filter { $0.id != baidu.id }
            if remaining.isEmpty {
                try? await credentials.deleteBaiduPanToken()
                try? await credentials.deleteBaiduPanAppConfiguration()
                baiduConnectionInstance = nil
            }
        }
        try await registry.remove(id: id)
        state.serverListRevision += 1
        // 连接实例跟着服务器一起走:留着会持有一个已不存在的服务器的 token 状态
        connections.removeValue(forKey: id)
        // 本地缓存也一起走:接口响应与图片磁盘目录都不留在盘上
        await responseCache.invalidate(serverID: id)
        await posters.purgeDisk(ownerID: id)
        if state.currentSource?.id == id {
            state.currentSource = await registry.mostRecentlyUsedSource()
        }
        if await registry.allSources().isEmpty {
            state.route = .onboarding
        }
    }

    /// 删除服务器(Emby 便利入口)。
    func removeServer(id: UUID) async throws {
        try await removeSource(id: id)
    }

    // MARK: - 会话恢复

    /// 启动时恢复最近一次使用的服务器
    /// (token 无效时回登录界面,但保留地址和用户名)。
    ///
    /// 有服务器就直接进主窗口的首页;
    /// 缺 token 时由 `BrowseView` 的登录 sheet 兜住(没记住密码时不静默重登,API_CONTRACT.md 2.5)。
    ///
    /// 这里**不发网络请求**:只判断本地有没有 token。token 是否仍然有效
    /// 由第一次鉴权请求决定,401 时回登录页(API_CONTRACT.md 2.5)。
    func restoreSession() async {
        guard !state.didRestoreSession else { return }
        state.didRestoreSession = true
        guard let recent = await registry.mostRecentlyUsedSource() else {
            state.route = .onboarding
            return
        }
        state.currentSource = recent
        state.route = .browse
        // 只有 Emby 来源有「要不要重新登录」这件事 —— 百度来源的授权状态
        // 由它自己那一页读凭据判断,不在这里预判。
        guard case .emby(let server) = recent else { return }
        do {
            if try await !canResumeSession(for: server) {
                state.serverNeedingLogin = server
            }
        } catch is KeychainError {
            // 首次访问凭据时才做旧版钥匙串导入,这里是它最早被触发的地方
            state.startupError = .credentialMigrationFailed
        } catch {
            // 读不到就不知道要不要重新登录 —— 如实挂到 state 上,不静默放过
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
