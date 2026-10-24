import Foundation
import Observation

/// 文件树来源(百度网盘 / 本地文件夹)页的 ViewModel。两个来源共用:列目录 → 合成 → TMDB 刮削 →
/// 剧集详情 → 本地续播 / 已看。差别按 `source` 分派:
///
/// - 授权只有百度有,三屏(填密钥 → 扫码 → 浏览)共用本 ViewModel,因为是一条连续流程。
///   本地文件夹访问权来自书签,失效时在目录层报 `.needsFolderReselection`。
/// - 目录缓存只有百度要(配额),见 `cachesDirectories`。
/// - 删 / 改名只有百度能做(`FileSource.supportsDeletingFiles`)。
///
/// 名字带 `BaiduPan…` 的纯函数(排序、剧集判定、合成器)对两个来源通用。
@MainActor
@Observable
final class FileSourceViewModel {

    // MARK: - 授权

    /// 现在该显示哪一屏。nil = 还在判定
    private(set) var authorization: BaiduPanAuthorization?
    private(set) var loadFailure: LoadFailure?
    private(set) var isLoading = false

    /// 正在等扫码(device code 已拿到)
    private(set) var deviceCode: BaiduPanDeviceCode?
    private(set) var isWaitingForAuthorization = false
    /// 不打断当前流程的本地提示(二维码渲染失败、片库根存不进去等)
    private(set) var notice: String?

    // MARK: - 目录

    /// 应用目录名(空状态里告诉用户把片子放哪)
    private(set) var folderName: String?
    /// 应用根目录 `/apps/{应用目录名}`,第三方应用能访问的全部范围
    private(set) var rootDirectory: String?
    /// 已校验的片库根(失效视同没设;nil = 用应用目录)。也是本页能退到的最外层(`canGoUp`)。
    /// 列表在设置里维护(`BaiduPanSourceSettingsView`),这里只读。
    private(set) var libraryRoot: BaiduPanLibraryRoot?
    private(set) var currentDirectory: String?
    /// 导航目标(进 / 退目录、进详情页),内容到手才与 `items` 一起提交给 `currentDirectory`。
    /// ⛔ 别在发请求前就写 `currentDirectory`:目录换了条目还没换,按目录算的区块
    /// (如「最近添加」)会在加载途中先消失,界面剩下半新半旧的一帧。
    private var pendingDirectory: String?
    /// 来源返回的原始顺序,不含 `path` 等播放信息(见 `filesByID`)。⛔ 界面用 `sortedItems`。
    private(set) var items: [SourceItem] = []
    /// `fs_id` → 原始文件。播放与进目录要用的 `path` 只在这里。
    private var filesByID: [UInt64: BaiduPanFile] = [:]
    /// 被隐藏的条目。计算属性里不能 await,所以每轮 `loadFiles` 从本地库读进内存。
    private var hiddenRefs: Set<SourceItemRef> = []

    /// 会话级目录缓存:目录路径 → 完整读取结果。来回进出同一目录零请求(配额见
    /// `docs/BAIDU_PAN_API.md` §7);网盘里的变化要用户点刷新(`refreshFiles()`)才反映,
    /// `reload()` 清空它。封面 `dlink` 8 小时过期,会话远短于此且有磁盘缓存兜底,不另处理。
    private var directoryCache: [String: FileSourceDirectoryContent] = [:]

    /// 命中落盘缓存后在后台拉真实目录。换目录时要取消,否则旧目录的结果会写进新目录。
    private var backgroundRefreshTask: Task<Void, Never>?

    /// 排序、去隐藏、按观看状态筛过的条目,界面用这个。零请求。
    ///
    /// 默认「剧集顺序」(`BaiduPanSortOrder.episode`):认得出集号按 (季, 集),否则自然名序。
    /// 做成计算属性、隐藏也在这里过滤而非真删:刮削回来会整份替换 `items`;
    /// 且设置里「恢复」隐藏项能立刻出现,不用重列目录。
    var sortedItems: [SourceItem] {
        let ordered = sortOrder.apply(to: items, filesByID: filesByID, ascending: sortAscending)
        return visible(ordered).filter { matchesWatchFilter($0) }
    }

    /// 片库根上的「最近添加」:按 `server_mtime` 倒序,零请求。只在片库根、且条目多于
    /// `recentShelfLimit` 时给(否则只是把网格换个顺序重画)。不受观看筛选影响。
    /// 目录的 `server_mtime` 随往里加文件更新,正好表示「这部剧最近更新过」。
    var recentItems: [SourceItem] {
        guard isAtLibraryRoot else { return [] }
        let dated = visible(items).compactMap { item -> (SourceItem, Date)? in
            guard let fsID = UInt64(item.ref.itemID),
                  let modified = filesByID[fsID]?.modifiedAt else { return nil }
            return (item, modified)
        }
        guard dated.count > Self.recentShelfLimit else { return [] }
        return dated
            .sorted { $0.1 > $1.1 }
            .prefix(Self.recentShelfLimit)
            .map(\.0)
    }

    private static let recentShelfLimit = 12

    /// 配了片库根就是它,否则是应用目录
    private var isAtLibraryRoot: Bool {
        guard let current = currentDirectory else { return false }
        return current == topmostDirectory
    }

    /// 排序与筛选只作用于已取回的条目,零请求;控件放页头,不放主窗口工具栏。
    private(set) var sortOrder: BaiduPanSortOrder = .episode
    private(set) var sortAscending = true

    /// 观看状态筛选,数据来自本地续播库。换目录不重置;筛空时空状态给「显示全部」。
    private(set) var watchFilter: BaiduPanWatchFilter = .all

    /// 目录路径 → 集数(`BaiduPanEpisodeCountStore`),只有进过详情页才有(见 `episodeTotal(for:)`)。
    private(set) var episodeCounts: [String: Int] = [:]

    private(set) var isLoadingFiles = false
    private(set) var directoryFailure: FileSourceDirectoryFailure?

    /// ⌘R 据此决定语义,见 `refreshFromToolbar()`
    private(set) var hasLoadedOnce = false

    /// 用户要改配置时预填给表单的现值
    private(set) var configurationDraft: BaiduPanConfigurationDraft?

    /// `fs_id` → 本地观看状态,来自本地续播库,零请求。覆盖当前目录、详情页当前季,
    /// 以及本来源在库里的全部记录。未看的不在字典里。
    private(set) var watchStates: [String: WatchProgressStore.WatchState] = [:]

    /// 目录路径 → 其下(含子目录)已看集数。只统计本地有记录的:算总集数要列子目录,
    /// 网格上花不起配额,所以做不到 Emby 那种「还有 N 集未看」。
    private(set) var watchedEpisodeCounts: [String: Int] = [:]

    // MARK: - 剧集详情(目录形态)

    /// 普通目录(网格)还是一部剧(详情页),由 `BaiduPanSeriesLayout` 判定
    private(set) var directoryShape: BaiduPanDirectoryShape = .directory

    /// 剧级展示信息。剧级元数据是列父目录时刮回来的(`enrichFolders`),
    /// 剧目录自己的内容里没有,所以要留住用户点进来的那张卡片。
    private(set) var seriesItem: SourceItem?

    /// 用户点进来的目录卡片,只有 `enter(_:)` 设置
    private var enteredSeriesItem: SourceItem?

    /// 从续播卡片进来时暂代剧级海报的封面。它是那一集的封面(配了 TMDB 时是 16:9 剧照),
    /// 与目录卡片进来看到的海报不同,所以 `seriesProfile` 一到就换掉
    /// (`applySeriesPosterFromProfile`)。nil = 没有待替换的。
    private var resumeSnapshotPoster: ImageDescriptor?

    /// 上一轮判定形态的目录。区分「同一部剧刷新」(保住当前季)与「进了另一部剧」(回第一季);
    /// ⛔ 不靠季号判断,两部剧都有第 1 季。
    private var shapeDirectory: String?

    /// 续播卡片进详情页时想选中的季。一次性导航意图:`openDetail(for:)` 写、
    /// `applyDirectoryShape` 消费即清,留着会影响下次进别的目录。
    private var preferredSeasonNumber: Int?

    private(set) var selectedSeason: BaiduPanSeason?

    /// 选中季的分集(已按集号排序;只含能播的条目)
    private(set) var episodes: [SourceItem] = []
    private(set) var isLoadingEpisodes = false
    /// 只影响分集区,剧级信息与季列表照常显示
    private(set) var episodeFailure: String?

    /// 换季 / 换目录 / 换授权时 +1,回来对不上就丢弃
    private var episodeGeneration = 0
    private var episodeScrapeTask: Task<Void, Never>?

    /// 播放主按钮对应的集:看到一半的 > 「下一集」占位 > 第一集。nil = 没有分集,不画按钮。
    var focusedEpisode: SourceItem? {
        episodes.first { (resumeSeconds(for: $0) ?? 0) > 0 }
            ?? episodes.first { upNextFileIDs.contains($0.ref.itemID) }
            ?? episodes.first
    }

    /// 「下一集」占位的 id(`FileSourceResumeCard.isUpNext`),直接取续播区的,不再读库
    private var upNextFileIDs: Set<String> {
        Set(resumeCards.filter(\.isUpNext).map(\.fileID))
    }

    /// 剧级扩展信息与演职员。列表刮削的搜索端点给不出这些,只在详情页按 id 取
    /// (`BaiduPanMetadataScraper.seriesProfile`)。nil = 没拿到,详情页缺就隐藏。
    private(set) var seriesProfile: TMDBSeriesProfile?
    private(set) var isLoadingSeriesProfile = false

    // 这一趟没有单独的失败文案:刮削器的 `lastFailureDescription` 是共用槽位,可能是分集刮削留下的。
    // 拿不到就整块隐藏;TMDB 本身的问题由分集那趟的 `scrapeFailure` 报。

    /// 换剧 / 换授权时 +1,回来对不上就丢弃
    private var seriesProfileGeneration = 0
    private var seriesProfileTask: Task<Void, Never>?

    /// 人物头像的归属来源,与海报 / 剧照同一缓存分区。详情页显示期间实际恒非 nil。
    var seriesSourceID: UUID? { seriesItem?.ref.sourceID ?? episodes.first?.ref.sourceID }

    /// 本地续播库里有进度且带快照的条目,按最近看排序。⛔ 不限于当前目录。
    private(set) var resumeCards: [FileSourceResumeCard] = []

    /// 正在为续播起播补列目录的卡片(要发请求,卡片据此转圈)
    private(set) var preparingPlaybackFileID: String?

    private let container: AppContainer
    /// 可变只为设置里改了显示名 / 换了文件夹时跟上(`sourceDidChange`)
    private(set) var source: FileSource
    /// 主窗口顶栏按它登记「根页有 hero」
    var sourceID: UUID { source.id }

    /// 目录缓存(会话内存 + 落盘)只有百度要(配额)。本地每次重读,用户拷了新片子回来就能看到。
    private var cachesDirectories: Bool {
        if case .baiduPan = source { return true }
        return false
    }
    /// 授权后是否顺带列目录。添加流程传 `false`:授权一成功就落库切页,此时列目录是白烧配额。
    private let loadsDirectory: Bool
    private var authorizationTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// TMDB 刮削是后台第二趟,回来时目录可能已换,靠它丢弃过期结果
    private var directoryGeneration = 0
    private var scrapeTask: Task<Void, Never>?
    /// nil = 没失败 / 没配 token。与 `notice` 分开,不盖掉目录本身的提示。
    private(set) var scrapeFailure: String?

    init(container: AppContainer, source: FileSource, loadsDirectory: Bool = true) {
        self.container = container
        self.source = source
        self.loadsDirectory = loadsDirectory
    }

    convenience init(container: AppContainer, source: BaiduPanSource, loadsDirectory: Bool = true) {
        self.init(container: container, source: .baiduPan(source), loadsDirectory: loadsDirectory)
    }

    /// 只在百度分支里用,本地文件夹来源不发请求
    private var connection: BaiduPanConnection { container.baiduConnection() }

    /// provider 负责列目录 → 合成 → 封面 / 时长 → 刮削
    private func makeProvider() -> any FileSourceBrowsing {
        switch source {
        case .baiduPan(let baidu):
            return BaiduPanSourceProvider(
                connection: connection,
                sourceID: baidu.id,
                folderName: folderName ?? baidu.folderName,
                scraper: container.metadataScraper()
            )
        case .localFolder(let local):
            return container.localFolderProvider(for: local)
        }
    }

    /// 设置里改了本来源时接过新值。⛔ 不接别的来源:换来源时主窗口按 id 重建整页(`BrowseView.rootPage`)。
    func sourceDidChange(_ updated: FileSource) {
        guard updated.id == source.id, updated != source else { return }
        source = updated
    }

    // MARK: - 动作:进入

    func reload() async {
        loadTask?.cancel()
        let task = Task { [weak self] in _ = await self?.performReload() }
        loadTask = task
        await task.value
    }

    /// ⌘R:没加载过走 `reload()`(回片库根);之后只重读当前目录,不把人踢回起点。两条都绕过会话缓存。
    func refreshFromToolbar() async {
        if hasLoadedOnce {
            await refreshFiles()
        } else {
            await reload()
        }
    }

    private func performReload() async {
        isLoading = true
        loadFailure = nil
        defer { isLoading = false }
        // 结构性变化:会话缓存作废,从片库根重列。放在 `case .authorized` 之外,
        // 因为解绑 / 换密钥后走「需要授权」那条路也得清。`filesByID` 是合并写入的,也要清。
        directoryCache.removeAll()
        filesByID.removeAll()
        enteredSeriesItem = nil
        resumeSnapshotPoster = nil
        shapeDirectory = nil
        preferredSeasonNumber = nil
        // 结构变了,导航目标也作废(否则重试会去追赶已不存在的目录)
        pendingDirectory = nil
        guard case .baiduPan = source else {
            // 本地文件夹没有授权步骤,书签失效由 `loadFiles` 报
            guard loadsDirectory else { return }
            currentDirectory = nil
            await loadFiles()
            hasLoadedOnce = true
            return
        }
        do {
            authorization = try await connection.authorization()
            // 目录名只用于展示。这里的 `try?` 不是吞错:读不出凭据时上面的 `authorization()` 已抛同样的错。
            folderName = try? await connection.appConfiguration().folderName
            switch authorization {
            case .authorized:
                // 结构性变化后一律从片库根开始;⌘R 走 `refreshFromToolbar()`
                guard loadsDirectory else { break }
                currentDirectory = nil
                await loadFiles()
                hasLoadedOnce = true
            case .needsAuthorization, .unconfigured, nil:
                break
            }
        } catch let error as BaiduPanError {
            // 「还没配置」不是失败,是第一屏(配置表单)
            if error == .appCredentialsMissing {
                authorization = .unconfigured
            } else {
                authorization = nil
                loadFailure = LoadFailure(message: error.userMessage)
            }
        } catch {
            authorization = nil
            loadFailure = LoadFailure(message: "读取百度网盘授权状态失败:\(error)")
        }
    }

    // MARK: - 动作:配置

    func saveConfiguration(appKey: String, secretKey: String, folderName: String) async {
        do {
            try await connection.saveConfiguration(
                appKey: appKey, secretKey: secretKey, folderName: folderName)
            await reload()
        } catch let error as BaiduPanError {
            loadFailure = LoadFailure(message: error.userMessage)
        } catch {
            loadFailure = LoadFailure(message: "保存配置失败:\(error)")
        }
    }

    // MARK: - 动作:授权

    func startAuthorization() async {
        guard !isWaitingForAuthorization else { return }
        isWaitingForAuthorization = true
        loadFailure = nil
        notice = nil
        do {
            deviceCode = try await connection.startDeviceAuthorization()
        } catch let error as BaiduPanError {
            loadFailure = LoadFailure(message: error.userMessage)
            isWaitingForAuthorization = false
            return
        } catch {
            loadFailure = LoadFailure(message: "获取授权二维码失败:\(error)")
            isWaitingForAuthorization = false
            return
        }
        guard let deviceCode else { return }
        authorizationTask?.cancel()
        authorizationTask = Task { [weak self] in await self?.poll(deviceCode) }
    }

    private func poll(_ code: BaiduPanDeviceCode) async {
        do {
            _ = try await connection.awaitAuthorization(code)
            isWaitingForAuthorization = false
            deviceCode = nil
            await reload()
        } catch is CancellationError {
            // 用户点了取消:回到「需要授权」那一屏,不报错
            isWaitingForAuthorization = false
            deviceCode = nil
        } catch let error as BaiduPanError {
            isWaitingForAuthorization = false
            deviceCode = nil
            loadFailure = LoadFailure(message: error.userMessage)
        } catch {
            isWaitingForAuthorization = false
            deviceCode = nil
            loadFailure = LoadFailure(message: "授权失败:\(error)")
        }
    }

    func cancelAuthorization() {
        authorizationTask?.cancel()
        authorizationTask = nil
        isWaitingForAuthorization = false
        deviceCode = nil
    }

    // 解除授权在设置里(`AppContainer.signOutBaidu`)。浏览页不会立即知道,
    // 下次刷新撞上 `notAuthorized` 时由 `loadFiles` 切回扫码屏。

    /// 切回配置表单(典型:应用目录名填错)。⛔ 不动 token,改目录名不该要求重新扫码。
    func beginConfigurationEdit() async {
        if let configuration = try? await connection.appConfiguration() {
            configurationDraft = BaiduPanConfigurationDraft(
                appKey: configuration.appKey,
                secretKey: configuration.secretKey,
                folderName: configuration.folderName
            )
        } else {
            configurationDraft = nil
        }
        authorization = .unconfigured
    }

    func cancelConfigurationEdit() async {
        configurationDraft = nil
        await reload()
    }

    // MARK: - 动作:目录

    func loadFiles() async {
        await loadFiles(directory: nil, allowingLibraryRootFallback: true)
    }

    /// 用户点「刷新 / 重试」:绕过会话缓存走网络并写回。导航(进 / 退目录)用 `navigate(to:)`。
    /// 上一次导航失败没提交时仍按那个目标重试(`pendingDirectory`)。
    func refreshFiles() async {
        await loadFiles(directory: nil, allowingLibraryRootFallback: true, forceRefresh: true)
    }

    /// 导航:目标先记进 `pendingDirectory`,列完目录才与 `items` 一起提交。
    private func navigate(to directory: String) async {
        await loadFiles(directory: directory, allowingLibraryRootFallback: true)
    }

    /// 播完 / 标记状态后只刷新本地观看状态。⛔ 不重列目录(2 次请求,而目录没变)。
    func refreshResumeState() async {
        await loadResumeCards()
        await loadWatchStates()
    }

    /// 换档位时回到该档的自然方向(同 `LibrarySort`)
    func setSortOrder(_ order: BaiduPanSortOrder) {
        guard order != sortOrder else { return }
        sortOrder = order
        sortAscending = order.defaultAscending
    }

    func toggleSortDirection() {
        sortAscending.toggle()
    }

    func setWatchFilter(_ filter: BaiduPanWatchFilter) {
        watchFilter = filter
    }

    /// `directory`:导航目标;nil = 当前位置(`pendingDirectory` 优先,见属性注释)。
    /// `allowingLibraryRootFallback`:片库根读不出时清掉它、回落应用目录。⛔ 只回落一次,
    /// 递归时传 false,否则真正的错误(目录名填错)会被重试藏起来。
    /// `forceRefresh`:绕过会话缓存走网络并写回。
    private func loadFiles(
        directory explicitDirectory: String?,
        allowingLibraryRootFallback allowFallback: Bool,
        forceRefresh: Bool = false
    ) async {
        isLoadingFiles = true
        directoryFailure = nil
        cancelScrape()
        // 本次读取的轮次(`cancelScrape` 刚 +1)。连着点两张卡片时只有最新那次能提交,
        // 先发后到的结果不许把界面拽回旧目录。
        let loadID = directoryGeneration
        defer { if loadID == directoryGeneration { isLoadingFiles = false } }

        // 本地数据,零请求。每轮都要读:设置页可能刚恢复了隐藏项。
        hiddenRefs = await container.hiddenItems.hiddenRefs(sourceID: source.id)
        episodeCounts = await container.baiduEpisodeCounts.counts(sourceID: source.id)

        // 续播区与当前目录无关,目录失败也要显示。片库根回落是同一轮递归,不重读。
        if allowFallback { await loadResumeCards() }

        var directory = ""
        do {
            let root: String
            switch source {
            case .baiduPan(let baidu):
                root = try await connection.applicationDirectory()
                libraryRoot = try await connection.libraryRoot(for: baidu.id)
            case .localFolder(let local):
                // 本地没有片库根,最外层就是选的文件夹
                root = local.rootPath
                libraryRoot = nil
            }
            rootDirectory = root
            // 导航目标 > 上次没提交的目标(重试)> 当前位置;刷新不抹掉导航留下的位置
            directory = explicitDirectory ?? pendingDirectory ?? currentDirectory
                ?? libraryRoot?.path ?? root
            pendingDirectory = directory
            let provider = makeProvider()
            let content: FileSourceDirectoryContent
            if !cachesDirectories {
                content = try await provider.content(directory: directory)
            } else if !forceRefresh, let cached = directoryCache[directory] {
                content = cached
            } else if !forceRefresh, let disk = await container.baiduDirectoryCache.content(
                sourceID: source.id, directory: directory) {
                // 冷启动首次进这一层:先端出盘上内容(无封面),封面由刮削缓存补,
                // 真实目录交给后台刷新,不让人对着转圈等网络。
                let restored = Self.content(from: disk, sourceID: source.id)
                content = restored
                directoryCache[directory] = restored
                guard loadID == directoryGeneration else { return }
                commit(restored, directory: directory)
                await applyDirectoryShape(directory: directory)
                startScrape(items: restored.items, provider: provider)
                startBackgroundRefresh(directory: directory)
                return
            } else {
                content = try await provider.content(directory: directory)
                directoryCache[directory] = content
                await storeDirectoryCache(content, directory: directory)
            }
            guard loadID == directoryGeneration else { return }
            commit(content, directory: directory)
            await applyDirectoryShape(directory: directory)
            startScrape(items: content.items, provider: provider)
            return
        } catch let error as BaiduPanError {
            guard loadID == directoryGeneration else { return }
            // token 没了 → 回扫码屏,⛔ 不停在一条「没权限」的目录错误上
            if case .notAuthorized = error {
                authorization = .needsAuthorization(folderName: folderName ?? "")
                return
            }
            // 片库根被删 / 改名 → 静默清掉并回落应用目录
            if allowFallback, error.isDirectoryUnavailable,
               let library = libraryRoot?.path, directory == library,
               library != rootDirectory {
                await clearLibraryRoot()
                currentDirectory = nil
                pendingDirectory = nil
                await loadFiles(
                    directory: nil,
                    allowingLibraryRootFallback: false,
                    forceRefresh: forceRefresh)
                return
            }
            directoryFailure = FileSourceDirectoryFailure(
                message: error.userMessage,
                isApplicationRootUnavailable: error.isDirectoryUnavailable
                    && directory == rootDirectory
            )
        } catch let error as LocalFolderError {
            guard loadID == directoryGeneration else { return }
            // 访问权没了 → 失败页给「重新选择文件夹…」;某层读不出 → 只报原因
            directoryFailure = FileSourceDirectoryFailure(
                message: error.userMessage,
                isApplicationRootUnavailable: false,
                needsFolderReselection: error.needsFolderReselection
            )
        } catch {
            guard loadID == directoryGeneration else { return }
            directoryFailure = FileSourceDirectoryFailure(
                message: "读取目录失败:\(error)", isApplicationRootUnavailable: false)
        }
    }

    // MARK: - 落盘缓存

    /// 目录与条目一起提交。⛔ 别拆成两处写:中间那一帧目录已换、条目还是旧的,
    /// 按目录算的区块会先消失(见 `pendingDirectory`)。
    private func commit(_ content: FileSourceDirectoryContent, directory: String) {
        currentDirectory = directory
        pendingDirectory = nil
        items = content.items
        // 合并而非覆盖:详情页另列的季文件夹不能把剧目录里的文件挤掉(`file(for:)` 要用)。
        // `fs_id` 全局唯一,同键覆盖无冲突。
        filesByID.merge(content.filesByID) { _, new in new }
    }

    /// 写失败不影响本次浏览,原因记在 store 的 `lastWriteFailureDescription`。
    /// 不存封面地址(`dlink` 会过期,见 `BaiduPanDirectoryCache`)。
    private func storeDirectoryCache(
        _ content: FileSourceDirectoryContent, directory: String
    ) async {
        guard cachesDirectories else { return }
        await container.baiduDirectoryCache.store(
            sourceID: source.id,
            directory: directory,
            // 排序让落盘 JSON 稳定,便于比对
            files: content.filesByID.values.sorted { $0.fsID < $1.fsID },
            durations: content.durations
        )
    }

    /// 落盘快照折成与 `BaiduPanSourceProvider.content(directory:)` 同形的结果。必须复用同一个合成器,
    /// 冷启动与刷新后的卡片才一致;另补缓存里的时长(`filemetas` 的 `needmedia=1`)。
    /// 没有封面,由随后的刮削缓存 / 后台刷新补。
    private static func content(
        from entry: BaiduPanDirectoryCache.Entry, sourceID: UUID
    ) -> FileSourceDirectoryContent {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: entry.files, sourceID: sourceID)
        let items = synthesized.map { synthesized -> SourceItem in
            var item = synthesized.item
            if let fsID = UInt64(item.ref.itemID), let duration = entry.duration(for: fsID) {
                item = item.withDuration(duration)
            }
            return item
        }
        return FileSourceDirectoryContent(
            items: items,
            filesByID: Dictionary(uniqueKeysWithValues: entry.files.map { ($0.fsID, $0) }),
            durations: Dictionary(
                uniqueKeysWithValues: entry.durations.compactMap { key, value in
                    UInt64(key).map { ($0, value) }
                })
        )
    }

    private enum BackgroundRefreshTarget {
        /// 当前目录的网格(`items`)
        case directory
        /// 详情页这一季的分集(`episodes`)
        case episodes(generation: Int)
    }

    /// 命中落盘缓存后拉真实目录:缓存里没封面地址,且网盘内容会变。
    private func startBackgroundRefresh(
        directory: String, target: BackgroundRefreshTarget = .directory
    ) {
        backgroundRefreshTask?.cancel()
        let provider = makeProvider()
        backgroundRefreshTask = Task { [weak self] in
            guard let self else { return }
            let fresh: FileSourceDirectoryContent
            do {
                fresh = try await provider.content(directory: directory)
            } catch {
                // 不报错:缓存内容已显示,真正的失败会在下次前台读取时报出
                return
            }
            guard !Task.isCancelled else { return }
            await self.applyBackgroundRefresh(
                fresh, provider: provider, directory: directory, target: target)
        }
    }

    /// 先校验结果仍有效(目录看 `currentDirectory`,分集看 `episodeGeneration`)再写回。
    private func applyBackgroundRefresh(
        _ content: FileSourceDirectoryContent,
        provider: any FileSourceBrowsing,
        directory: String,
        target: BackgroundRefreshTarget
    ) async {
        switch target {
        case .directory:
            guard currentDirectory == directory else { return }
            directoryCache[directory] = content
            items = content.items
            filesByID.merge(content.filesByID) { _, new in new }
            await storeDirectoryCache(content, directory: directory)
            await applyDirectoryShape(directory: directory)
            startScrape(items: content.items, provider: provider)
        case .episodes(let generation):
            guard generation == episodeGeneration else { return }
            directoryCache[directory] = content
            await storeDirectoryCache(content, directory: directory)
            await applyEpisodeContent(
                content, provider: provider, generation: generation, directory: directory)
        }
    }

    /// 列表出来后再在后台问 TMDB 补封面(`docs/TMDB_API.md`),TMDB 连不上不能让片库打不开。
    /// 失败只挂到 `scrapeFailure`,卡片保持图标卡。
    private func startScrape(items directoryItems: [SourceItem], provider: any FileSourceBrowsing) {
        let myGeneration = directoryGeneration
        scrapeFailure = nil
        scrapeTask = Task { [weak self] in
            let enriched = await provider.scrape(items: directoryItems)
            let failure = await provider.lastScrapeFailureDescription()
            guard let self, myGeneration == self.directoryGeneration else { return }
            self.items = enriched
            self.scrapeFailure = failure
            self.refreshFlatSeason(from: enriched)
        }
    }

    /// 轮次 +1,在途的刮削回来时自行丢弃
    private func cancelScrape() {
        directoryGeneration += 1
        scrapeTask?.cancel()
        scrapeTask = nil
        scrapeFailure = nil
    }

    /// 进去是网格还是详情页,由列出的内容决定(`applyDirectoryShape`),⛔ 不另发请求预判。
    func enter(_ item: SourceItem) async {
        guard item.kind.isContainer, let file = file(for: item) else { return }
        enteredSeriesItem = item
        resumeSnapshotPoster = nil
        preferredSeasonNumber = nil
        await navigate(to: file.path)
    }

    func goUp() async {
        guard let current = pendingDirectory ?? currentDirectory, let top = topmostDirectory,
              current != top else { return }
        let parent = (current as NSString).deletingLastPathComponent
        enteredSeriesItem = nil
        resumeSnapshotPoster = nil
        preferredSeasonNumber = nil
        // ⛔ 不退到最外层(片库根 / 应用目录)之上:上面没意义,应用目录外也访问不到
        await navigate(to: BaiduPanPath.isInside(parent, applicationRoot: top) ? parent : top)
    }

    // MARK: - 动作:剧集详情

    /// 判定目录 / 剧集并备好详情页状态。判定零请求;唯一的请求是自动选中季时列季文件夹。
    private func applyDirectoryShape(directory: String) async {
        let shape = BaiduPanSeriesLayout.shape(of: items)
        directoryShape = shape
        // 一次性选季意图:这一层不是剧就丢掉
        let preferredSeasonNumber = self.preferredSeasonNumber
        self.preferredSeasonNumber = nil
        guard let structure = shape.seriesStructure else {
            enteredSeriesItem = nil
            resumeSnapshotPoster = nil
            seriesItem = nil
            shapeDirectory = nil
            clearEpisodeState()
            // 普通目录的观看状态在这里读(剧集形态由 `selectSeason` 读)
            await loadWatchStates()
            return
        }
        // 同一部剧刷新要保住当前季,换了剧才回第一季
        let isSameSeries = shapeDirectory == directory
        shapeDirectory = directory
        // 平铺存法此刻就知道总数;季文件夹要等各季列完。⛔ 不为这个数字去列子目录。
        await recordEpisodeTotal(structure: structure, directory: directory)
        // 片库根直接就是一部剧时没有点进来的卡片,用只有目录名的兜底条目
        seriesItem = enteredSeriesItem
            ?? Self.fallbackSeriesItem(directory: directory, sourceID: source.id)
        // 只在同一部剧时换:换了剧时 `seriesProfile` 还是上一部的,会贴错海报
        if isSameSeries { applySeriesPosterFromProfile() }
        let previousSeasonID = isSameSeries ? selectedSeason?.id : nil
        // 续播指定的季 > 刷新保住的季 > 第一季。指定的必须最优先,否则「继续播放」变成「播放第 1 集」。
        let target = preferredSeasonNumber
            .flatMap { number in structure.seasons.first { $0.number == number } }
            ?? structure.seasons.first { $0.id == previousSeasonID }
            ?? structure.seasons.first
        await selectSeason(target)
        // 剧级信息不随季变:同一部剧刷新时已有就不重问(否则演职员区会闪),
        // 在飞也不重发,只有拿不到时才重试
        if !isSameSeries || (seriesProfile == nil && !isLoadingSeriesProfile) {
            startSeriesProfileLoad()
        }
    }

    /// 后台取剧级扩展信息(`BaiduPanMetadataScraper.seriesProfile`),不阻塞详情页。
    /// 优先 `tmdbID`,否则剧名 + 年份(与分集刮削同一把 `QueryKey`,保证是同一部剧,通常命中缓存);
    /// 都没有就不问,空标题只会搜回无关结果。
    private func startSeriesProfileLoad() {
        let tmdbID = seriesItem?.tmdbID ?? episodes.first?.tmdbID
        let title = seriesItem?.title ?? episodes.first?.title ?? ""
        let year = seriesItem?.year ?? episodes.first?.year
        guard tmdbID != nil || !title.isEmpty else {
            cancelSeriesProfile()
            return
        }
        let myGeneration = seriesProfileGeneration
        seriesProfile = nil
        isLoadingSeriesProfile = true
        let scraper = container.metadataScraper()
        seriesProfileTask = Task { [weak self] in
            let profile = await scraper.seriesProfile(
                tmdbID: tmdbID, title: title, year: year)
            guard let self, myGeneration == self.seriesProfileGeneration else { return }
            self.seriesProfile = profile
            self.isLoadingSeriesProfile = false
            self.applySeriesPosterFromProfile()
        }
    }

    /// 把续播快照暂代的封面换成 TMDB 剧集海报,让两个入口看到同一张图。
    /// ⛔ 只换快照那张,不覆盖目录卡片自己的封面;拿不到海报时保留快照(剧照好过占位图)。
    private func applySeriesPosterFromProfile() {
        guard let snapshot = resumeSnapshotPoster,
              let profile = seriesProfile,
              let poster = BaiduPanMetadataScraper.posterDescriptor(
                  for: profile.match, sourceID: source.id),
              let item = seriesItem else { return }
        let updated = item.withPoster(poster)
        seriesItem = updated
        // 刷新时 `seriesItem` 会从 `enteredSeriesItem` 重取,不一起换会退回剧照
        if enteredSeriesItem?.poster == snapshot { enteredSeriesItem = updated }
        resumeSnapshotPoster = nil
    }

    private func cancelSeriesProfile() {
        seriesProfileGeneration += 1
        seriesProfileTask?.cancel()
        seriesProfileTask = nil
        seriesProfile = nil
        isLoadingSeriesProfile = false
    }

    /// 季文件夹要另列一次(会话缓存兜住重复切换);平铺存法零请求。
    func selectSeason(_ season: BaiduPanSeason?) async {
        guard let season else { return }
        selectedSeason = season
        switch season.source {
        case .flatFiles(let files):
            // 列剧目录时已拿到并刮过,不再列 / 刮
            cancelEpisodeScrape()
            episodes = BaiduPanSeriesLayout.sortedEpisodes(visible(files))
            episodeFailure = nil
        case .folder(let folder):
            guard let file = file(for: folder) else {
                episodes = []
                episodeFailure = "找不到「\(folder.title)」在\(source.storageNoun)里的路径,没法读它的分集。"
                return
            }
            await loadEpisodes(directory: file.path)
        }
        await loadWatchStates()
        applySeriesPosterFallback()
    }

    /// 剧级条目没有封面时,用刚列出的分集封面顶上。⛔ 不为找剧级封面去列父目录(配额)。
    private func applySeriesPosterFallback() {
        guard let item = seriesItem, item.poster == nil,
              let poster = episodes.first(where: { $0.poster != nil })?.poster else { return }
        seriesItem = item.withPoster(poster)
    }

    /// 只收能播的条目,⛔ 不递归进季目录下的子目录。
    private func loadEpisodes(directory: String) async {
        isLoadingEpisodes = true
        episodeFailure = nil
        cancelEpisodeScrape()
        let myGeneration = episodeGeneration
        defer { isLoadingEpisodes = false }
        do {
            let provider = makeProvider()
            let content: FileSourceDirectoryContent
            if !cachesDirectories {
                content = try await provider.content(directory: directory)
            } else if let cached = directoryCache[directory] {
                content = cached
            } else if let disk = await container.baiduDirectoryCache.content(
                sourceID: source.id, directory: directory) {
                // 同 `loadFiles`:盘上那份先出,真实分集交给后台刷新
                content = Self.content(from: disk, sourceID: source.id)
                directoryCache[directory] = content
                await applyEpisodeContent(
                    content, provider: provider, generation: myGeneration, directory: directory)
                startBackgroundRefresh(
                    directory: directory, target: .episodes(generation: myGeneration))
                return
            } else {
                content = try await provider.content(directory: directory)
                directoryCache[directory] = content
                await storeDirectoryCache(content, directory: directory)
            }
            await applyEpisodeContent(
                content, provider: provider, generation: myGeneration, directory: directory)
        } catch let error as BaiduPanError {
            episodes = []
            episodeFailure = error.userMessage
        } catch let error as LocalFolderError {
            episodes = []
            episodeFailure = error.userMessage
        } catch {
            episodes = []
            episodeFailure = "读取这一季的分集失败:\(error)"
        }
    }

    /// 前台(`loadEpisodes`)与后台刷新共用,保证都合并了 `filesByID`(否则分集点不动)。
    private func applyEpisodeContent(
        _ content: FileSourceDirectoryContent,
        provider: any FileSourceBrowsing,
        generation: Int,
        directory: String
    ) async {
        filesByID.merge(content.filesByID) { _, new in new }
        let playable = visible(content.items.filter { $0.kind.isPlayable })
        episodes = BaiduPanSeriesLayout.sortedEpisodes(playable)
        await recordEpisodeCount(directory: directory, count: episodes.count)
        startEpisodeScrape(items: episodes, provider: provider, generation: generation)
    }

    // MARK: - 集数记录

    /// 记下这一季的集数(变了才写盘),并试着凑出整部剧的总数(剧卡「共 N 集」的唯一来源)。
    private func recordEpisodeCount(directory: String, count: Int) async {
        if count > 0, episodeCounts[directory] != count {
            episodeCounts[directory] = count
            await container.baiduEpisodeCounts.store(
                sourceID: source.id, directory: directory, count: count)
        }
        guard let structure = directoryShape.seriesStructure,
              let seriesDirectory = shapeDirectory else { return }
        await recordEpisodeTotal(structure: structure, directory: seriesDirectory)
    }

    /// 有一季没列过就算不出,什么都不写。⛔ 不拿已知几季之和冒充总数。
    private func recordEpisodeTotal(
        structure: BaiduPanSeriesStructure, directory: String
    ) async {
        var total = 0
        for season in structure.seasons {
            switch season.source {
            case .flatFiles(let items):
                total += items.count
            case .folder(let item):
                guard let path = file(for: item)?.path,
                      let count = episodeCounts[path] else { return }
                total += count
            }
        }
        guard total > 0, episodeCounts[directory] != total else { return }
        episodeCounts[directory] = total
        await container.baiduEpisodeCounts.store(
            sourceID: source.id, directory: directory, count: total)
    }

    /// 后台补集名 / 剧照 / 简介,理由同 `startScrape`
    private func startEpisodeScrape(
        items: [SourceItem], provider: any FileSourceBrowsing, generation: Int
    ) {
        episodeScrapeTask = Task { [weak self] in
            let enriched = await provider.scrape(items: items)
            let failure = await provider.lastScrapeFailureDescription()
            guard let self, generation == self.episodeGeneration else { return }
            self.episodes = enriched
            self.scrapeFailure = failure
            self.applySeriesPosterFallback()
        }
    }

    /// 平铺存法的分集就是当前目录条目,目录刮削整份替换 `items` 后要同步到 `episodes`。
    /// 季文件夹有自己的刮削(`startEpisodeScrape`)。
    private func refreshFlatSeason(from items: [SourceItem]) {
        guard case .flatFiles = selectedSeason?.source else { return }
        episodes = BaiduPanSeriesLayout.sortedEpisodes(
            visible(items.filter { $0.kind == .episode }))
        applySeriesPosterFallback()
    }

    private func cancelEpisodeScrape() {
        episodeGeneration += 1
        episodeScrapeTask?.cancel()
        episodeScrapeTask = nil
    }

    private func clearEpisodeState() {
        cancelEpisodeScrape()
        cancelSeriesProfile()
        selectedSeason = nil
        episodes = []
        episodeFailure = nil
    }

    /// 剧级兜底条目:目录名 + 可能有的封面,⛔ 不伪造其他字段。`ref` 用目录路径,只用于展示。
    /// `title` / `poster` 来自续播卡快照(剧名比目录名准)。
    private static func fallbackSeriesItem(
        directory: String,
        sourceID: UUID,
        title: String? = nil,
        poster: ImageDescriptor? = nil
    ) -> SourceItem {
        let directoryName = (directory as NSString).lastPathComponent
        let resolvedTitle: String
        if let title, !title.isEmpty {
            resolvedTitle = title
        } else if !directoryName.isEmpty {
            resolvedTitle = directoryName
        } else {
            resolvedTitle = "剧集"
        }
        return SourceItem(
            ref: SourceItemRef(sourceID: sourceID, itemID: directory),
            title: resolvedTitle,
            kind: .folder,
            overview: nil,
            year: nil,
            tmdbID: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            episodeTitle: nil,
            durationSeconds: nil,
            poster: poster,
            metadataOrigin: .none
        )
    }

    /// 本页能退到的最外层:片库根,否则应用目录
    private var topmostDirectory: String? {
        libraryRoot?.path ?? rootDirectory
    }

    var canGoUp: Bool {
        // 加载中 / 上次导航失败没提交时按目标算,否则返回按钮会在失败页上消失
        guard let current = pendingDirectory ?? currentDirectory, let top = topmostDirectory
        else { return false }
        return current != top
    }

    // MARK: - 动作:片库根
    //
    // 片库根是应用目录内「进来先落在哪」,不是授权范围(授权范围固定为 `/apps/{应用目录名}`)。
    // 每个来源一个,在设置里维护(`BaiduPanSourceSettingsView`);要两个起点就加两个来源(共用 token)。

    /// 设置里改过片库根后调用。来源列表任何变更都会触发,所以只在真的变了时重载(配额)。
    /// `hasLoadedOnce` 闸必需:`.task(id:)` 首次出现也会跑,那时片库根还没读进来,会误判成变了。
    func refreshLibraryRoot() async {
        guard hasLoadedOnce else { return }
        guard case .baiduPan = source else {
            // 本地:多半是换了文件夹 / 改了名。重读当前层让失败页消失,⛔ 不回到起点
            await refreshFiles()
            return
        }
        let stored = try? await connection.libraryRoot(for: source.id)
        guard stored != libraryRoot else { return }
        libraryRoot = stored
        await reload()
    }

    /// 本地文件夹重新选择后从根重列(原来那层未必还在)。失败挂 `notice`,失败页留着可再选。
    func relinkFolder(to folderURL: URL) async {
        guard case .localFolder(let local) = source else { return }
        do {
            let updated = try await container.relinkLocalFolder(local, to: folderURL)
            source = .localFolder(updated)
            notice = nil
            await reload()
        } catch let error as LocalFolderError {
            notice = error.userMessage
        } catch {
            notice = "换文件夹失败:\(error.localizedDescription)"
        }
    }

    /// 清掉失效的片库根,不报错。写回设置,免得下次又撞上。
    private func clearLibraryRoot() async {
        libraryRoot = nil
        guard case .baiduPan(let baidu) = source else { return }
        try? await container.setLibraryRoot(nil, for: baidu)
    }

    /// 标题栏名字:根层用应用目录名(百度)/ 来源名(本地),其余用路径最后一段。
    var currentDirectoryName: String {
        let fallback: String
        switch source {
        case .baiduPan: fallback = "百度网盘"
        case .localFolder(let local): fallback = local.displayName
        }
        guard let current = currentDirectory else { return fallback }
        if let root = rootDirectory, current == root {
            if case .baiduPan = source { return folderName ?? fallback }
            return fallback
        }
        let last = (current as NSString).lastPathComponent
        return last.isEmpty ? fallback : last
    }

    /// - Parameter fromBeginning: 详情页「从头播放」用。默认按本地进度续播。
    func play(_ item: SourceItem, fromBeginning: Bool = false) {
        guard let file = file(for: item) else { return }
        // 起播时记下展示快照,续播区才画得出来;⛔ 不在渲染续播区时回头列网盘
        Task { await container.rememberResumeCard(item: item, file: file) }
        // 详情页用这一季分集,网格用当前目录,零请求
        let queueItems = directoryShape.isSeries ? episodes : sortedItems
        container.play(
            file,
            in: source,
            subtitleFiles: BaiduPanSubtitle.files(for: file, in: Array(filesByID.values)),
            episodeQueue: Self.episodeQueue(
                selecting: item, in: queueItems, filesByID: filesByID, source: source),
            fromBeginning: fromBeginning)
    }

    /// 用已列出的条目装配剧集队列,零请求;顺序即传入的 `items`(与界面一致)。纯函数,便于测试。
    /// 只收 `.episode`(合成器认定为剧集序列才给),不足两集返回 nil。
    static func episodeQueue(
        selecting item: SourceItem,
        in items: [SourceItem],
        filesByID: [UInt64: BaiduPanFile],
        source: FileSource
    ) -> EpisodeQueue? {
        guard item.kind == .episode else { return nil }
        let episodes = items.filter { $0.kind == .episode }
        guard episodes.count > 1 else { return nil }
        let entries = episodes.compactMap { entry -> PlaybackEpisode? in
            guard let fsID = UInt64(entry.ref.itemID), let file = filesByID[fsID] else { return nil }
            return PlaybackEpisode(
                id: entry.ref.itemID,
                label: entry.episodeNumber.map { "第 \($0) 集" },
                title: entry.episodeTitle ?? entry.title,
                source: source.playbackSource(for: file),
                resumeItem: entry,
                poster: entry.poster,
                subtitleFiles: BaiduPanSubtitle.files(for: file, in: Array(filesByID.values))
            )
        }
        guard let index = entries.firstIndex(where: { $0.id == item.ref.itemID }) else { return nil }
        return EpisodeQueue(episodes: entries, currentIndex: index)
    }

    /// 播续播卡片。文件由快照重建(`fs_id` / `path` / `name` 是原值,播放用不到的字段留空)。
    /// 换集队列要兄弟集,起播前补列文件所在目录(就是当前目录时复用)。
    /// ⛔ 不改 `currentDirectory`:接着看不该让浏览页换一屏。
    ///
    /// - Returns: 是否已发出播放请求(视图据此决定要不要唤起播放窗口)。
    @discardableResult
    func play(_ card: FileSourceResumeCard) async -> Bool {
        guard let file = card.reconstructedFile else { return false }
        guard preparingPlaybackFileID == nil else { return false }
        preparingPlaybackFileID = card.fileID
        defer { preparingPlaybackFileID = nil }

        let content = await directoryContent(for: BaiduPanPath.directory(ofFilePath: file.path))
        let queue = content.flatMap { content in
            content.items.first { $0.ref.itemID == String(file.fsID) }.flatMap { item in
                Self.episodeQueue(
                    selecting: item, in: content.items, filesByID: content.filesByID, source: source)
            }
        }
        // 外挂字幕取自同一份 `filesByID`;拿不到目录时照常播放,只是没有字幕
        let subtitles = content.map {
            BaiduPanSubtitle.files(for: file, in: Array($0.filesByID.values))
        } ?? []
        container.play(file, in: source, subtitleFiles: subtitles, episodeQueue: queue)
        return true
    }

    /// 点续播卡片非播放区域:跳到它的详情页(与 `play(_ card:)` 不同,会改 `currentDirectory`)。
    /// 落在剧目录而非季文件夹,否则季文件夹存法会显示成一部叫「第1季」的剧
    /// (`BaiduPanPath.seriesDirectory(ofFilePath:)`);不是剧时显示文件所在目录的网格。
    /// 不越出最外层,见 `detailDirectory(ofFilePath:topmost:)`。
    func openDetail(for card: FileSourceResumeCard) async {
        preferredSeasonNumber = Self.seasonNumber(ofFilePath: card.path)
        let directory = Self.detailDirectory(ofFilePath: card.path, topmost: topmostDirectory)
        // 没有父目录卡片,用续播快照的封面兜底(过渡用,见 `resumeSnapshotPoster`)
        resumeSnapshotPoster = card.poster
        enteredSeriesItem = Self.fallbackSeriesItem(
            directory: directory,
            sourceID: source.id,
            title: card.title,
            poster: card.poster
        )
        await navigate(to: directory)
    }

    /// 当前目录直接复用,否则补列一次。拿不到返回 nil:照常播放,只是没有换集入口,不打断起播。
    private func directoryContent(
        for directory: String
    ) async -> FileSourceDirectoryContent? {
        // 两个分支都要过隐藏过滤
        if directory == currentDirectory, !items.isEmpty {
            return FileSourceDirectoryContent(
                items: sortedItems, filesByID: filesByID, durations: [:])
        }
        do {
            let provider = makeProvider()
            let content = try await provider.content(directory: directory)
            // 剧照只来自 TMDB;刮削不抛错,失败退本地图
            let enriched = await provider.scrape(items: content.items)
            return FileSourceDirectoryContent(
                items: visible(enriched), filesByID: content.filesByID,
                durations: content.durations)
        } catch {
            return nil
        }
    }

    /// 剧目录在最外层之上(某一季被设成片库根)时,退回文件所在目录。
    static func detailDirectory(ofFilePath path: String, topmost: String?) -> String {
        let series = BaiduPanPath.seriesDirectory(ofFilePath: path)
        guard let topmost, !topmost.isEmpty else { return series }
        return BaiduPanPath.isInside(series, applicationRoot: topmost)
            ? series
            : BaiduPanPath.directory(ofFilePath: path)
    }

    /// 判据同合成器:父目录名是季标记就用它,否则看文件名 `SxxExx`。nil = 认不出(详情页落第一季)。
    static func seasonNumber(ofFilePath path: String) -> Int? {
        let parentName = (BaiduPanPath.directory(ofFilePath: path) as NSString).lastPathComponent
        if let season = BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: parentName) {
            return season
        }
        return BaiduPanMetadataSynthesizer.parse(
            name: (path as NSString).lastPathComponent).season
    }

    /// 删掉整部剧的本地进度记录(不动网盘文件)。只删一集的话同剧下一集会立刻顶上来。
    /// 用 `remove(fileIDs:)` 而非 `forget(fileIDs:)`:文件还在,之后再看要能重新记进度。
    func removeResumeCard(_ card: FileSourceResumeCard) async {
        let key = Self.seriesKey(title: card.title, locator: card.path)
        do {
            let ids = await container.watchProgress.resumeEntries(sourceID: source.id)
                .filter { Self.seriesKey(of: $0) == key }
                .map(\.fileID)
            try await container.watchProgress.remove(fileIDs: ids)
            resumeCards = resumeCards.filter { $0.id != card.id }
        } catch {
            notice = "移出继续观看失败:\(error)"
        }
    }

    /// 没记录 = 未看
    func watchState(for item: SourceItem) -> WatchProgressStore.WatchState {
        watchStates[item.ref.itemID] ?? .unwatched
    }

    /// 显式标记,或自动判定过了 90%
    func isWatched(_ item: SourceItem) -> Bool {
        watchState(for: item) == .watched
    }

    /// 看完 / 未看都是 nil
    func resumeSeconds(for item: SourceItem) -> Double? {
        guard case .inProgress(let seconds) = watchState(for: item) else { return nil }
        return seconds
    }

    /// 目录卡片「已看 N 集」的 N(0 = 不显示),只数本地有记录的
    func watchedEpisodeCount(for item: SourceItem) -> Int {
        guard item.kind.isContainer, let path = file(for: item)?.path else { return 0 }
        return watchedEpisodeCounts[path] ?? 0
    }

    /// 总集数,来自进详情页时记下的本地记录,零请求。nil = 还不知道。网盘增删集后会偏,下次进详情页重算。
    func episodeTotal(for item: SourceItem) -> Int? {
        guard item.kind.isContainer, let path = file(for: item)?.path else { return nil }
        guard let total = episodeCounts[path], total > 0 else { return nil }
        return total
    }

    /// 筛选用。目录:知道总数时要求已看 ≥ 总数,不知道时有记录就算(否则「已看」档在没进过详情页的剧上永远空)。
    func isWatchedItem(_ item: SourceItem) -> Bool {
        guard item.kind.isContainer else { return isWatched(item) }
        let watched = watchedEpisodeCount(for: item)
        guard watched > 0 else { return false }
        guard let total = episodeTotal(for: item) else { return true }
        return watched >= total
    }

    /// ✓ 角标用,比 `isWatchedItem` 严:目录必须知道总数且已看 ≥ 总数。
    func isFullyWatched(_ item: SourceItem) -> Bool {
        guard item.kind.isContainer else { return isWatched(item) }
        guard let total = episodeTotal(for: item) else { return false }
        return watchedEpisodeCount(for: item) >= total
    }

    private func matchesWatchFilter(_ item: SourceItem) -> Bool {
        switch watchFilter {
        case .all: return true
        case .watched: return isWatchedItem(item)
        case .unwatched: return !isWatchedItem(item)
        }
    }

    // MARK: - 动作:观看状态
    //
    // 百度没有播放状态接口(`docs/BAIDU_PAN_API.md` §2),已看 / 未看只记在本地续播库,不跨机器同步。

    /// 零请求。顺手写展示快照:没有 `locator` 的记录在删网盘文件时按路径圈不到(`BaiduPanWatchHistory`)。
    func markPlayed(_ items: [SourceItem], played: Bool) async {
        let marks = items.filter { $0.kind.isPlayable }.map { item in
            WatchProgressStore.PlayedMark(
                fileID: item.ref.itemID,
                display: file(for: item).map { WatchProgressStore.Display(item: item, file: $0) }
            )
        }
        await applyPlayed(marks, played: played)
        // 让续播卡指向下一个没看的集,否则标完最后一张整部剧就从续播区消失
        if played { await advanceUpNext() }
    }

    /// 续播卡对应的记录本来就有快照,不再给。标完让卡指向下一集,否则整部剧从续播区消失。
    func markPlayed(_ card: FileSourceResumeCard) async {
        do {
            _ = try await container.watchProgress.setPlayed(
                [WatchProgressStore.PlayedMark(fileID: card.fileID, display: nil)], played: true)
        } catch {
            notice = "标记已看失败:\(error)"
            return
        }
        if let file = card.reconstructedFile {
            await container.advanceFileSourceUpNext(
                after: file, playing: source.playbackSource(for: file), queue: nil)
        }
        await refreshResumeState()
    }

    /// 只作用于已列出的这一季,⛔ 不为整部剧去列别的季文件夹。
    func markSeasonPlayed(_ played: Bool) async {
        await markPlayed(episodes, played: played)
    }

    private func applyPlayed(_ marks: [WatchProgressStore.PlayedMark], played: Bool) async {
        guard !marks.isEmpty else { return }
        do {
            _ = try await container.watchProgress.setPlayed(marks, played: played)
            await refreshResumeState()
        } catch {
            notice = "标记\(played ? "已看" : "未看")失败:\(error)"
        }
    }

    /// 把续播卡指向这一季下一个没看的集(类似 Emby NextUp)。只在详情页(知道分集清单)时有效;
    /// 网格里 `episodes` 为空,⛔ 不为此列目录。
    /// 季末不写,⛔ 不猜下一季。
    private func advanceUpNext() async {
        guard !episodes.isEmpty else { return }
        guard let next = episodes.first(where: { $0.kind.isPlayable && !isWatched($0) }),
              let file = file(for: next) else { return }
        do {
            let changed = try await container.watchProgress.setUpNext([
                WatchProgressStore.PlayedMark(
                    fileID: next.ref.itemID,
                    display: WatchProgressStore.Display(item: next, file: file))
            ])
            guard changed > 0 else { return }
            await refreshResumeState()
        } catch {
            notice = "续播卡没指向下一集:\(error)"
        }
    }

    // MARK: - 动作:删除 / 隐藏

    /// 隐藏或连网盘文件一起删(`alsoDeleteRemotely`)。两条路都清掉这一条名下的本地观看记录
    /// (按路径圈定,见 `BaiduPanWatchHistory`;⛔ 不按标题 / 集号猜):
    ///
    /// - 隐藏:写 `HiddenItemsStore`(可恢复),`items` 不动以便恢复时立刻重现;记录用 `remove`
    ///   (恢复后再看要能重新记,但已删的进度不还原)。
    /// - 真删:不写隐藏库(恢复不出东西),清缓存与卡片;记录用 `forget` 封 id,
    ///   否则正在播的那场还会把进度写回来。只删一集时同剧其它集记录保留。
    ///
    /// 找不到路径或网盘删除失败都直接抛,⛔ 不悄悄降级成隐藏;失败时本地记录不动。
    func delete(_ item: SourceItem, alsoDeleteRemotely: Bool) async throws {
        guard let file = file(for: item) else {
            throw BaiduPanError.configuration(
                "找不到「\(item.title)」在\(source.storageNoun)里的路径,没法删除。")
        }
        // 本地文件夹只读,界面不给这个开关;走到这里是调用方 bug,如实抛
        if alsoDeleteRemotely, !source.supportsDeletingFiles {
            throw LocalFolderError.readOnly
        }
        // ⛔ 不从 `item.kind` 反推是否目录(`.unknown` 也可能是文件)
        let isDirectory = file.isDirectory
        let fileIDs = await affectedRecordIDs(
            path: file.path, isDirectory: isDirectory, ownItemID: item.ref.itemID)
        guard alsoDeleteRemotely else {
            try await container.hiddenItems.hide(
                HiddenItemsStore.Item(
                    ref: item.ref,
                    title: item.title,
                    hiddenAt: Date(),
                    path: file.path,
                    isDirectory: isDirectory))
            hiddenRefs.insert(item.ref)
            await removeRecords(fileIDs)
            for id in fileIDs { watchStates.removeValue(forKey: id) }
            await loadResumeCards()
            return
        }

        guard case .baiduPan = source else { throw LocalFolderError.readOnly }
        try await connection.deleteFile(at: file.path)

        if libraryRoot?.path == file.path {
            await clearLibraryRoot()
        }

        // 只进内存(不写隐藏库);下一轮 `loadFiles` 走网络,删掉的自然不再出现
        hiddenRefs.insert(item.ref)
        items.removeAll { $0.ref == item.ref }
        if let fsID = UInt64(item.ref.itemID) { filesByID.removeValue(forKey: fsID) }
        // 丢被删的那层(含子层)和它所在的那层;所在层不连子层丢,免得同剧别的季白烧请求
        await evictCachedDirectory(file.path)
        await evictCachedDirectory(
            BaiduPanPath.directory(ofFilePath: file.path), includeDescendants: false)
        await forgetRecords(fileIDs)
        // 重算角标;不在 `items` / `episodes` 里的分集再按 id 兜一层
        await loadWatchStates()
        for id in fileIDs { watchStates.removeValue(forKey: id) }
        await loadResumeCards()
    }

    /// 读 `storedRecords`(含已看完 / 位置 0 的),否则会漏下死记录。
    /// 另并入条目自己的 `fs_id`:没有快照(无 `locator`)的老记录按路径圈不到。
    private func affectedRecordIDs(
        path: String, isDirectory: Bool, ownItemID: String
    ) async -> [String] {
        let records = await container.watchProgress.storedRecords(sourceID: source.id)
        var ids = BaiduPanWatchHistory.fileIDs(
            deletingPath: path, isDirectory: isDirectory, from: records)
        if !ids.contains(ownItemID) { ids.append(ownItemID) }
        return ids
    }

    /// 真删用:`forget` 还会在本进程内拒绝再写这批 id(正在播的那场还在报进度)。
    /// 失败只提示,⛔ 不算删除失败(删除已经发生)。
    private func forgetRecords(_ fileIDs: [String]) async {
        guard !fileIDs.isEmpty else { return }
        do {
            try await container.watchProgress.forget(fileIDs: fileIDs)
        } catch {
            notice = "条目已处理,但本地观看记录没清掉:\(error)"
        }
    }

    /// 隐藏用:只删记录,不封 id(见 `forgetRecords`)
    private func removeRecords(_ fileIDs: [String]) async {
        guard !fileIDs.isEmpty else { return }
        do {
            try await container.watchProgress.remove(fileIDs: fileIDs)
        } catch {
            notice = "条目已隐藏,但本地观看记录没清掉:\(error)"
        }
    }

    /// 丢目录缓存(内存 + 落盘),默认连子层一起丢
    private func evictCachedDirectory(_ path: String, includeDescendants: Bool = true) async {
        guard !path.isEmpty, cachesDirectories else { return }
        directoryCache = directoryCache.filter { key, _ in
            key != path
                && !(includeDescendants && BaiduPanPath.isInside(key, applicationRoot: path))
        }
        await container.baiduDirectoryCache.remove(
            sourceID: source.id, directory: path, includeDescendants: includeDescendants)
    }

    /// 全库有进度的条目 + 「下一集」占位 → 续播卡(`loadWatchStates` 管当前目录的角标)。
    /// 隐藏过滤两道:按 `fs_id`,再按路径(隐藏整个目录时,其下各集记录的 `fs_id` 挡不住)。
    private func loadResumeCards() async {
        let records = await container.watchProgress.resumeEntries(sourceID: source.id)
        let hiddenPaths = await container.hiddenItems.hiddenPaths(sourceID: source.id)
        let visibleRecords = records.filter { record in
            guard !hiddenRefs.contains(
                SourceItemRef(sourceID: source.id, itemID: record.fileID)) else { return false }
            return !Self.isHidden(record, by: hiddenPaths)
        }
        resumeCards = Self.oneCardPerSeries(visibleRecords).compactMap(FileSourceResumeCard.init(record:))
    }

    /// 只按路径判断(⛔ 不按标题 / 集号)。没有 `path` 的隐藏记录只按 `fs_id` 生效,不参与这里。
    static func isHidden(
        _ record: WatchProgressStore.ResumeRecord,
        by hiddenPaths: [HiddenItemsStore.HiddenPath]
    ) -> Bool {
        hiddenPaths.contains {
            BaiduPanPath.covers(
                path: $0.path, locator: record.display.locator, isDirectory: $0.isDirectory)
        }
    }

    /// 一部剧(同目录 + 同剧名)只出一张卡,取最近看的。续播库按文件记、不改,这里只聚合卡片。
    /// 「看到一半」优先于「下一集」占位:先按进度记录去重,占位只补空位。
    static func oneCardPerSeries(
        _ records: [WatchProgressStore.ResumeRecord]
    ) -> [WatchProgressStore.ResumeRecord] {
        var seen: Set<String> = []
        let progressed = records
            .filter { !$0.isUpNext }
            .filter { seen.insert(seriesKey(of: $0)).inserted }
        let upNext = records
            .filter(\.isUpNext)
            .filter { seen.insert(seriesKey(of: $0)).inserted }
        return (progressed + upNext).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 季文件夹里的集按剧目录归一部(`BaiduPanPath.seriesDirectory`):各季文件名解析出的剧名常不一致,
    /// 剧目录本身已认定是同一部。其余按剧名 + 所在目录,防止同一目录里不同内容并成一张。
    static func seriesKey(of record: WatchProgressStore.ResumeRecord) -> String {
        seriesKey(title: record.display.title, locator: record.display.locator)
    }

    static func seriesKey(title: String, locator: String) -> String {
        let directory = BaiduPanPath.directory(ofFilePath: locator)
        let series = BaiduPanPath.seriesDirectory(ofFilePath: locator)
        guard series == directory else { return "|\(series)" }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(name)|\(directory)"
    }

    /// ⛔ 找不到返回 nil,不拿 `SourceItem` 反推一个假 `BaiduPanFile`
    func file(for item: SourceItem) -> BaiduPanFile? {
        guard let fsID = UInt64(item.ref.itemID) else { return nil }
        return filesByID[fsID]
    }

    /// 工厂方法,不把 `container` 暴露给调用方
    func makeRenameViewModel() -> BaiduPanRenameSeriesViewModel {
        BaiduPanRenameSeriesViewModel(container: container)
    }

    private func visible(_ items: [SourceItem]) -> [SourceItem] {
        guard !hiddenRefs.isEmpty else { return items }
        return items.filter { !hiddenRefs.contains($0.ref) }
    }

    struct BaiduPanConfigurationDraft: Sendable, Equatable {
        let appKey: String
        let secretKey: String
        let folderName: String
    }

    /// 当前目录 / 当前季每条的状态,加剧目录卡片的已看集数。全部本地,零请求。
    private func loadWatchStates() async {
        var ids = Set<String>()
        for item in items + episodes where item.kind.isPlayable {
            ids.insert(item.ref.itemID)
        }
        let records = await container.watchProgress.storedRecords(sourceID: source.id)
        ids.formUnion(records.map(\.fileID))
        let states = await container.watchProgress.watchStates(forFileIDs: Array(ids))
        watchStates = states
        watchedEpisodeCounts = Self.watchedEpisodeCounts(records: records, states: states)
    }

    /// 每条已看记录给所在目录及所有上层目录各 +1,季文件夹存法也数得进剧目录。
    /// 没有 `locator` 的记录不计,⛔ 不拿文件名猜。
    static func watchedEpisodeCounts(
        records: [WatchProgressStore.StoredRecord],
        states: [String: WatchProgressStore.WatchState]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in records where states[record.fileID] == .watched {
            var directory = BaiduPanPath.directory(ofFilePath: record.display.locator)
            while !directory.isEmpty, directory != "/" {
                counts[directory, default: 0] += 1
                let parent = (directory as NSString).deletingLastPathComponent
                guard parent != directory else { break }
                directory = parent
            }
        }
        return counts
    }
}

/// 文件树来源续播区的卡片,由本地续播库记录折出(`WatchProgressStore.Display` 快照),
/// 所以能跨目录、目录读失败时也能显示。
struct FileSourceResumeCard: Identifiable, Sendable, Equatable {
    let fileID: String
    let title: String
    let positionSeconds: Double
    /// nil = 未知,不画进度条
    let durationSeconds: Double?
    /// nil = 不是一集或快照里没记
    let episodeNumber: Int?
    let path: String
    let fileName: String
    let poster: ImageDescriptor?
    /// 「下一集该看」的占位(上一集刚看完):报「下一集」,不画进度条
    let isUpNext: Bool

    var id: String { fileID }

    var subtitle: String {
        let what = isUpNext ? "下一集" : "已看到 \(PlayerTime.text(positionSeconds))"
        guard let episodeNumber else { return what }
        return "第 \(episodeNumber) 集 · \(what)"
    }

    /// 键不是合法 `fs_id` 时返回 nil,⛔ 不端出点不动的卡片
    init?(record: WatchProgressStore.ResumeRecord) {
        guard UInt64(record.fileID) != nil else { return nil }
        self.fileID = record.fileID
        self.title = record.display.title
        self.positionSeconds = record.positionSeconds
        self.episodeNumber = record.display.episodeNumber
        self.durationSeconds = record.durationSeconds
        self.path = record.display.locator
        self.fileName = record.display.fileName
        self.poster = record.display.cover.map(ImageDescriptor.init(snapshot:))
        self.isUpNext = record.isUpNext
    }

    /// 够播放用的 `BaiduPanFile`(见 `FileSourceViewModel.play(_ card:)`)
    var reconstructedFile: BaiduPanFile? {
        guard let fsID = UInt64(fileID) else { return nil }
        return BaiduPanFile(
            fsID: fsID,
            path: path,
            name: fileName,
            sizeBytes: nil,
            isDirectory: false,
            category: nil,
            modifiedAt: nil,
            thumbnailURL: nil
        )
    }
}

/// 目录读失败时的用户可见信息。不复用 Emby 的 `LoadFailure`(带 `needsLogin`),分支不同。
struct FileSourceDirectoryFailure: Sendable, Equatable {
    let message: String

    /// 应用目录本身读不出(`errno` -7 无权 / -9 不存在,且失败的正是应用目录)。
    /// 重试没用,要让人核对控制台里的「应用名称」。
    let isApplicationRootUnavailable: Bool

    /// 本地文件夹访问权没了,重试没用,失败页给「重新选择文件夹…」
    var needsFolderReselection = false
}
