import Foundation
import os

/// 组合根:装配各存储与连接,承载跨视图的来源管理动作(添加 / 切换 / 编辑 / 删除 / 会话恢复)。
@MainActor
final class AppContainer {
    let credentials: CredentialStore
    let registry: ServerRegistry
    let state = AppState()
    /// 所有服务器共用,按 serverID 隔离;登录重建连接后缓存仍有效。
    let responseCache = EmbyResponseCache()
    /// 同一部剧沿用同一倍速。放组合根上:换集会新建 `PlayerViewModel`,寿命要的是「本次运行」。
    let playbackSpeeds = PlaybackSpeedStore()
    /// 本地续播库,给没有进度上报接口的来源(百度、本地文件夹)用;Emby 仍上报服务端。
    let watchProgress: WatchProgressStore
    /// 用户隐藏、但网盘上还留着的条目(百度没有这类标记接口,只能记本地)。
    let hiddenItems: HiddenItemsStore
    /// 用户手标的片头 / 片尾(Emby 没有写回章节标记的接口)。键见 `ManualMarkersScope`。
    let manualMarkers: ManualMarkersStore
    /// 百度目录落盘缓存:冷启动先出内容、后台刷新。按来源 id 分区。
    let baiduDirectoryCache: BaiduPanDirectoryCache
    /// 刮削结果落盘缓存。与目录缓存分开:失效条件不同,混在一起会互相误伤。
    let baiduScrapeCache: BaiduPanScrapeCache
    /// 每个目录有几集,供剧卡片显示「已看 3 / 共 12 集」(总数只有进过详情页才知道)。
    let baiduEpisodeCounts: BaiduPanEpisodeCountStore
    /// 全 App 一份:一个 App 只对应开放平台上的一个应用、一个授权。
    private var baiduConnectionInstance: BaiduPanConnection?
    /// 本地文件夹的安全作用域访问权,按来源开一次、开到来源被删 / 换文件夹(见 `LocalFolderAccess`)。
    let localFolderAccess: LocalFolderAccess
    /// 本地视频时长的进程内记忆,免得每次进目录都读文件头。
    let localMediaDurations = LocalMediaDurationCache()
    /// 设置窗口改、播放窗口读,必须同一实例,播放中改设置才即时生效。下面的偏好 / 设置 store 同理。
    let subtitleStyles: SubtitleStyleStore
    /// 外挂字幕复制进容器后播放器只读容器内路径,不必长期持 security-scoped 权限。
    let subtitleFiles: SubtitleFileStore
    /// 在线字幕(assrt)。全 App 一份:凭据、落盘目录、缓存只该有一个写入方。
    let subtitleService: SubtitleService
    /// 每集上次挂的外挂字幕,起播时自动挂上。
    let subtitleBindings: SubtitleBindingStore
    let preferences: PlaybackPreferences
    let homeAppearance: HomeAppearancePreferences
    /// 建 `posterDiskCache` 时读上限档位
    let imageCachePreferences: ImageCachePreferences
    /// 单独持有:设置页看占用 / 清空 / 改上限,不该依赖 `posters` 懒加载的整条加载链。
    let posterDiskCache: PosterDiskCache
    let danmakuSettings: DanmakuSettingsStore
    /// 弹幕(弹弹play)。全 App 一份:带剧集列表的进程内记忆,绑定库 / 缓存只该有一个写入方。
    /// 凭据用时才取,设置页刚填就生效。
    let danmaku: DanmakuService
    /// 所有连接共用,测试注入 `MockEmbyURLProtocol`。非 private:弹幕指纹的 `Range` 请求也要走它,
    /// 测试里才不会真发出去。
    let session: URLSession

    init(
        registry: ServerRegistry,
        credentials: CredentialStore,
        session: URLSession = .shared,
        preferences: UserDefaults = .standard,
        watchProgress: WatchProgressStore? = nil,
        hiddenItems: HiddenItemsStore? = nil,
        manualMarkers: ManualMarkersStore? = nil,
        danmaku: DanmakuService? = nil,
        subtitleFiles: SubtitleFileStore? = nil,
        subtitleService: SubtitleService? = nil,
        subtitleBindings: SubtitleBindingStore? = nil,
        baiduDirectoryCache: BaiduPanDirectoryCache? = nil,
        baiduScrapeCache: BaiduPanScrapeCache? = nil,
        baiduEpisodeCounts: BaiduPanEpisodeCountStore? = nil,
        localFolderAccess: LocalFolderAccess? = nil
    ) {
        self.registry = registry
        self.credentials = credentials
        self.session = session
        self.subtitleStyles = SubtitleStyleStore(defaults: preferences)
        self.subtitleFiles = subtitleFiles ?? SubtitleFileStore(directory: SubtitleFileStore.defaultDirectory)
        self.subtitleService = subtitleService ?? SubtitleService(
            credentials: credentials, store: self.subtitleFiles)
        self.subtitleBindings = subtitleBindings
            ?? SubtitleBindingStore(fileURL: SubtitleBindingStore.defaultFileURL)
        self.preferences = PlaybackPreferences(defaults: preferences)
        self.homeAppearance = HomeAppearancePreferences(defaults: preferences)
        let imageCachePreferences = ImageCachePreferences(defaults: preferences)
        self.imageCachePreferences = imageCachePreferences
        self.posterDiskCache = PosterDiskCache(byteLimit: imageCachePreferences.byteLimitBytes)
        self.watchProgress = watchProgress
            ?? WatchProgressStore(fileURL: WatchProgressStore.defaultFileURL)
        self.hiddenItems = hiddenItems
            ?? HiddenItemsStore(fileURL: HiddenItemsStore.defaultFileURL)
        self.manualMarkers = manualMarkers
            ?? ManualMarkersStore(fileURL: ManualMarkersStore.defaultFileURL)
        self.baiduDirectoryCache = baiduDirectoryCache
            ?? BaiduPanDirectoryCache(fileURL: BaiduPanDirectoryCache.defaultFileURL)
        self.baiduScrapeCache = baiduScrapeCache
            ?? BaiduPanScrapeCache(fileURL: BaiduPanScrapeCache.defaultFileURL)
        self.baiduEpisodeCounts = baiduEpisodeCounts
            ?? BaiduPanEpisodeCountStore(fileURL: BaiduPanEpisodeCountStore.defaultFileURL)
        self.localFolderAccess = localFolderAccess ?? LocalFolderAccess()
        self.danmakuSettings = DanmakuSettingsStore(defaults: preferences)
        self.danmaku = danmaku ?? DanmakuService(
            credentials: credentials,
            bindings: DanmakuBindingStore(fileURL: DanmakuBindingStore.defaultFileURL),
            cache: DanmakuCommentCache(directory: DanmakuCommentCache.defaultDirectory))
    }

    /// 生产组装。服务器列表损坏时按空列表启动,并挂 `AppError.serverListCorrupted` 由 RootView 提示。
    convenience init() {
        // 测试宿主共享真实沙盒容器:用临时文件、不做钥匙串导入,否则每次测试弹授权窗,
        // 且宿主生成的 DeviceId 会写进真实文件、压过钥匙串里的旧值。
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

    func sources() async -> [SourceProfile] {
        await registry.allSources()
    }

    func source(id: UUID) async -> SourceProfile? {
        await registry.allSources().first { $0.id == id }
    }

    func baiduConnection() -> BaiduPanConnection {
        if let existing = baiduConnectionInstance { return existing }
        let fresh = BaiduPanConnection(credentials: credentials)
        baiduConnectionInstance = fresh
        return fresh
    }

    /// 全 App 一份:刮削器带「问过的标题」缓存,每次新建就等于每次重问 TMDB。token 用时才取。
    private var metadataScraperInstance: BaiduPanMetadataScraper?

    func metadataScraper() -> BaiduPanMetadataScraper {
        if let existing = metadataScraperInstance { return existing }
        let fresh = BaiduPanMetadataScraper(
            credentials: credentials,
            cache: baiduScrapeCache
        )
        metadataScraperInstance = fresh
        return fresh
    }

    /// 添加百度来源:先存配置再落库。授权是应用级的(一个 AppKey 一份 token,`docs/BAIDU_PAN_API.md` §6),
    /// 多个百度来源共用授权与密钥,只各记各的片库根;不重新扫码,没授权过由调用方先扫码。
    /// 应用目录名 / AppKey 变了会让所有来源的片库根失效,一并清掉。
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
        // ⛔ 不要写 `state.currentServer = nil`:它是 currentSource 的派生访问器,会把来源一并抹掉
        state.currentSource = .baiduPan(source)
        state.route = .browse
        return source
    }

    /// 扫码后的添加收尾:配置扫码前已存,这里从凭据文件回读现值再落库(扫码屏手上没有明文)。
    @discardableResult
    func registerBaiduSource() async throws -> BaiduPanSource {
        let configuration = try await baiduConnection().appConfiguration()
        return try await addBaiduSource(
            appKey: configuration.appKey,
            secretKey: configuration.secretKey,
            folderName: configuration.folderName)
    }

    /// 按添加顺序。
    func baiduSources() async -> [BaiduPanSource] {
        await registry.allSources().compactMap(\.baiduPanSource)
    }

    /// 应用目录变了后清掉所有片库根。⛔ 落「没有」而不是删键:删键会让旧键 `baidu-library-root`
    /// 的兼容逻辑把废路径继承回来。
    private func discardAllBaiduLibraryRoots() async {
        for source in await baiduSources() {
            try? await credentials.saveBaiduPanLibraryRoot(nil, for: source.id)
        }
    }

    /// 已有同名时往后编号(「百度网盘 2」…)。
    private func uniqueBaiduDisplayName() async -> String {
        let existing = Set(await baiduSources().map(\.displayName))
        guard existing.contains("百度网盘") else { return "百度网盘" }
        var index = 2
        while existing.contains("百度网盘 \(index)") { index += 1 }
        return "百度网盘 \(index)"
    }

    // MARK: - 百度片库根

    /// 已校验落在应用目录内,失效当没设。nil = 没设,进来落在应用目录。
    func libraryRoot(for source: BaiduPanSource) async throws -> BaiduPanLibraryRoot? {
        try await baiduConnection().libraryRoot(for: source.id)
    }

    /// nil = 清除。越界路径抛 `BaiduPanError`。
    func setLibraryRoot(_ path: String?, for source: BaiduPanSource) async throws {
        try await baiduConnection().setLibraryRoot(path, for: source.id)
        state.serverListRevision += 1
    }

    /// 留空则回到「百度网盘」。
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

    /// 清本机 token。授权共用,对所有百度来源生效;AppKey / 密钥 / 片库根保留,重新扫码即恢复。
    func signOutBaidu() async throws {
        try await baiduConnection().signOut()
        state.serverListRevision += 1
    }

    // MARK: - 本地文件夹

    /// 做书签 → 落库 → 切过去。`folderURL` 须是打开面板给的(本次运行带访问权);`displayName` 留空用文件夹名。
    @discardableResult
    func addLocalFolderSource(
        folderURL: URL, displayName: String = ""
    ) async throws -> LocalFolderSource {
        let bookmark = try await localFolderAccess.makeBookmark(forFolderAt: folderURL)
        let rootName = LocalFolderSource.rootName(forFolderAt: folderURL)
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = LocalFolderSource(
            displayName: trimmed.isEmpty ? rootName : trimmed,
            bookmark: bookmark,
            lastKnownPath: folderURL.path,
            rootName: rootName)
        try await registry.add(.localFolder(source))
        state.serverListRevision += 1
        // ⛔ 同上,不写 `state.currentServer = nil`
        state.currentSource = .localFolder(source)
        state.route = .browse
        return source
    }

    /// 原文件夹挪走 / 访问权失效时重选。`rootName` 不变:条目路径与 id 挂在它下面,换后续播 / 隐藏 / 已看记录仍认得。
    @discardableResult
    func relinkLocalFolder(
        _ source: LocalFolderSource, to folderURL: URL
    ) async throws -> LocalFolderSource {
        let bookmark = try await localFolderAccess.makeBookmark(forFolderAt: folderURL)
        var updated = await registry.allSources()
            .first { $0.id == source.id }?.localFolderSource ?? source
        updated.bookmark = bookmark
        updated.lastKnownPath = folderURL.path
        // 关掉旧书签的访问权,下次读盘按新书签重开
        await localFolderAccess.close(sourceID: source.id)
        try await registry.update(.localFolder(updated))
        state.serverListRevision += 1
        if state.currentSource?.id == source.id {
            state.currentSource = .localFolder(updated)
        }
        return updated
    }

    /// 留空则回到文件夹名。
    func renameLocalFolderSource(_ source: LocalFolderSource, displayName: String) async throws {
        var updated = await registry.allSources()
            .first { $0.id == source.id }?.localFolderSource ?? source
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.displayName = trimmed.isEmpty ? updated.rootName : trimmed
        try await registry.update(.localFolder(updated))
        state.serverListRevision += 1
        if state.currentSource?.id == source.id {
            state.currentSource = .localFolder(updated)
        }
    }

    /// 根目录 URL(访问权已打开)。以注册表现值为准(调用方的可能是旧快照)。
    /// 书签陈旧时写回新书签,但不 +1 `serverListRevision`:静默维护,不该触发浏览页重读。
    func localFolderRoot(for source: LocalFolderSource) async throws -> URL {
        let current = await registry.allSources()
            .first { $0.id == source.id }?.localFolderSource ?? source
        let resolution = try await localFolderAccess.rootURL(for: current)
        if resolution.refreshedBookmark != nil || resolution.url.path != current.lastKnownPath {
            var updated = current
            if let refreshed = resolution.refreshedBookmark { updated.bookmark = refreshed }
            updated.lastKnownPath = resolution.url.path
            do {
                try await registry.update(.localFolder(updated))
            } catch {
                // 写不回去只是下次还报陈旧,⛔ 不挡这次访问
                Self.localFolderLogger.error(
                    "本地文件夹书签写回失败:\(error.localizedDescription, privacy: .public)")
            }
        }
        return resolution.url
    }

    func localFolderProvider(for source: LocalFolderSource) -> LocalFolderSourceProvider {
        LocalFolderSourceProvider(
            source: source,
            resolveRoot: { try await self.localFolderRoot(for: source) },
            durations: localMediaDurations,
            scraper: metadataScraper())
    }

    private static let localFolderLogger = Logger(
        subsystem: NetworkDiagnostics.subsystem, category: "local-folder")

    /// 切换当前来源,并停掉旧来源的播放。
    func switchCurrent(to source: SourceProfile) async throws {
        stopPlayback(unlessOn: source.id)
        try await registry.markUsed(id: source.id, at: Date())
        // 回读库内现值:传入的可能是旧快照,lastUsedAt 会停在切换前
        state.currentSource = await registry.allSources().first { $0.id == source.id } ?? source
    }

    // MARK: - 服务器连接

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

    /// 本地有 token 或记住了密码。false = 需要重新登录。
    func canResumeSession(for server: ServerProfile) async throws -> Bool {
        try await makeConnection(for: server).canAuthenticateWithoutPrompt()
    }

    // MARK: - 浏览用连接与图片缓存

    /// 浏览用连接按服务器复用(持有 token 与 `/emby` 前缀状态)。登录 / 探测仍用 `makeConnection` 新建:
    /// 要带 `schemeWasInferred`,且失败不该留下半成品。
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

    /// 与接口请求共用会话,测试的 `MockEmbyURLProtocol` 才能拦住图片请求。
    private(set) lazy var posters = PosterImageStore(
        loader: PosterImageLoader(container: self, session: session),
        disk: posterDiskCache
    )

    /// ⌘R 手动刷新时整台作废,不吃 TTL 内的缓存。
    func invalidateResponses(for server: ServerProfile) async {
        await responseCache.invalidate(serverID: server.id)
    }

    /// 已有服务器重新登录,保留地址与用户名。
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
        // 浏览连接还拿着旧档案 / token 状态,丢掉
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

    /// 地址规范化 → 探测 → 登录 → 成功后才入库(API_CONTRACT.md 1.4),失败不留「存在但用不了」的服务器。
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
            // 没填名称时用服务器自报的 ServerName,没报才退回主机名
            profile.displayName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if Task.isCancelled {
            // 登录完成瞬间被取消:不入库,不留孤立凭证
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

    /// 只写请求、不碰 AppKit:⛔ 调用方(视图)必须自己 `openWindow`,漏了就是「点播放没反应」。
    /// 替换正在播的内容时,旧播放页拆除,收尾上报照常发出(API_CONTRACT.md 5.4)。
    func play(_ item: EmbyItem, on server: ServerProfile, fromBeginning: Bool = false) {
        state.nowPlaying = PlaybackRequest(server: server, item: item, startFromBeginning: fromBeginning)
    }

    /// 播文件树来源(百度 / 本地文件夹)的文件;同样须调用方 `openWindow`。切 Emby 服务器不打断它。
    /// `episodeQueue`:同剧兄弟集(起播时用当前目录已列条目装配);nil = 播放页不显示换集入口。
    func play(
        _ file: BaiduPanFile,
        in source: FileSource,
        subtitleFiles: [BaiduPanFile] = [],
        episodeQueue: EpisodeQueue? = nil,
        fromBeginning: Bool = false
    ) {
        state.nowPlaying = PlaybackRequest(
            source: source.playbackSource(for: file),
            startFromBeginning: fromBeginning,
            episodeQueue: episodeQueue,
            subtitleFiles: subtitleFiles)
    }

    /// 播放页换集用:队列须原样带过去(兄弟集只在这次请求里,丢了就得再列网盘)。
    func play(_ request: PlaybackRequest) {
        state.nowPlaying = request
    }

    /// 记下续播卡的标题 + 定位 + 封面快照。起播时调用(此刻信息都在手上);⛔ 不要渲染续播区时再列网盘
    /// (配额,`docs/BAIDU_PAN_API.md` §7)。写盘失败不抛:尽力而为,同一文件的写失败会由
    /// 上报器 `lastFailureDescription` 留下(见 `LocalResumeReporting`)。
    func rememberResumeCard(item: SourceItem, file: BaiduPanFile) async {
        do {
            try await watchProgress.rememberDisplay(
                fileID: String(file.fsID),
                display: WatchProgressStore.Display(item: item, file: file)
            )
        } catch {}
    }

    /// 文件树来源一场播放结束后的本地收尾(播完、关窗、换集都走这里)。
    /// `naturalEnd`(自然播完)时先把这集落成已看:⛔ 不能交给进度比例判定,百度常拿不到时长
    /// (见 `WatchProgressStore.markFinished`)。之后只要这集已看(含越过 90% 直接关窗)就补「下一集」占位。
    /// `endedAt` 单位秒;`durationSeconds` 百度常为 nil。
    func settleFileSourceEpisode(
        _ playing: PlaybackSource,
        queue: EpisodeQueue?,
        naturalEnd: Bool,
        endedAt positionSeconds: Double,
        durationSeconds: Double?
    ) async {
        guard let file = playing.file else { return }
        let fileID = String(file.fsID)
        if naturalEnd {
            let resumeItem = queue?.episodes.first { $0.id == fileID }?.resumeItem
            do {
                try await watchProgress.markFinished(
                    fileID: fileID,
                    display: resumeItem.map { WatchProgressStore.Display(item: $0, file: file) },
                    endedAt: positionSeconds,
                    durationSeconds: durationSeconds
                )
            } catch {
                // 没落成已看时占位也不该出(会与停在 99% 的这集抢卡),下次播完再补
                Self.watchProgressLogger.error(
                    "播完落成已看失败:\(String(describing: error), privacy: .public)")
                return
            }
        }
        await advanceFileSourceUpNext(after: file, playing: playing, queue: queue)
    }

    /// 一集已看后把续播卡指向下一个没看的集(类似 Emby NextUp);这集不是已看就什么都不做。
    /// 不补的话这部剧在续播库里没有进行中记录,整张卡从「继续观看」消失。
    ///
    /// 找法:先在 `queue`(起播时装配,零请求)里往后找;没有队列时列一次所在目录。
    /// 这一季都看过了再按季文件夹往后找(每季末至多再列两次目录,配额 `docs/BAIDU_PAN_API.md` §7)。
    /// 平铺存法整部剧就在所在目录里,⛔ 不往外猜;特别篇(第 0 季)与未分季不算「后面的季」。
    func advanceFileSourceUpNext(
        after file: BaiduPanFile,
        playing: PlaybackSource,
        queue: EpisodeQueue?
    ) async {
        let fileID = String(file.fsID)
        guard await watchProgress.watchState(forFileID: fileID) == .watched else { return }
        var provider: (any FileSourceBrowsing)?
        do {
            let laterInSeason: [(item: SourceItem, file: BaiduPanFile)]
            if let queue, let index = queue.episodes.firstIndex(where: { $0.id == fileID }) {
                laterInSeason = queue.episodes[(index + 1)...].compactMap { episode in
                    guard let item = episode.resumeItem, let file = episode.source.file else { return nil }
                    return (item, file)
                }
            } else {
                // 不是剧集(电影等)没有下一集,省一次列目录
                guard await watchProgress.display(forFileID: fileID)?.episodeNumber != nil else { return }
                provider = await fileSourceProvider(for: playing, fileID: fileID)
                guard let provider else { return }
                let siblings = try await sortedEpisodes(
                    in: BaiduPanPath.directory(ofFilePath: file.path), provider: provider)
                laterInSeason = siblings
                    .firstIndex { $0.file.fsID == file.fsID }
                    .map { Array(siblings[($0 + 1)...]) } ?? []
            }
            if try await pointUpNext(toFirstUnwatchedIn: laterInSeason) { return }

            let seasonFolder = BaiduPanPath.directory(ofFilePath: file.path)
            let seriesDirectory = BaiduPanPath.seriesDirectory(ofFilePath: file.path)
            guard seriesDirectory != seasonFolder,
                  let season = BaiduPanMetadataSynthesizer.seasonNumber(
                      fromDirectoryName: (seasonFolder as NSString).lastPathComponent)
            else { return }
            if provider == nil { provider = await fileSourceProvider(for: playing, fileID: fileID) }
            guard let provider else { return }
            let series = try await provider.content(directory: seriesDirectory)
            guard let structure = BaiduPanSeriesLayout.shape(of: series.items).seriesStructure else { return }
            let hidden = await hiddenItems.hiddenRefs(sourceID: provider.sourceID)
            for later in structure.seasons {
                guard let number = later.number, number > season,
                      case .folder(let folder) = later.source,
                      !hidden.contains(folder.ref),
                      let fsID = UInt64(folder.ref.itemID),
                      let path = series.filesByID[fsID]?.path else { continue }
                let episodes = try await sortedEpisodes(in: path, provider: provider)
                if try await pointUpNext(toFirstUnwatchedIn: episodes) { return }
            }
        } catch {
            Self.watchProgressLogger.error(
                "续播卡没指向下一集:\(String(describing: error), privacy: .public)")
        }
    }

    /// 找到第一个没看的就停(它已有进度时不写,续播卡本来就会指向它)。
    /// - Returns: 找到了没看的集
    private func pointUpNext(
        toFirstUnwatchedIn candidates: [(item: SourceItem, file: BaiduPanFile)]
    ) async throws -> Bool {
        for candidate in candidates {
            let id = String(candidate.file.fsID)
            guard await watchProgress.watchState(forFileID: id) != .watched else { continue }
            try await watchProgress.setUpNext([
                WatchProgressStore.PlayedMark(
                    fileID: id,
                    display: WatchProgressStore.Display(item: candidate.item, file: candidate.file))
            ])
            return true
        }
        return false
    }

    /// 目录里的分集,顺序与详情页一致。隐藏的不算。
    private func sortedEpisodes(
        in directory: String,
        provider: any FileSourceBrowsing
    ) async throws -> [(item: SourceItem, file: BaiduPanFile)] {
        let content = try await provider.content(directory: directory)
        let hidden = await hiddenItems.hiddenRefs(sourceID: provider.sourceID)
        let episodes = BaiduPanSeriesLayout.sortedEpisodes(
            content.items.filter { $0.kind == .episode && !hidden.contains($0.ref) })
        // 卡片封面要 TMDB 剧照,与浏览页起播时记的快照一致;刮削不抛错,失败退本地图
        let scraped = await provider.scrape(items: episodes)
        return scraped.compactMap { item in
            guard let fsID = UInt64(item.ref.itemID), let file = content.filesByID[fsID] else { return nil }
            return (item, file)
        }
    }

    /// 播放收尾时用的目录读取能力。百度的来源 id 取自续播快照(起播时记下);没有就找不到来源,返回 nil。
    private func fileSourceProvider(
        for playing: PlaybackSource,
        fileID: String
    ) async -> (any FileSourceBrowsing)? {
        switch playing {
        case .emby:
            return nil
        case .localFolder(_, let local):
            return localFolderProvider(for: local)
        case .baiduPan:
            guard let sourceID = await watchProgress.display(forFileID: fileID)?.sourceID,
                  let baidu = await baiduSources().first(where: { $0.id == sourceID }) else { return nil }
            return BaiduPanSourceProvider(
                connection: baiduConnection(),
                sourceID: baidu.id,
                folderName: baidu.folderName,
                scraper: metadataScraper()
            )
        }
    }

    private static let watchProgressLogger = Logger(
        subsystem: NetworkDiagnostics.subsystem, category: "watch-progress")

    /// 切到别的来源时结束 Emby 播放(否则窗口还在播上一台、上报也打到上一台,DesignTokens.swift「界面规则」)。
    /// ⛔ 文件树来源不属于任何 Emby 服务器,不打断。
    private func stopPlayback(unlessOn sourceID: UUID) {
        guard let playing = state.nowPlaying else { return }
        guard case .emby(let server, _) = playing.source else { return }
        guard server.id != sourceID else { return }
        state.nowPlaying = nil
    }

    func switchCurrent(to server: ServerProfile) async throws {
        try await switchCurrent(to: .emby(server))
    }

    // MARK: - 播放会话装配

    /// 播放页只认 `PlaybackSessionPreparing`,⛔ 不认具体来源;新增来源改这里,不改播放页。
    func makeSessionPreparer(for request: PlaybackRequest) -> any PlaybackSessionPreparing {
        switch request.source {
        case .emby(let server, let item):
            return PlaybackSessionCoordinator(
                connection: connection(for: server),
                itemID: item.id
            )
        case .baiduPan(let file):
            return BaiduPanSessionPreparer(
                connection: baiduConnection(),
                file: file,
                subtitleFiles: request.subtitleFiles
            )
        case .localFolder(let file, let source):
            return LocalFileSessionPreparer(
                file: file,
                source: source,
                subtitleFiles: request.subtitleFiles,
                resolveRoot: { try await self.localFolderRoot(for: source) }
            )
        }
    }

    /// Emby → 服务端上报;文件树来源 → 本地续播库。
    func makeReporter(for request: PlaybackRequest) -> any PlaybackReporting {
        switch request.source {
            // 复用浏览连接。⛔ `@Sendable` 闭包里不能调 MainActor 的 `connection(for:)`,先取出再捕获。
        case .emby(let server, _):
            let connection = connection(for: server)
            return PlaybackProgressReporter { endpoint in
                try await connection.reportPlayback(endpoint)
            }
        case .baiduPan, .localFolder:
            return LocalResumeReporting(store: watchProgress)
        }
    }

    /// 起播位置(秒)。Emby 读 `UserData`,文件树来源读本地续播库;「从头播放」返回 0。
    func resumeSeconds(for request: PlaybackRequest, fromBeginning: Bool) async -> Double {
        guard !fromBeginning else { return 0 }
        switch request.source {
        case .emby(_, let item):
            return item.userData?.playbackPositionTicks
                .flatMap { TickConverter.seconds(fromTicks: $0) } ?? 0
        case .baiduPan(let file), .localFolder(let file, _):
            return await watchProgress.resumeSeconds(forFileID: String(file.fsID)) ?? 0
        }
    }

    /// 地址变了先重新探测(`/emby` 前缀与 http 回退跟着地址走,API_CONTRACT.md 1.4),不通就抛错不保存。
    /// 只改名称不发请求。
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
                    // 换成了另一台 Emby:缓存 key 不含 host,旧列表不能端给新地址
                    await responseCache.invalidate(serverID: server.id)
                }
                updated.serverID = probedID
            }
        }
        try await updateServer(updated)
    }

    /// 保存档案;若是当前服务器同步刷新 currentServer。
    func updateServer(_ profile: ServerProfile) async throws {
        try await registry.update(profile)
        state.serverListRevision += 1
        // 浏览连接还拿着旧地址 / 前缀,丢掉
        connections.removeValue(forKey: profile.id)
        if state.currentServer?.id == profile.id {
            // update 是合并式的(保留 lastUsedAt),回读库内值
            state.currentServer = await registry.all().first { $0.id == profile.id } ?? profile
        }
    }

    /// 删除来源及其本地数据;删的是当前来源则切到最近使用的,一个不剩回引导页。
    func removeSource(id: UUID) async throws {
        if state.nowPlaying?.source.embyServer?.id == id {
            state.nowPlaying = nil
        }
        if case .localFolder(_, let playing) = state.nowPlaying?.source, playing.id == id {
            // 访问权马上要关,先停
            state.nowPlaying = nil
        }
        let target = await registry.allSources().first { $0.id == id }
        if target?.localFolderSource != nil {
            await purgeLocalFolderData(sourceID: id)
        }
        if let baidu = target?.baiduPanSource {
            try? await credentials.deleteBaiduPanLibraryRoot(for: baidu.id)
            // 落盘缓存含片名,留着只有隐私风险
            await baiduDirectoryCache.purge(sourceID: baidu.id)
            await baiduScrapeCache.purge(sourceID: baidu.id)
            await baiduEpisodeCounts.purge(sourceID: baidu.id)
            // 授权与密钥共用:删最后一个百度来源才清
            let remaining = await baiduSources().filter { $0.id != baidu.id }
            if remaining.isEmpty {
                try? await credentials.deleteBaiduPanToken()
                try? await credentials.deleteBaiduPanAppConfiguration()
                baiduConnectionInstance = nil
            }
        }
        try await registry.remove(id: id)
        state.serverListRevision += 1
        connections.removeValue(forKey: id)
        await responseCache.invalidate(serverID: id)
        await posters.purgeDisk(ownerID: id)
        // 字幕 / 弹幕绑定键带服务器 id(`DanmakuMediaQuery.itemKey`);字幕文件与弹幕缓存不分服务器,
        // 由 `cleanUp…Cache` 按时间淘汰
        do {
            try await subtitleBindings.purge(keyPrefix: "emby|\(id.uuidString)|")
        } catch {
            Self.logger.error("删除服务器的字幕记录失败:\(error.localizedDescription, privacy: .public)")
        }
        do {
            try await danmaku.purgeBindings(keyPrefix: "emby|\(id.uuidString)|")
        } catch {
            Self.danmakuLogger.error("删除服务器的弹幕绑定失败:\(error.localizedDescription, privacy: .public)")
        }
        if state.currentSource?.id == id {
            state.currentSource = await registry.mostRecentlyUsedSource()
        }
        if await registry.allSources().isEmpty {
            state.route = .onboarding
        }
    }

    /// 本地条目 id 由「来源 id + 路径」哈希(`LocalFolderListing.fileID`),来源一删记录就永远对不上,
    /// 且路径含片名,一起清。清不掉只记日志,⛔ 不挡删除。
    private func purgeLocalFolderData(sourceID id: UUID) async {
        await localFolderAccess.close(sourceID: id)
        await baiduScrapeCache.purge(sourceID: id)
        await baiduEpisodeCounts.purge(sourceID: id)
        // 各清各的,一处失败不连累后面
        func attempt(_ what: String, _ work: () async throws -> Void) async {
            do {
                try await work()
            } catch {
                Self.localFolderLogger.error(
                    "删除本地文件夹来源时清\(what, privacy: .public)失败:\(error.localizedDescription, privacy: .public)")
            }
        }
        let prefix = "local|\(id.uuidString)|"
        await attempt("观看记录") {
            let records = await watchProgress.storedRecords(sourceID: id).map(\.fileID)
            try await watchProgress.remove(fileIDs: records)
        }
        await attempt("隐藏记录") { try await hiddenItems.purge(sourceID: id) }
        await attempt("字幕记录") { try await subtitleBindings.purge(keyPrefix: prefix) }
        await attempt("弹幕绑定") { try await danmaku.purgeBindings(keyPrefix: prefix) }
    }

    func removeServer(id: UUID) async throws {
        try await removeSource(id: id)
    }

    // MARK: - 字幕缓存

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "subtitles")

    /// 启动时清理:先删过期的每集记录,再删没人引用且过期 / 超量的文件(规则见 `SubtitleFileStore`)。
    /// 失败只记日志、不打扰用户,下次启动再清。
    func cleanUpSubtitleCache() async {
        do {
            let prunedBindings = try await subtitleBindings.prune()
            let keeping = await subtitleBindings.referencedGroups()
            let report = try await subtitleFiles.cleanUp(keeping: keeping)
            if prunedBindings > 0 || report.removedGroups > 0 {
                Self.logger.info(
                    "字幕缓存清理:过期记录 \(prunedBindings) 条,删除 \(report.removedGroups) 组 \(report.removedBytes) 字节,剩余 \(report.remainingBytes) 字节")
            }
        } catch {
            Self.logger.error("字幕缓存清理失败:\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 弹幕缓存

    private static let danmakuLogger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "danmaku")

    /// 启动时删过期 / 损坏的文件(规则见 `DanmakuCommentCache`)。失败只记日志。
    func cleanUpDanmakuCache() async {
        do {
            let report = try await danmaku.cleanUpCache()
            if report.removedFiles > 0 {
                Self.danmakuLogger.info(
                    "弹幕缓存清理:删除 \(report.removedFiles) 个文件 \(report.removedBytes) 字节")
            }
        } catch {
            Self.danmakuLogger.error("弹幕缓存清理失败:\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 会话恢复

    /// 恢复最近使用的来源并直接进首页。⛔ 不发网络请求:只看本地有没有 token,缺了由 `BrowseView`
    /// 的登录 sheet 兜;token 是否有效由第一次鉴权请求决定(API_CONTRACT.md 2.5)。
    func restoreSession() async {
        guard !state.didRestoreSession else { return }
        state.didRestoreSession = true
        guard let recent = await registry.mostRecentlyUsedSource() else {
            state.route = .onboarding
            return
        }
        state.currentSource = recent
        state.route = .browse
        // 只有 Emby 在这里判断是否要重新登录;百度授权由它自己那一页判断
        guard case .emby(let server) = recent else { return }
        do {
            if try await !canResumeSession(for: server) {
                state.serverNeedingLogin = server
            }
        } catch is KeychainError {
            // 钥匙串导入在首次访问凭据时触发,通常就是这里
            state.startupError = .credentialMigrationFailed
        } catch {
            // 读不到就不知道要不要重新登录,如实报出
            state.startupError = .credentialReadFailed
        }
    }

    // MARK: - 私有

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 显示名留空时用 host[:port];`addServer` 拿到 ServerName 后会替换
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
