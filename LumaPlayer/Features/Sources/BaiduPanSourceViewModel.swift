import Foundation
import Observation

/// 百度网盘来源那一页的状态(ViewModel)。
///
/// 三屏共用一个 ViewModel:填密钥 → 扫码 → 浏览目录。
/// 因为「保存密钥 → 立刻走扫码 → 授权完立刻列目录」是一条连续的流程,
/// 拆成三个 View 各自取状态反而要来回传。
@MainActor
@Observable
final class BaiduPanSourceViewModel {

    // MARK: - 授权

    /// 现在该显示哪一屏。nil = 还在判定
    private(set) var authorization: BaiduPanAuthorization?
    private(set) var loadFailure: LoadFailure?
    private(set) var isLoading = false

    /// 正在等扫码(device code 已拿到)
    private(set) var deviceCode: BaiduPanDeviceCode?
    private(set) var isWaitingForAuthorization = false
    /// 二维码渲染失败、片库根存不进去之类的本地提示(不打断当前流程)
    private(set) var notice: String?

    // MARK: - 目录

    /// 应用目录名(展示用:空状态里要告诉用户把片子放进哪个目录)
    private(set) var folderName: String?
    /// 应用根目录 `/apps/{应用目录名}`。第三方应用能访问的**全部范围**
    private(set) var rootDirectory: String?
    /// 片库根:用户在应用目录**内部**选定的起点。nil = 就用应用目录
    private(set) var libraryRoot: String?
    /// 当前目录
    private(set) var currentDirectory: String?
    /// 当前目录的卡片(来源无关条目,带封面),**百度返回的原始顺序**。
    /// ⚠️ 它**不含播放所需的信息**(`path` / 原始文件名),所以下面还有一份原始索引。
    /// ⚠️ 界面⛔ 不要直接读它 —— 用 `sortedItems`(那个才是排好的)。
    private(set) var items: [SourceItem] = []
    /// `fs_id` → 原始文件。播放与「进目录」都要用它 ——
    /// 合成后的 `SourceItem` 只保留展示所需字段,`path` 这类定位信息不在里面。
    private var filesByID: [UInt64: BaiduPanFile] = [:]
    /// 被用户隐藏的条目身份。**同步过滤**用 —— 计算属性里⛔ 不能 await,
    /// 所以每轮 `loadFiles` 从本地库读一次,存成内存集合。
    private var hiddenRefs: Set<SourceItemRef> = []

    /// **会话级**目录缓存:`目录路径` → 一次目录读取的完整结果。
    ///
    /// 为什么要有它:未审核应用配额只有 **10 次/小时**(`docs/BAIDU_PAN_API.md`),
    /// 而「进目录 → 退回上层 → 再进同一个目录」这种来回走会把配额烧光。
    /// 有了它,同一会话里重进**已列过**的目录就是**零请求**。
    ///
    /// ⚠️ 取舍:网盘里新增 / 删除的文件要等用户点刷新才反映 —— 这正是
    /// 「有数据就不自动请求、把刷新交给用户」的既定策略。`reload()`(结构性变化)
    /// 会清掉它;用户点「刷新 / 重试」走 `refreshFiles()` 强制重列。
    ///
    /// ⚠️ 缓存里的封面地址是百度 `dlink`(8 小时有效)。会话通常远短于 8 小时,
    /// 且封面图本身另有磁盘缓存兜底,所以不为过期另做处理。
    private var directoryCache: [String: BaiduPanSourceProvider.DirectoryContent] = [:]

    /// 目录排序方式。默认**剧集顺序** —— 「看剧都是从前往后看的」。
    ///
    /// ⚠️ 它是**展示层**状态:改它只重排已经取回的条目,⛔ 不重新请求目录
    /// (配额 10 次/小时,见 `BaiduPanSortOrder` 的注释)。
    var sort: BaiduPanSortOrder = .episode {
        didSet {
            guard sort != oldValue else { return }
            ascending = sort.defaultAscending
        }
    }
    /// 排序方向。换排序方式时回到该档的自然方向(与 `LibraryViewModel` 同一条纪律)。
    var ascending = true

    /// 按当前排序排好的条目,**并去掉被隐藏的** —— **界面用这个**。
    ///
    /// 为什么是计算属性而不是在 `loadFiles()` 里排一次:刮削回来会**整份换掉**
    /// `items`(`startScrape`),排一次的做法会在那一刻把顺序丢掉;
    /// 而且改排序不该触发任何网络请求。
    ///
    /// 为什么隐藏过滤在这里而不是从 `items` 里真删:`items` 会被刮削整份换掉,
    /// 真删的做法会在那一刻把隐藏项又写回来。而且留着它,设置页点「恢复」
    /// 能立刻重新出现 —— 不必再等一次列目录(配额:2 次请求)。
    var sortedItems: [SourceItem] {
        visible(sort.apply(to: items, filesByID: filesByID, ascending: ascending))
    }

    private(set) var isLoadingFiles = false
    private(set) var directoryFailure: BaiduPanDirectoryFailure?

    /// 用户主动要改配置时(多半是应用目录名填错了)预填给表单的现值。
    private(set) var configurationDraft: BaiduPanConfigurationDraft?

    /// 本地续播进度(fs_id → 已看秒数),用于列表上画一行「已看到 12:34」
    private(set) var resumePositions: [String: Double] = [:]

    /// 「继续观看」区的卡片:本地续播库里有进度、且带展示快照的条目,
    /// 按最近看排序。⛔ 不限于当前目录 —— 它就是要跨目录把你看过的东西捞出来。
    private(set) var resumeCards: [BaiduResumeCard] = []

    /// 正在为「继续观看」起播做准备(补列它所在的目录)的那张卡片。
    /// 卡片据此转圈 —— 补列要发两次请求,不显示就等于「点了没反应」。
    private(set) var preparingPlaybackFileID: String?

    private let container: AppContainer
    /// 这个页面属于哪个百度来源(决定 `sourceID`,也就决定了封面缓存 key)
    private let source: BaiduPanSource
    /// 进到「已授权」那一屏时要不要顺带列目录。
    /// 添加流程传 `false`:`authorization()` 一变 `.authorized` 就会落库并切页,
    /// 此刻还照常列目录的话,那次请求(含封面)会被立刻丢掉 —— 白烧一次配额。
    private let loadsDirectory: Bool
    private var authorizationTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// 这一轮目录读取的轮次。TMDB 刮削是**后台跑的第二趟**,回来时目录可能已经换了
    /// —— 靠它丢掉过期结果(与 `MediaDetailViewModel.generation` 同一处置)。
    private var directoryGeneration = 0
    private var scrapeTask: Task<Void, Never>?
    /// 上一次 TMDB 刮削的失败原因(nil = 没失败 / 没配置 token)。
    /// ⚠️ 与 `notice` 分开:它是**附加信息**的失败,不能盖掉目录本身的提示。
    private(set) var scrapeFailure: String?

    init(container: AppContainer, source: BaiduPanSource, loadsDirectory: Bool = true) {
        self.container = container
        self.source = source
        self.loadsDirectory = loadsDirectory
    }

    private var connection: BaiduPanConnection { container.baiduConnection() }

    /// 条目读取走 `BaiduPanSourceProvider` —— 那里把「列目录 → 合成条目 →
    /// 批量换封面地址 → 刮削补封面」几步收在一起,这一页不必知道封面
    /// 为什么要另外发请求、也不必知道刮削走的是哪个服务。
    private func makeProvider() -> BaiduPanSourceProvider {
        BaiduPanSourceProvider(
            connection: connection,
            sourceID: source.id,
            folderName: folderName ?? source.folderName,
            scraper: container.metadataScraper()
        )
    }

    // MARK: - 动作:进入

    func reload() async {
        loadTask?.cancel()
        let task = Task { [weak self] in _ = await self?.performReload() }
        loadTask = task
        await task.value
    }

    private func performReload() async {
        isLoading = true
        loadFailure = nil
        defer { isLoading = false }
        // 结构性变化(首次进入 / 换配置 / 换授权 / 用户点工具栏刷新):会话缓存作废,
        // 之后从片库根重新列起。⚠️ 放在这里而不是 `case .authorized` 里 ——
        // 解绑 / 换密钥之后会走到「需要授权」那一屏,那条路也得把旧缓存清掉。
        directoryCache.removeAll()
        do {
            authorization = try await connection.authorization()
            // 目录名只用于展示。⛔ 这里的 `try?` 不是吞错:凭据文件读不出来时
            // 上面的 `authorization()` 已经抛了同样的错误并进了 `loadFailure`。
            folderName = try? await connection.appConfiguration().folderName
            switch authorization {
            case .authorized:
                // ⚠️ 进这一屏一律**从片库根重新开始**:`reload()` 只在结构性变化后
                // 被调用(首次进入 / 授权完成 / 保存配置 / 解除授权 / 工具栏刷新)。
                // 路径栏那个刷新按钮走 `refreshFiles()`,**不会**重置当前目录,
                // 也不会清掉其它目录的会话缓存。
                guard loadsDirectory else { break }
                currentDirectory = nil
                await loadFiles()
            case .needsAuthorization, .unconfigured, nil:
                break
            }
        } catch let error as BaiduPanError {
            // ⚠️「还没配置」不是失败,是这一页的第一屏 —— 走配置表单,不报错
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

    func signOut() async {
        do {
            try await connection.signOut()
            // 正在跑的后台刮削也要停:解绑之后它写回来的卡片已经不属于这一屏
            cancelScrape()
            items = []
            filesByID = [:]
            currentDirectory = nil
            // 片库根**保留**(与 AppKey / SecretKey 同一条理由):
            // 重新扫码不该逼用户再选一次片库在哪。
            await reload()
        } catch {
            loadFailure = LoadFailure(message: "解除授权失败:\(error)")
        }
    }

    /// 用户主动要改配置(典型场景:应用目录名填错,整页空着)。
    /// ⛔ 只把界面切回表单,**不动 token** —— 改个目录名不该连带重新扫码。
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

    /// 改配置改到一半又不想改了:回到授权后的那一屏。
    func cancelConfigurationEdit() async {
        configurationDraft = nil
        await reload()
    }

    // MARK: - 动作:目录

    func loadFiles() async {
        await loadFiles(allowingLibraryRootFallback: true)
    }

    /// 强制重新列目录(用户点「刷新 / 重试」):⛔ 不用会话缓存,并把这一目录的缓存换成新的。
    ///
    /// ⚠️ 与 `loadFiles()` 的分工:`loadFiles()` 走**导航**(进目录 / 退回上层),
    /// 命中会话缓存就零请求;这个是用户**明确要最新数据**,必须走网络。
    func refreshFiles() async {
        await loadFiles(allowingLibraryRootFallback: true, forceRefresh: true)
    }

    /// 播完一场后刷新**本地续播状态**(进度标签、继续观看区)。
    ///
    /// ⛔ 不重新列目录:那是 2 次百度请求(`list` + `filemetas`),而播完一场变的
    /// 只有本地续播库(`WatchProgressStore`)—— 目录内容一个字节都没动。
    /// 进度标签与续播区都直接读本地库,所以只重读本地就够(配额纪律)。
    func refreshResumeState() async {
        await loadResumeCards()
        await loadResumePositions()
    }

    /// `allowingLibraryRootFallback`:片库根读不出来时,允许清掉它并回落到应用目录。
    /// ⛔ 只回落**一次**。递归时传 false:再失败就是应用目录本身的问题,
    /// 继续套娃只会把真正的错误(目录名填错)藏在一层层的重试里。
    ///
    /// `forceRefresh`:⛔ 不用会话缓存,强制走网络并把结果写回缓存(用户点刷新 / 重试)。
    private func loadFiles(
        allowingLibraryRootFallback allowFallback: Bool, forceRefresh: Bool = false
    ) async {
        isLoadingFiles = true
        directoryFailure = nil
        // 新一轮读取:上一轮的后台刮削结果已经作废
        cancelScrape()
        defer { isLoadingFiles = false }

        // 隐藏列表是**本地**的,读它不发请求(配额纪律)。⛔ 必须每轮都读:
        // 设置页可能刚刚恢复了一条,而浏览页这一屏还开着。
        hiddenRefs = await container.hiddenItems.hiddenRefs(sourceID: source.id)

        // 「继续观看」独立于当前目录:目录读失败也要看得到它。只在最外层读一次
        // —— 片库根回落是同一轮的递归,不必重读。
        if allowFallback { await loadResumeCards() }

        var directory = ""
        do {
            let root = try await connection.applicationDirectory()
            rootDirectory = root
            let library = try await connection.libraryRoot()
            libraryRoot = library
            directory = currentDirectory ?? library ?? root
            currentDirectory = directory
            let provider = makeProvider()
            let content: BaiduPanSourceProvider.DirectoryContent
            if !forceRefresh, let cached = directoryCache[directory] {
                // 命中会话缓存:同一会话里重进已列过的目录 → 零请求(配额纪律)
                content = cached
            } else {
                content = try await provider.content(directory: directory)
                directoryCache[directory] = content
            }
            items = content.items
            // 原始文件按 `fs_id` 留一份:播放与进目录要 `path` / 真实文件名。
            // ⚠️ 它来自**同一次**目录读取,不是再列一遍(配额,见 provider 的注释)
            filesByID = content.filesByID
            await loadResumePositions()
            startScrape(items: content.items, provider: provider)
            return
        } catch let error as BaiduPanError {
            // 片库根在网盘里被删了 / 改了名 → 丢掉这个偏好,回落到应用目录。
            // ⛔ 不弹错误:它只是个「记住上次在哪」的便利,不值得为此打断浏览。
            if allowFallback, error.isDirectoryUnavailable,
               let library = libraryRoot, directory == library, directory != rootDirectory {
                try? await connection.setLibraryRoot(nil)
                libraryRoot = nil
                currentDirectory = nil
                await loadFiles(allowingLibraryRootFallback: false, forceRefresh: forceRefresh)
                return
            }
            directoryFailure = BaiduPanDirectoryFailure(
                message: error.userMessage,
                isApplicationRootUnavailable: error.isDirectoryUnavailable
                    && directory == rootDirectory
            )
        } catch {
            directoryFailure = BaiduPanDirectoryFailure(
                message: "读取目录失败:\(error)", isApplicationRootUnavailable: false)
        }
    }

    /// 目录**已经能看**之后再问 TMDB 补封面(`docs/TMDB_API.md`)。
    ///
    /// ⚠️ 为什么是后台第二趟:这一趟要发 N 次外部请求(N = 认出来的片子数),
    /// 让它参与列表加载就等于「TMDB 连不上 → 片库打不开」。所以列表先出、封面后补,
    /// 回来时就地换图(`PosterImage` 认 `descriptor` 的 `cacheKey`,会自动重取)。
    ///
    /// 失败(没 token / token 无效 / 连不上)只挂一句提示到 `scrapeFailure`:
    /// 卡片保持本地合成的样子,降级成图标卡 —— ⛔ 不假装有封面。
    private func startScrape(items directoryItems: [SourceItem], provider: BaiduPanSourceProvider) {
        let myGeneration = directoryGeneration
        scrapeFailure = nil
        scrapeTask = Task { [weak self] in
            let enriched = await provider.scrape(items: directoryItems)
            let failure = await provider.lastScrapeFailureDescription()
            // 期间换了目录:这一趟的结果已经过期,⛔ 不能把上一层的卡片写回来
            guard let self, myGeneration == self.directoryGeneration else { return }
            self.items = enriched
            self.scrapeFailure = failure
        }
    }

    /// 丢掉正在跑的后台刮削(它的结果已经作废)。轮次 +1 也就是让它在回来时自行退出。
    private func cancelScrape() {
        directoryGeneration += 1
        scrapeTask?.cancel()
        scrapeTask = nil
        scrapeFailure = nil
    }

    /// 进一个目录卡片
    func enter(_ item: SourceItem) async {
        guard item.kind.isContainer, let file = file(for: item) else { return }
        currentDirectory = file.path
        await loadFiles()
    }

    func goUp() async {
        guard let current = currentDirectory, let root = rootDirectory,
              current != root else { return }
        let parent = (current as NSString).deletingLastPathComponent
        // ⛔ 不许退到应用目录之外:那以外的地方第三方应用访问不了
        currentDirectory = parent.hasPrefix(root) ? parent : root
        await loadFiles()
    }

    var canGoUp: Bool {
        guard let current = currentDirectory, let root = rootDirectory else { return false }
        return current != root
    }

    // MARK: - 动作:片库根

    /// 片库根是「进来先落在哪」的选择,不是授权范围 —— 授权范围由
    /// `/apps/{应用目录名}` 一个值决定,用户改不了,所以百度那边
    /// **没有**「授权时选文件夹」这一步;能选的只有应用目录**里面**的起点。
    var isCurrentDirectoryLibraryRoot: Bool {
        guard let library = libraryRoot, let current = currentDirectory else { return false }
        return current == library
    }

    /// 应用目录本身就是默认起点,把它设成片库根没有意义(等于没设)。
    var canSetLibraryRoot: Bool {
        guard let current = currentDirectory, let root = rootDirectory, current != root else {
            return false
        }
        return !isCurrentDirectoryLibraryRoot
    }

    func setLibraryRootToCurrentDirectory() async {
        guard let current = currentDirectory else { return }
        do {
            try await connection.setLibraryRoot(current)
            libraryRoot = current
        } catch let error as BaiduPanError {
            notice = error.userMessage
        } catch {
            notice = "设置片库根失败:\(error)"
        }
    }

    func clearLibraryRoot() async {
        do {
            try await connection.setLibraryRoot(nil)
            libraryRoot = nil
            currentDirectory = nil
            await loadFiles()
        } catch let error as BaiduPanError {
            notice = error.userMessage
        } catch {
            notice = "清除片库根失败:\(error)"
        }
    }

    /// 当前目录相对应用根目录的显示路径
    var relativePath: String? {
        guard let current = currentDirectory, let root = rootDirectory else { return nil }
        if current == root { return "/" }
        guard current.hasPrefix(root) else { return current }
        let remainder = String(current.dropFirst(root.count))
        return remainder.isEmpty ? "/" : remainder
    }

    func play(_ item: SourceItem) {
        guard let file = file(for: item) else { return }
        // 起播这一刻顺手记下展示快照(标题 / 封面),「继续观看」才渲染得出来。
        // ⛔ 不要等到渲染续播区时回头再列网盘(配额,见 `AppContainer.rememberResumeCard`)。
        Task { await container.rememberResumeCard(item: item, file: file) }
        container.play(file, episodeQueue: Self.episodeQueue(
            selecting: item, in: sortedItems, filesByID: filesByID))
    }

    /// 用**当前目录已列的条目**装配剧集队列(播放页的上一集 / 下一集 / 选集面板)。
    ///
    /// ⛔ 这里一次网络请求都不发:兄弟集此刻就在 `items` / `filesByID` 里,
    /// 而配额只有 10 次/小时(见 `docs/BAIDU_PAN_API.md`)。顺序取调用方给的
    /// `items`(浏览页传的就是界面那一份 `sortedItems`),与看到的**完全一致**。
    ///
    /// 纯函数,不碰 VM 状态 —— 测试直接驱动它,不必先造一个真目录。
    ///
    /// 只收 `.episode`:合成器判定「这一层像剧集序列」才会给这个 kind
    /// (`BaiduPanMetadataSynthesizer.mediaItem`),所以单条视频 / 电影不会凭空得到
    /// 一个「队列」,花絮之类也不会混进来。不足两集同样不给 —— 没有可切的一集。
    static func episodeQueue(
        selecting item: SourceItem,
        in items: [SourceItem],
        filesByID: [UInt64: BaiduPanFile]
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
                source: .baiduPan(file: file),
                resumeItem: entry,
                // 选集面板的封面:同目录同名图,或 TMDB 刮回来的分集剧照
                poster: entry.poster
            )
        }
        guard let index = entries.firstIndex(where: { $0.id == item.ref.itemID }) else { return nil }
        return EpisodeQueue(episodes: entries, currentIndex: index)
    }

    /// 播「继续观看」区的一张卡片。
    ///
    /// 卡片是**跨目录**的(那正是这个区的意义),所以文件本身只能靠快照重建 ——
    /// ⚠️ 这不是「编一个文件」:`fs_id` / `path` / `name` 都是**当初那条文件**的原值,
    /// 只是把播放用不到的字段(size / category / mtime)留空。
    ///
    /// 换集入口要的兄弟集不在手上,所以起播前**补列一次它所在的那个目录**
    /// (目录由 `path` 推出);卡片恰好落在当前浏览的目录里时不列,直接复用。
    /// 列回来的那一份同时带着封面,选集面板因此也有图。
    ///
    /// ⛔ 不改 `currentDirectory`:点「继续观看」是**接着看**,不是要跳到那个目录 ——
    /// 那样浏览页会毫无征兆地换一屏。
    ///
    /// - Returns: 是否已经把播放请求写好(视图据此决定要不要唤起播放窗口)。
    @discardableResult
    func play(_ card: BaiduResumeCard) async -> Bool {
        guard let file = card.reconstructedFile else { return false }
        guard preparingPlaybackFileID == nil else { return false }
        preparingPlaybackFileID = card.fileID
        defer { preparingPlaybackFileID = nil }

        let content = await directoryContent(for: Self.directory(ofFilePath: file.path))
        let queue = content.flatMap { content in
            content.items.first { $0.ref.itemID == String(file.fsID) }.flatMap { item in
                Self.episodeQueue(selecting: item, in: content.items, filesByID: content.filesByID)
            }
        }
        container.play(file, episodeQueue: queue)
        return true
    }

    /// 某个目录的内容:就是当前目录就直接复用(0 请求),否则补列一次。
    ///
    /// ⛔ 拿不到就返回 nil,**照常播放**,只是没有换集入口 —— 「继续观看」的语义是
    /// 接着看,不能因为一次列目录失败就播不了。目录本身的错误浏览页已经提示过,
    /// 这里再弹一次只会把起播打断。
    private func directoryContent(
        for directory: String
    ) async -> BaiduPanSourceProvider.DirectoryContent? {
        // ⚠️ 两个分支都要过隐藏过滤:从「继续观看」起播时,隐藏的兄弟集
        // 不该因为换了个入口就回到选集面板里。
        if directory == currentDirectory, !items.isEmpty {
            return BaiduPanSourceProvider.DirectoryContent(
                items: sortedItems, filesByID: filesByID)
        }
        do {
            let provider = makeProvider()
            let content = try await provider.content(directory: directory)
            // 逐集剧照只来自 TMDB 那一趟(⛔ 不抛错:没配 token / 连不上就退本地图)
            let enriched = await provider.scrape(items: content.items)
            return BaiduPanSourceProvider.DirectoryContent(
                items: visible(enriched), filesByID: content.filesByID)
        } catch {
            return nil
        }
    }

    /// 从文件全路径推出它所在的目录(续播快照只存了文件路径,没有目录字段)。
    static func directory(ofFilePath path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// 把一条移出「继续观看」:删掉本地进度记录(⛔ 不动网盘上的文件)。
    ///
    /// ⚠️ 删的是**这一整部剧**:卡片是一部剧一张,只删当前那一集的话,
    /// 同剧下一集有进度就会立刻顶上来 —— 表现为「移出了又回来了」。
    /// (本地续播库没有「隐藏」这一态,删记录是它唯一的移除手段。)
    func removeResumeCard(_ card: BaiduResumeCard) async {
        let key = Self.seriesKey(title: card.title, locator: card.path)
        do {
            for record in await container.watchProgress.resumeEntries(sourceID: source.id)
            where Self.seriesKey(of: record) == key {
                try await container.watchProgress.remove(fileID: record.fileID)
            }
            resumeCards = resumeCards.filter { $0.id != card.id }
        } catch {
            notice = "移出继续观看失败:\(error)"
        }
    }

    func resumeSeconds(for item: SourceItem) -> Double? {
        resumePositions[item.ref.itemID]
    }

    // MARK: - 动作:删除 / 隐藏

    /// 让一条条目从眼前消失:只本地隐藏,或连网盘里的文件一起删。
    ///
    /// - Parameter alsoDeleteRemotely: 勾了「同时删除网盘里的文件」。
    ///
    /// ⚠️ 两条路后果不同,⛔ 别混:
    ///
    /// - **只隐藏** → 写 `HiddenItemsStore`(设置页可恢复),`items` 不动
    ///   —— 留着它,恢复那一刻条目立刻重现,不必再列一次目录(配额 2 次请求);
    /// - **连网盘一起删** → ⛔ **不写**隐藏库:文件已经不在网盘,恢复不出任何东西,
    ///   记一条只会让「已隐藏」列表越积越多。改成把本地这一份(缓存 / 卡片 /
    ///   续播记录)一起清掉。
    ///
    /// 勾了但网盘删失败 → **直接抛**,既不隐藏也不摘除 —— 让用户看到「没删成」,
    /// ⛔ 不悄悄降级成隐藏(那会让人以为已经删干净了)。
    func delete(_ item: SourceItem, alsoDeleteRemotely: Bool) async throws {
        guard let file = file(for: item) else {
            throw BaiduPanError.configuration(
                "找不到「\(item.title)」在网盘上的路径,没法删除。")
        }
        guard alsoDeleteRemotely else {
            try await container.hiddenItems.hide(
                HiddenItemsStore.Item(ref: item.ref, title: item.title, hiddenAt: Date()))
            hiddenRefs.insert(item.ref)
            resumeCards.removeAll { $0.fileID == item.ref.itemID }
            return
        }

        try await connection.deleteFile(at: file.path)

        // 只进内存:下一轮 `loadFiles` 会从库里重读(这一条从来没写进库),
        // 而那时目录缓存已经丢掉、条目来自网络 —— 删掉的自然不会再出现。
        hiddenRefs.insert(item.ref)
        items.removeAll { $0.ref == item.ref }
        if let fsID = UInt64(item.ref.itemID) { filesByID.removeValue(forKey: fsID) }
        resumeCards.removeAll { $0.fileID == item.ref.itemID }
        resumePositions.removeValue(forKey: item.ref.itemID)
        // 缓存要丢两层:被删的那一条自己(目录的话还有它的子层),
        // 以及**它所在的那一层** —— 后者还留着它的卡片,不丢就等于删了个寂寞。
        evictCachedDirectory(file.path)
        evictCachedDirectory(Self.directory(ofFilePath: file.path))
        do {
            try await container.watchProgress.remove(fileID: item.ref.itemID)
        } catch {
            // 文件已经删掉了,清不掉进度只是留一条死记录 —— 如实说一句,
            // ⛔ 不把它算成删除失败(那会让人再删一次)。
            notice = "网盘文件已删除,但本地续播记录没清掉:\(error)"
        }
    }

    /// 丢掉一条目录缓存:它自己与其**所有子层**(删掉一个目录后,子层的旧内容一样是垃圾)。
    private func evictCachedDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        directoryCache = directoryCache.filter { key, _ in
            key != path && !BaiduPanPath.isInside(key, applicationRoot: path)
        }
    }

    /// 读本地续播库里属于这个来源的记录,折成卡片。
    ///
    /// 与 `loadResumePositions` 的分工:那个读的是**当前目录**每一条的进度(画在
    /// 卡片角上);这个读的是**全库**里有进度的条目(撑起顶部的续播区)。
    private func loadResumeCards() async {
        let records = await container.watchProgress.resumeEntries(sourceID: source.id)
        // ⚠️ 过滤放在这里而不是调用方:这个方法在 `loadFiles` 的片库根回落里
        // 会被再调一次,只在外层过滤会漏掉那一趟。
        let visibleRecords = records.filter { !hiddenRefs.contains(
            SourceItemRef(sourceID: source.id, itemID: $0.fileID)) }
        resumeCards = Self.oneCardPerSeries(visibleRecords).compactMap(BaiduResumeCard.init(record:))
    }

    /// 一部剧只留**一条**记录:同一目录 + 同一剧名的合成一张,取最近看的那一集。
    ///
    /// ## 为什么必须在展示层合
    ///
    /// 续播库按**文件**记(一集一条,换集 / 跳集都要各自记得住),而卡片上的标题
    /// 是**剧名**(`BaiduPanMetadataSynthesizer.mediaItem`:剧集目录结构取目录名)。
    /// 不合就会看到一排同名卡片 —— 一部剧看几集就占几张。
    ///
    /// ⛔ 不改续播库:各集的进度还得留着(进目录时角标要按集显示),这里只是**卡片**聚合。
    ///
    /// - Note: `resumeEntries` 已按 `updatedAt` 倒序,所以留下的是组内最近看的那一集。
    static func oneCardPerSeries(
        _ records: [WatchProgressStore.ResumeRecord]
    ) -> [WatchProgressStore.ResumeRecord] {
        var seen: Set<String> = []
        return records.filter { seen.insert(seriesKey(of: $0)).inserted }
    }

    /// 一部剧的聚合键:剧名 + 所在目录。
    ///
    /// ⚠️ 目录也进键:不同目录下同名的内容是**两部**(重拍 / 同名电影),
    /// 只按剧名合会把它们并成一张。代价是同一部剧分季目录
    /// (`剧/Season 1`、`剧/Season 2`)会各出一张 —— 那正是「不并错」换来的。
    static func seriesKey(of record: WatchProgressStore.ResumeRecord) -> String {
        seriesKey(title: record.display.title, locator: record.display.locator)
    }

    static func seriesKey(title: String, locator: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(name)|\(Self.directory(ofFilePath: locator))"
    }

    /// `SourceItem` 只是给 UI 的投影;播放与进目录要原始文件(`path` / 真实文件名)。
    /// ⛔ 找不到就什么都不做 —— 不拿投影反推一个假 `BaiduPanFile`。
    private func file(for item: SourceItem) -> BaiduPanFile? {
        guard let fsID = UInt64(item.ref.itemID) else { return nil }
        return filesByID[fsID]
    }

    /// 去掉被隐藏的条目。
    private func visible(_ items: [SourceItem]) -> [SourceItem] {
        guard !hiddenRefs.isEmpty else { return items }
        return items.filter { !hiddenRefs.contains($0.ref) }
    }

    /// 修改配置时预填给表单的现值。
    struct BaiduPanConfigurationDraft: Sendable, Equatable {
        let appKey: String
        let secretKey: String
        let folderName: String
    }

    private func loadResumePositions() async {
        var result: [String: Double] = [:]
        for item in items where item.kind.isPlayable {
            let id = item.ref.itemID
            if let seconds = await container.watchProgress.resumeSeconds(forFileID: id) {
                result[id] = seconds
            }
        }
        resumePositions = result
    }
}

/// 百度来源「继续观看」区的一张卡片。
///
/// 它是**从本地续播库的记录折出来的**(不是从目录列出来的)—— 因为续播区要
/// 跨目录、甚至要能在目录读失败时也显示。展示所需的一切都来自播放那一刻
/// 存下的快照(`WatchProgressStore.Display`)。
struct BaiduResumeCard: Identifiable, Sendable, Equatable {
    let fileID: String
    let title: String
    let positionSeconds: Double
    /// 已知总时长;未知为 nil(百度不给时长时就没有,进度条也不画)
    let durationSeconds: Double?
    /// 第几集。nil = 不是一集,或快照里没记 —— 副标题就只报「已看到 …」
    let episodeNumber: Int?
    let path: String
    let fileName: String
    let poster: ImageDescriptor?

    var id: String { fileID }

    /// 副标题:一部剧只出一张卡,得说清接着看的是第几集。
    var subtitle: String {
        let progress = "已看到 \(PlayerTime.text(positionSeconds))"
        guard let episodeNumber else { return progress }
        return "第 \(episodeNumber) 集 · \(progress)"
    }

    /// 折不出可播文件(键不是合法 `fs_id`)就返回 nil —— ⛔ 不端一张点不动的卡片。
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
    }

    /// 重建一个够播放用的 `BaiduPanFile`(见 `BaiduPanSourceViewModel.play(_ card:)`)。
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

/// 目录读失败时的用户可见信息。
///
/// ⚠️ 没有复用 `LoadFailure`:那一个是给 Emby 那条的(带 `needsLogin`),
/// 而这里的分支是百度独有的,塞进去会让两个来源的状态互相污染。
struct BaiduPanDirectoryFailure: Sendable, Equatable {
    let message: String

    /// 是不是**应用目录本身**读不出来(`/apps/{应用目录名}` 不在 / 没权限)。
    ///
    /// 这一态要给完全不同的处置:重试没用,得让人去核对控制台里的「应用名称」。
    /// ⛔ 它**不是**「大概是权限问题」的猜测 —— 只有 `errno` 是
    /// `-7`(无权访问)/ `-9`(不存在)且失败的请求正是应用目录时才置 true。
    let isApplicationRootUnavailable: Bool
}
