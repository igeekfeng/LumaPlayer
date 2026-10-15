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
    /// 这个来源配的片库根(**已校验**:失效时已当作没设)。
    ///
    /// ⚠️ 它同时是**本页能退到的最外层**(见 `canGoUp`)—— 片库根之上是应用目录,
    /// 那里只看得见刚设的这个目录名,没有意义。
    /// 它**不落盘到这里**:列表在设置里维护(`BaiduPanSourceSettingsView`),
    /// 这里只是读出来用。nil = 没配,直接用应用目录。
    private(set) var libraryRoot: BaiduPanLibraryRoot?
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
    /// 为什么要有它:配额见 §7(`docs/BAIDU_PAN_API.md`),
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

    /// 排好序、去掉隐藏项的条目 —— **界面用这个**。
    ///
    /// ## 顺序固定为「剧集顺序」
    ///
    /// 排序菜单已经去掉(浏览页不再暴露它):看剧都是从前往后看的,而这一档
    /// 是唯一一个「认得出集号就按 (季, 集) 排、认不出就按自然名」的顺序
    /// (`BaiduPanSortOrder.episode`)—— 字符串序下 `10.mp4` 会跑到 `2.mp4` 前面。
    /// ⛔ 排的是**已经取回**的条目,不发任何请求(配额见 `docs/BAIDU_PAN_API.md` §7)。
    ///
    /// 为什么是计算属性而不是在 `loadFiles()` 里排一次:刮削回来会**整份换掉**
    /// `items`(`startScrape`),排一次的做法会在那一刻把顺序丢掉。
    ///
    /// 为什么隐藏过滤在这里而不是从 `items` 里真删:`items` 会被刮削整份换掉,
    /// 真删的做法会在那一刻把隐藏项又写回来。而且留着它,设置页点「恢复」
    /// 能立刻重新出现 —— 不必再等一次列目录(配额:2 次请求)。
    var sortedItems: [SourceItem] {
        visible(BaiduPanSortOrder.episode.apply(to: items, filesByID: filesByID, ascending: true))
    }

    private(set) var isLoadingFiles = false
    private(set) var directoryFailure: BaiduPanDirectoryFailure?

    /// 是否已经完成过一次完整的目录加载。「Reload」(⌘R)据此决定语义
    /// (首次 = 结构性重载,之后 = 只重读当前目录),见 `refreshFromToolbar()`。
    private(set) var hasLoadedOnce = false

    /// 用户主动要改配置时(多半是应用目录名填错了)预填给表单的现值。
    private(set) var configurationDraft: BaiduPanConfigurationDraft?

    /// 本地续播进度(fs_id → 已看秒数),用于列表上画一行「已看到 12:34」。
    /// 覆盖**当前目录**与**详情页这一季的分集**两份条目。
    private(set) var resumePositions: [String: Double] = [:]

    // MARK: - 剧集详情(目录形态)

    /// 当前目录的**内容形态**:普通目录(网格)还是一部剧(详情页)。
    ///
    /// 判定是纯函数(`BaiduPanSeriesLayout`),这里只负责把结果接住 ——
    /// 「点进去的是一层文件,还是一部剧」正是本页与 Emby 观感对齐的关键一步。
    private(set) var directoryShape: BaiduPanDirectoryShape = .directory

    /// 剧集形态下这一部剧的**剧级展示信息**。
    ///
    /// ⚠️ 为什么单留一格:剧级元数据(标题 / TMDB 海报 / 简介 / 年份)是**父目录列目录时**
    /// 刮回来的(`BaiduPanMetadataScraper.enrichFolders`),而进了详情页之后列的是
    /// **剧目录自己的内容**(集文件 + 季文件夹),那份元数据不在其中 ——
    /// 不把用户点进来时那张卡片留住,详情页就只剩一个目录名。
    private(set) var seriesItem: SourceItem?

    /// 用户点进来时那张**目录卡片**(剧级元数据的来源)。只有 `enter(_:)` 会设置它。
    private var enteredSeriesItem: SourceItem?

    /// 上一轮判定形态的是哪个目录。
    ///
    /// 用途只有一个:区分「同一部剧的刷新」与「进了另一部剧」—— 前者要保住用户正看着的季,
    /// 后者必须回到第一季。⛔ 不靠季号判断:两部剧都有「第 1 季」是常态。
    private var shapeDirectory: String?

    /// 「继续观看」卡片点进详情页时,希望默认选中哪一季(`nil` = 没指定)。
    ///
    /// ⚠️ 它是一次**导航意图**,不是常驻状态:由 `openDetail(for:)` 写下、
    /// `applyDirectoryShape` 消费一次即清 —— 留着会让下一次进别的目录时莫名选中某一季。
    private var preferredSeasonNumber: Int?

    /// 当前选中的季
    private(set) var selectedSeason: BaiduPanSeason?

    /// 选中季的分集(已按集号排序;只含能播的条目)
    private(set) var episodes: [SourceItem] = []
    private(set) var isLoadingEpisodes = false
    /// 读某一季失败的原因(nil = 没失败)。与 `directoryFailure` 分开:
    /// 它只影响分集那一块,剧级信息与季列表照常能看。
    private(set) var episodeFailure: String?

    /// 分集刮削的轮次。换季 / 换目录 / 换授权时 +1,回来时对不上就丢弃
    /// (与 `directoryGeneration` 同一处置)。
    private var episodeGeneration = 0
    private var episodeScrapeTask: Task<Void, Never>?

    /// 详情页的播放主按钮作用于哪一集:**有本地续播进度的那一集**,都没有就是第一集。
    /// 没有分集时为 nil —— UI 据此不画播放按钮,⛔ 不给一个点了没反应的按钮。
    var focusedEpisode: SourceItem? {
        episodes.first { (resumePositions[$0.ref.itemID] ?? 0) > 0 } ?? episodes.first
    }

    /// 详情页的**剧级扩展信息 + 演职员**(类型 / 评分 / 标语 / 状态 / 制片公司 / 演员表)。
    ///
    /// ⚠️ 它**不来自列表刮削**:`enrich` 走的搜索端点给不出这些字段,而且那一趟按标题
    /// 批量查、要服务一屏三十个卡片。这一趟只在**详情页**发,按 id 精确取
    /// (`BaiduPanMetadataScraper.seriesProfile`)。
    ///
    /// nil = 还没拿到 / 拿不到 —— 详情页按「缺就隐藏」处理(`CLAUDE.md` 硬规则 4)。
    private(set) var seriesProfile: TMDBSeriesProfile?
    private(set) var isLoadingSeriesProfile = false

    // ⚠️ 这一趟**没有**单独的失败文案:刮削器的失败原因是**一个共用槽位**
    // (`lastFailureDescription`),而详情页的分集刮削与它可能同时在跑 ——
    // 读到的可能是另一趟留下的、指向别的原因的一句话。与其端出一句可能张冠李戴的
    // 提示,不如什么都不说:这一块拿不到就整块隐藏,而「TMDB 连不上 / token 无效」
    // 这类原因分集那一趟的 `scrapeFailure` 已经会如实报出来。

    /// 剧级扩展信息的轮次。换剧 / 换授权时 +1,回来时对不上就丢弃。
    private var seriesProfileGeneration = 0
    private var seriesProfileTask: Task<Void, Never>?

    /// 详情页里 TMDB 图片(人物头像)的归属来源 —— 与海报 / 剧照同一个 `sourceID`,
    /// 于是头像与它们落在同一格缓存分区里。
    ///
    /// ⚠️ 详情页显示期间它实际上恒非 nil:`applyDirectoryShape` 保证 `seriesItem`
    /// 已经被填过(`enteredSeriesItem` 或兜底条目),分集也一定已经列过。
    /// 类型上写成可选只是为了不在代码里撒一个「一定不会 nil」的谎。
    var seriesSourceID: UUID? { seriesItem?.ref.sourceID ?? episodes.first?.ref.sourceID }

    /// 「继续观看」区的卡片:本地续播库里有进度、且带展示快照的条目,
    /// 按最近看排序。⛔ 不限于当前目录 —— 它就是要跨目录把你看过的东西捞出来。
    private(set) var resumeCards: [BaiduResumeCard] = []

    /// 正在为「继续观看」起播做准备(补列它所在的目录)的那张卡片。
    /// 卡片据此转圈 —— 补列要发两次请求,不显示就等于「点了没反应」。
    private(set) var preparingPlaybackFileID: String?

    private let container: AppContainer
    /// 这个页面属于哪个百度来源(决定 `sourceID`,也就决定了封面缓存 key)
    private let source: BaiduPanSource
    /// 这个来源的 id(主窗口顶栏按它登记「根页有 hero」)
    var sourceID: UUID { source.id }
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

    /// 「Reload」(⌘R)的入口。
    ///
    /// ⚠️ 与 `reload()` 的分工:首次进入(还没加载过)按结构性变化处理,
    /// 回到片库根重新列;之后只重读**当前所在**的目录 —— 刷新不该把人踢回起点。
    /// 两条路都会绕过会话缓存走网络(`refreshFiles`)。
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
        // 结构性变化(首次进入 / 换配置 / 换授权 / 用户按 ⌘R 刷新):会话缓存作废,
        // 之后从片库根重新列起。⚠️ 放在这里而不是 `case .authorized` 里 ——
        // 解绑 / 换密钥之后会走到「需要授权」那一屏,那条路也得把旧缓存清掉。
        // ⚠️ `filesByID` 也要清:它是**合并**进去的(见 `loadFiles`),
        // 不清就会带着上一次的条目跨配置留存。
        directoryCache.removeAll()
        filesByID.removeAll()
        enteredSeriesItem = nil
        shapeDirectory = nil
        // 结构性重载:上一次「继续观看」点进来的选季意图已经不作数了
        preferredSeasonNumber = nil
        do {
            authorization = try await connection.authorization()
            // 目录名只用于展示。⛔ 这里的 `try?` 不是吞错:凭据文件读不出来时
            // 上面的 `authorization()` 已经抛了同样的错误并进了 `loadFailure`。
            folderName = try? await connection.appConfiguration().folderName
            switch authorization {
            case .authorized:
                // ⚠️ 进这一屏一律**从片库根重新开始**:`reload()` 只在结构性变化后
                // 被调用(首次进入 / 授权完成 / 保存配置 / 解除授权)。
                // 手动刷新(⌘R)走 `refreshFromToolbar()` —— 首次进这一屏时等价于
                // `reload()`,之后只重读当前目录,不会把人踢回起点。
                guard loadsDirectory else { break }
                currentDirectory = nil
                await loadFiles()
                hasLoadedOnce = true
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

    // ⚠️ 「解除授权」**不在这里**:它是低频的配置动作,已经搬进设置里的来源页
    // (`AppContainer.signOutBaidu` + `BaiduPanSourceSettingsView`)。解除之后
    // 浏览页不会自己知道 —— 下一次刷新(`refreshFromToolbar`)会撞上
    // `notAuthorized`,由 `loadFiles` 切回扫码那一屏。

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
            let stored = try await connection.libraryRoot(for: source.id)
            libraryRoot = stored
            // 进来先落在片库根;没配就落在应用目录。
            // ⚠️ `currentDirectory` 优先:那是**导航**留下的位置(进目录 / 退回上层),
            // 不该被一次刷新抹掉。
            directory = currentDirectory ?? stored?.path ?? root
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
            // ⚠️ 用**合并**而不是覆盖:详情页会为季文件夹另外列一次子目录,
            // 那一次的结果不该把剧目录里的文件挤掉 —— 分集的 `file(for:)` 还要靠它们。
            // `fs_id` 全局唯一,同键覆盖只是同一个文件的新副本,没有语义冲突。
            filesByID.merge(content.filesByID) { _, new in new }
            await applyDirectoryShape(directory: directory)
            startScrape(items: content.items, provider: provider)
            return
        } catch let error as BaiduPanError {
            // token 没了(在设置里解除了授权 / 刷新失败被清)→ 回到扫码那一屏。
            // ⛔ 不要停在一条「没权限」的目录错误上:那会让人以为网盘出了问题,
            // 而真正要做的是重新授权。
            if case .notAuthorized = error {
                authorization = .needsAuthorization(folderName: folderName ?? "")
                return
            }
            // 片库根在网盘里被删了 / 改了名 → 丢掉它,回落到应用目录。
            // ⛔ 不弹错误:它只是个「进来先落在哪」的便利,不值得为此打断浏览。
            if allowFallback, error.isDirectoryUnavailable,
               let library = libraryRoot?.path, directory == library,
               library != rootDirectory {
                await clearLibraryRoot()
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
            self.refreshFlatSeason(from: enriched)
        }
    }

    /// 丢掉正在跑的后台刮削(它的结果已经作废)。轮次 +1 也就是让它在回来时自行退出。
    private func cancelScrape() {
        directoryGeneration += 1
        scrapeTask?.cancel()
        scrapeTask = nil
        scrapeFailure = nil
    }

    /// 进一个目录卡片。
    ///
    /// 进去之后是**文件网格**还是**剧集详情页**,由列出来的内容形态决定
    /// (`applyDirectoryShape` → `BaiduPanSeriesLayout`)—— 点的时候不必预判,
    /// 所以这一层目录只要列过一次,判定就是免费的(⛔ 不多发一次请求去探)。
    func enter(_ item: SourceItem) async {
        guard item.kind.isContainer, let file = file(for: item) else { return }
        // 记下这张目录卡片:若点进去的是一部剧,它就是这一部剧的剧级元数据来源
        // (标题 / TMDB 海报 / 简介 / 年份,见 `enteredSeriesItem`)。
        enteredSeriesItem = item
        // 手点目录进来自带上下文,上一次「继续观看」留下的选季意图到此为止
        preferredSeasonNumber = nil
        currentDirectory = file.path
        await loadFiles()
    }

    func goUp() async {
        guard let current = currentDirectory, let top = topmostDirectory,
              current != top else { return }
        let parent = (current as NSString).deletingLastPathComponent
        // ⛔ 不许退到最外层之上:配了片库根就是片库根,否则是应用目录。
        // 片库根之上那一层只是「应用目录里有个叫 Videos 的文件夹」,退上去没意义;
        // 应用目录再往外第三方应用也访问不到。
        currentDirectory = BaiduPanPath.isInside(parent, applicationRoot: top) ? parent : top
        // 退回上一层:上一层是什么形态要重新判,刚才那一部剧的剧级元数据也不再适用
        enteredSeriesItem = nil
        preferredSeasonNumber = nil
        await loadFiles()
    }

    // MARK: - 动作:剧集详情

    /// 判这一层是**普通目录**还是**一部剧**,并据此把详情页要的状态备好。
    ///
    /// 判定本身零请求(只看已列出来的条目)。唯一可能的请求是「自动选中第一季」那一次
    /// —— 季文件夹要另外列一次才知道里面有哪些集(百度配额,见 `docs/BAIDU_PAN_API.md` §7)。
    private func applyDirectoryShape(directory: String) async {
        let shape = BaiduPanSeriesLayout.shape(of: items)
        directoryShape = shape
        // 「继续观看」点进来时指定的那一季(见 `openDetail(for:)`)是一次性的导航意图:
        // 这一层不是剧就丢掉 —— ⛔ 别让它漂到下一次进别的目录时生效。
        let preferredSeasonNumber = self.preferredSeasonNumber
        self.preferredSeasonNumber = nil
        guard let structure = shape.seriesStructure else {
            enteredSeriesItem = nil
            seriesItem = nil
            shapeDirectory = nil
            clearEpisodeState()
            return
        }
        // ⚠️ 同一部剧的**刷新**(手动刷新(⌘R) / 播完回来)要保住用户正看着的那一季;
        // 换了一部剧才回到第一季。靠「上一轮判定的是哪个目录」区分这两件事。
        let isSameSeries = shapeDirectory == directory
        shapeDirectory = directory
        // 剧级条目:优先用用户点进来时那张卡片(带 TMDB 元数据);
        // 直接落在剧目录(片库根就是一部剧)时没有那张卡片,退回只有目录名的兜底条目。
        seriesItem = enteredSeriesItem
            ?? Self.fallbackSeriesItem(directory: directory, sourceID: source.id)
        let previousSeasonID = isSameSeries ? selectedSeason?.id : nil
        // 选中哪一季的优先级:「继续观看」指定的那一季 > 同一部剧刷新时保住的那一季 > 第一季。
        // ⚠️ 指定的排最前:用户从续播卡片点进来时看的多半不是第 1 季,而详情页的播放主按钮
        // 作用于「有进度的那一集」—— 落在第一季会让「继续播放」变成「播放第 1 集」。
        let target = preferredSeasonNumber
            .flatMap { number in structure.seasons.first { $0.number == number } }
            ?? structure.seasons.first { $0.id == previousSeasonID }
            ?? structure.seasons.first
        await selectSeason(target)
        // 剧级扩展信息(类型 / 评分 / 演职员)是**另一趟**请求,不参与上面的加载。
        // ⚠️ 同一部剧的刷新不再问:它是**剧级**的,不随季变化,已经有一份就留着 ——
        // 重问会让演职员那一块先清空再填回(闪一下),而内容一个字都不会变。
        // 上一趟还在飞时同样不起第二趟(结果一样)。只有「拿不到」才在刷新时重试。
        if !isSameSeries || (seriesProfile == nil && !isLoadingSeriesProfile) {
            startSeriesProfileLoad()
        }
    }

    /// 起一趟「取剧级扩展信息 + 演职员」的后台请求(`BaiduPanMetadataScraper.seriesProfile`)。
    ///
    /// ⚠️ 为什么是后台第二趟:这一趟要发 1–2 次外部请求,让它参与详情页的加载就等于
    /// 「TMDB 连不上 → 详情页打不开」。所以详情页先出(标题 / 海报 / 分集都已经有了),
    /// 类型 / 演职员这一块后到、到了就地填上。
    ///
    /// 身份来源按可信度取:显式 / 父目录回填的 `tmdbID` 优先,没有就用**剧名 + 年份**
    /// —— 那把键与分集刮削用的是同一把(`searchMatch` 的 `QueryKey`),
    /// 所以详情页问到的必定就是**分集剧照所属于的那部剧**,而且通常命中缓存、零请求。
    /// 两样都没有时**什么都不问**:拿空标题去搜只会端回一堆无关的剧(硬规则 4)。
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
            // 期间换了剧 / 退了目录 / 解了绑:这一趟的结果已经过期
            guard let self, myGeneration == self.seriesProfileGeneration else { return }
            self.seriesProfile = profile
            self.isLoadingSeriesProfile = false
        }
    }

    /// 丢掉正在跑的剧级扩展信息请求(它的结果已经作废)。轮次 +1 也就是让它回来时自行退出。
    private func cancelSeriesProfile() {
        seriesProfileGeneration += 1
        seriesProfileTask?.cancel()
        seriesProfileTask = nil
        seriesProfile = nil
        isLoadingSeriesProfile = false
    }

    /// 切到某一季。
    ///
    /// ⚠️ 季文件夹要**另外列一次**那个目录;平铺存法的分集已经在手上,零请求。
    /// 同一季反复切会命中会话缓存(`directoryCache`),不会重复烧配额。
    func selectSeason(_ season: BaiduPanSeason?) async {
        guard let season else { return }
        selectedSeason = season
        switch season.source {
        case .flatFiles(let files):
            // 平铺的那一批已经在列剧目录时拿到并刮过了(见 `startScrape`),
            // ⛔ 不在这里再列一次、再刮一次
            cancelEpisodeScrape()
            episodes = BaiduPanSeriesLayout.sortedEpisodes(visible(files))
            episodeFailure = nil
        case .folder(let folder):
            guard let file = file(for: folder) else {
                episodes = []
                episodeFailure = "找不到「\(folder.title)」在网盘上的路径,没法读它的分集。"
                return
            }
            await loadEpisodes(directory: file.path)
        }
        await loadResumePositions()
    }

    /// 列某一季的目录,取分集。
    ///
    /// ⚠️ 只收**能播的**条目:季目录里可能混着 `poster.jpg` 这类封面(合成器已滤掉),
    /// 也可能有再下一层的目录 —— ⛔ 详情页只到「集」这一层,不递归。
    private func loadEpisodes(directory: String) async {
        isLoadingEpisodes = true
        episodeFailure = nil
        cancelEpisodeScrape()
        let myGeneration = episodeGeneration
        defer { isLoadingEpisodes = false }
        do {
            let provider = makeProvider()
            let content: BaiduPanSourceProvider.DirectoryContent
            if let cached = directoryCache[directory] {
                content = cached
            } else {
                content = try await provider.content(directory: directory)
                directoryCache[directory] = content
            }
            filesByID.merge(content.filesByID) { _, new in new }
            let playable = visible(content.items.filter { $0.kind.isPlayable })
            episodes = BaiduPanSeriesLayout.sortedEpisodes(playable)
            startEpisodeScrape(items: episodes, provider: provider, generation: myGeneration)
        } catch let error as BaiduPanError {
            episodes = []
            episodeFailure = error.userMessage
        } catch {
            episodes = []
            episodeFailure = "读取这一季的分集失败:\(error)"
        }
    }

    /// 分集的第二趟刮削:补集名 / 单集剧照 / 单集简介。
    ///
    /// 与目录那一趟同一个理由:TMDB 要发 N 次外部请求,让它参与列表加载就等于
    /// 「TMDB 连不上 → 分集列表打不开」。所以列表先出、这些字段后补。
    private func startEpisodeScrape(
        items: [SourceItem], provider: BaiduPanSourceProvider, generation: Int
    ) {
        episodeScrapeTask = Task { [weak self] in
            let enriched = await provider.scrape(items: items)
            let failure = await provider.lastScrapeFailureDescription()
            // 期间换了季 / 退了目录:这一趟的结果已经过期
            guard let self, generation == self.episodeGeneration else { return }
            self.episodes = enriched
            self.scrapeFailure = failure
        }
    }

    /// 刮削回来后同步详情页的分集。
    ///
    /// ⚠️ 只有**平铺存法**需要它:那种存法下分集就是当前目录的条目,而目录刮削是
    /// **整份换掉** `items`(`startScrape`)—— 详情页那一份 `episodes` 还指着旧数组,
    /// 不同步就等于「剧照补上了,但详情页看不到」。季文件夹的分集自己有一趟刮削
    /// (`startEpisodeScrape`),不走这里。
    private func refreshFlatSeason(from items: [SourceItem]) {
        guard case .flatFiles = selectedSeason?.source else { return }
        episodes = BaiduPanSeriesLayout.sortedEpisodes(
            visible(items.filter { $0.kind == .episode }))
    }

    /// 丢掉正在跑的分集刮削(它的结果已经作废)。轮次 +1 也就是让它在回来时自行退出。
    private func cancelEpisodeScrape() {
        episodeGeneration += 1
        episodeScrapeTask?.cancel()
        episodeScrapeTask = nil
    }

    /// 清掉剧集详情的那一组状态(退回普通目录 / 换授权时)。
    private func clearEpisodeState() {
        cancelEpisodeScrape()
        cancelSeriesProfile()
        selectedSeason = nil
        episodes = []
        episodeFailure = nil
    }

    /// 剧级展示信息的兜底条目:只有目录名,没有海报 / 简介 / 年份。
    ///
    /// ⛔ 不伪造任何字段 —— 详情页按「缺就隐藏」处理(`CLAUDE.md` 硬规则 4)。
    /// `ref` 用目录路径当 id:它只用于展示,不参与播放(播放走分集条目)。
    private static func fallbackSeriesItem(directory: String, sourceID: UUID) -> SourceItem {
        let name = (directory as NSString).lastPathComponent
        return SourceItem(
            ref: SourceItemRef(sourceID: sourceID, itemID: directory),
            title: name.isEmpty ? "剧集" : name,
            kind: .folder,
            overview: nil,
            year: nil,
            tmdbID: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            episodeTitle: nil,
            durationSeconds: nil,
            poster: nil,
            metadataOrigin: .none
        )
    }

    /// 本页能退到的**最外层**:配了片库根就是它,否则是应用目录。
    ///
    /// 用户把 `apps/LumaPlayer/Videos` 设为片库根时,根目录就是 `Videos` ——
    /// 再往上是应用目录,那里只看得见「有个叫 Videos 的文件夹」,退上去没有意义。
    private var topmostDirectory: String? {
        libraryRoot?.path ?? rootDirectory
    }

    var canGoUp: Bool {
        guard let current = currentDirectory, let top = topmostDirectory else { return false }
        return current != top
    }

    // MARK: - 动作:片库根
    //
    // 片库根是「进来先落在哪」的选择,不是授权范围 —— 授权范围由
    // `/apps/{应用目录名}` 一个值决定,用户改不了,所以百度那边**没有**
    // 「授权时选文件夹」这一步;能选的只有应用目录**里面**的起点。
    //
    // ⚠️ **一个来源一个**,在**设置**里维护(`BaiduPanSourceSettingsView`)——
    // 顶部那条路径栏去掉之后,浏览页不再有「设为片库根」这个动作,也不再有
    // 切换菜单(要两个起点就加两个来源:授权是应用级的,多来源共用同一份 token)。
    // 这一节只剩「设置里改过之后,这一屏要跟着变」这一件事。

    /// 设置里改过片库根之后重新读一次。
    ///
    /// ⚠️ 只在**真的变了**时才重载目录:变了就意味着入口换了,留在旧目录里没有意义。
    /// 没变就什么都不做 —— 来源列表的每一次变更(改名 / 增删 / 解除授权)都会
    /// 触发这个调用,一律重载会白烧配额(一次列目录 = 2 次请求,§7)。
    ///
    /// ⚠️ `hasLoadedOnce` 那道闸是必需的:这个 `.task(id:)` 在**首次出现**时
    /// 也会跑一次,而那时 `reload()` 还没把片库根读进来 —— 不加闸就会把
    /// 「nil → 有值」误判成「变了」,开局白列一次目录。
    func refreshLibraryRoot() async {
        guard hasLoadedOnce else { return }
        let stored = try? await connection.libraryRoot(for: source.id)
        guard stored != libraryRoot else { return }
        libraryRoot = stored
        await reload()
    }

    /// 把失效的片库根清掉(网盘里那个目录没了 / 改名了),回落到应用目录。
    /// ⛔ 不弹错误:它只是个「进来先落在哪」的便利,不值得为此打断浏览。
    private func clearLibraryRoot() async {
        libraryRoot = nil
        // 写回设置,免得下次进来又撞同一个失效路径
        try? await container.setLibraryRoot(nil, for: source)
    }

    /// 当前目录在标题栏上显示的名字。
    ///
    /// 应用目录根用应用目录名(或「百度网盘」);其余用路径最后一段 ——
    /// 与 Emby 那边 `navigationTitle(媒体库名)` 的对位物。
    /// 片库根那一层因此显示的就是那个目录名(设 `Videos` 为片库根 → 标题「Videos」)。
    var currentDirectoryName: String {
        guard let current = currentDirectory else { return "百度网盘" }
        if let root = rootDirectory, current == root {
            return folderName ?? "百度网盘"
        }
        let last = (current as NSString).lastPathComponent
        return last.isEmpty ? "百度网盘" : last
    }

    /// - Parameter fromBeginning: 从头播放(详情页「从头播放」按钮用)。默认按本地进度续播。
    func play(_ item: SourceItem, fromBeginning: Bool = false) {
        guard let file = file(for: item) else { return }
        // 起播这一刻顺手记下展示快照(标题 / 封面),「继续观看」才渲染得出来。
        // ⛔ 不要等到渲染续播区时回头再列网盘(配额,见 `AppContainer.rememberResumeCard`)。
        Task { await container.rememberResumeCard(item: item, file: file) }
        // 换集队列按**当前所处的上下文**装配:详情页里用这一季的分集,
        // 文件网格里用当前目录那一份。两份都已经在手上,零请求。
        let queueItems = directoryShape.isSeries ? episodes : sortedItems
        container.play(file, episodeQueue: Self.episodeQueue(
            selecting: item, in: queueItems, filesByID: filesByID), fromBeginning: fromBeginning)
    }

    /// 用**当前目录已列的条目**装配剧集队列(播放页的上一集 / 下一集 / 选集面板)。
    ///
    /// ⛔ 这里一次网络请求都不发:兄弟集此刻就在 `items` / `filesByID` 里,
    /// 而配额见 `docs/BAIDU_PAN_API.md` §7。顺序取调用方给的
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

        let content = await directoryContent(for: BaiduPanPath.directory(ofFilePath: file.path))
        let queue = content.flatMap { content in
            content.items.first { $0.ref.itemID == String(file.fsID) }.flatMap { item in
                Self.episodeQueue(selecting: item, in: content.items, filesByID: content.filesByID)
            }
        }
        container.play(file, episodeQueue: queue)
        return true
    }

    /// 点「继续观看」卡片的**非播放**区域:进它的详情页。
    ///
    /// 与 `play(_ card:)` 的分工:那个是接着看(⛔ 不动 `currentDirectory`,
    /// 点一下不该把浏览页换一屏),这个是**跳到那个目录**看详情 ——
    /// 与 Emby 首页「继续观看」卡片点空白处打开详情页对齐。
    ///
    /// 落在**剧目录**上,而不是文件所在的季文件夹上:季文件夹存法
    /// (`琅琊榜/第1季/01.mp4`)下后者会显示成一部只有一季、剧名还是「第1季」的剧
    /// (见 `BaiduPanPath.seriesDirectory(ofFilePath:)`)。那一层不是剧(单条视频 / 电影)时
    /// 照常显示文件网格 —— 百度没有「单文件详情页」,文件所在目录就是能给的最近一层。
    ///
    /// ⚠️ 不越出这一页的最外层:用户把某一季设成了片库根时剧目录在它之上,
    /// 那就退回文件所在目录(见 `detailDirectory(ofFilePath:topmost:)`)。
    func openDetail(for card: BaiduResumeCard) async {
        // 卡片那一集属于哪一季,点进去就默认选哪一季 —— 否则「继续播放」会变成
        // 「播放第 1 集」(理由见 `applyDirectoryShape`)
        preferredSeasonNumber = Self.seasonNumber(ofFilePath: card.path)
        // 这次不是「从父目录那张卡片点进来的」,剧级元数据退回目录名兜底
        // (已知取舍,见 `docs/KNOWN_ISSUES.md`「剧集详情页」一节)
        enteredSeriesItem = nil
        currentDirectory = Self.detailDirectory(
            ofFilePath: card.path, topmost: topmostDirectory)
        await loadFiles()
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

    /// 「继续观看」卡片点进详情页该落在哪一层(见 `openDetail(for:)`)。
    ///
    /// ⚠️ 剧目录若在**片库根之上**(用户把某一季设成了片库根),退回文件所在目录 ——
    /// ⛔ 不越出这一页的最外层(与 `canGoUp` 同一把尺子)。
    static func detailDirectory(ofFilePath path: String, topmost: String?) -> String {
        let series = BaiduPanPath.seriesDirectory(ofFilePath: path)
        guard let topmost, !topmost.isEmpty else { return series }
        return BaiduPanPath.isInside(series, applicationRoot: topmost)
            ? series
            : BaiduPanPath.directory(ofFilePath: path)
    }

    /// 这一集属于第几季(`nil` = 认不出来)。只用于「点进详情页时默认选中哪一季」。
    ///
    /// 判据与合成器同源:父目录名整个是季标记时用它,否则看文件名里的 `SxxExx`。
    /// 两样都没有就不给 —— 详情页退回第一季,与平铺存法(`琅琊榜/01.mp4` 一律算第 1 季)
    /// 的口径一致。
    static func seasonNumber(ofFilePath path: String) -> Int? {
        let parentName = (BaiduPanPath.directory(ofFilePath: path) as NSString).lastPathComponent
        if let season = BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: parentName) {
            return season
        }
        return BaiduPanMetadataSynthesizer.parse(
            name: (path as NSString).lastPathComponent).season
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

        // 删掉的若是片库根,顺手清掉 —— 留着就是指向已不存在目录的悬空值
        if libraryRoot?.path == file.path {
            await clearLibraryRoot()
        }

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
        evictCachedDirectory(BaiduPanPath.directory(ofFilePath: file.path))
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
        return "\(name)|\(BaiduPanPath.directory(ofFilePath: locator))"
    }

    /// `SourceItem` 只是给 UI 的投影;播放与进目录要原始文件(`path` / 真实文件名)。
    /// ⛔ 找不到就什么都不做 —— 不拿投影反推一个假 `BaiduPanFile`。
    func file(for item: SourceItem) -> BaiduPanFile? {
        guard let fsID = UInt64(item.ref.itemID) else { return nil }
        return filesByID[fsID]
    }

    /// 建一个「按 TMDB 重命名」流程的 ViewModel。
    ///
    /// ⚠️ 走工厂而不是把 `container` 暴露出去:那边需要的是凭据 / 连接 / 进度库
    /// 三样东西,由这里按本 ViewModel 自己那份装配好,⛔ 不让调用方自己拼。
    func makeRenameViewModel() -> BaiduPanRenameSeriesViewModel {
        BaiduPanRenameSeriesViewModel(container: container)
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
        var seen: Set<String> = []
        // 覆盖两份条目:当前目录那一层(网格卡片角标)与详情页这一季的分集。
        // 平铺存法下两者是同一批条目,`seen` 去重免得同一条查两遍。
        for item in items + episodes where item.kind.isPlayable {
            let id = item.ref.itemID
            guard seen.insert(id).inserted else { continue }
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
