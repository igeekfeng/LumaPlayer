import SwiftUI

/// 百度网盘目录浏览(**海报墙**)。
///
/// ## 封面从哪来
///
/// 百度不给视频封面,所以封面是**本地合成**的:同目录的
/// `<同名>.jpg` / `poster.jpg` / `folder.jpg`(`docs/SOURCE_ABSTRACTION_PLAN.md` §6.3)。
/// 本地配不到时,再由后台第二趟问 TMDB 补(设置里填了 token 才走,
/// 见 `BaiduPanMetadataScraper`;用户自己放的图优先,⛔ 不被盖掉)。
/// 两样都没有就不伪造 —— 卡片降级成图标卡,⛔ 绝不留一片空白占位图假装有封面。
///
/// ## 为什么点一下就是播放
///
/// 这里的条目是**媒体文件本身**,不是 Emby 那种「进详情页再选集」的结构。
/// 点目录就进目录,点文件就播 —— 与文件管理器一致,不需要中间那一层。
///
/// ⚠️ 顶部的「继续观看」区是**例外**:它与 Emby 首页那一行是同一套交互 ——
/// 悬停出播放按钮,点它直接续播;点卡片其余位置进详情页(见 `BaiduResumeCardView`)。
///
/// ## 顺序
///
/// 目录顺序**由客户端排**(`BaiduPanSortOrder`),不用百度返回的顺序:
/// 那个是纯字符串序,`10.mp4` 会排在 `2.mp4` 前面。**固定按剧集顺序**排
/// (`BaiduPanSortOrder.episode`),不再暴露排序菜单。
///
/// ## 导航
///
/// 与 Emby 那边对齐:页顶大标题是当前目录名(`PageHeader`,剧目录走详情页时不画,
/// 详情页自己有剧名),返回上一层走主窗口浮动顶栏的返回按钮(经
/// `BrowseChromeController.pageBackAction` 登记)。⛔ 不再自绘路径栏 —— 账号名 / 面包屑 /
/// 设为片库根 / 排序 / 刷新 / 解除授权那一条整个去掉了:刷新用顶栏的按钮
/// (`refreshToken` 驱动),其余移进设置里的来源页(`BaiduPanSourceSettingsView`)。
///
/// ⚠️ 返回只退到**片库根为止**(`BaiduPanSourceViewModel.canGoUp`)—— 它就是这一页
/// 的最外层。设 `apps/LumaPlayer/Videos` 为片库根时,根目录就是 `Videos`,
/// 再往上是应用目录(那里只看得见「有个叫 Videos 的文件夹」),退上去没有意义。
/// 没配片库根时最外层是应用目录。
struct BaiduPanBrowserView: View {
    @Bindable var viewModel: BaiduPanSourceViewModel
    let store: PosterImageStore

    /// ⛔ 唤起播放窗口。**写请求与开窗必须成对出现**:`AppState.nowPlaying`
    /// 只是「请播放器播这一项」的请求,窗口不会因为写了请求自己出现 ——
    /// 少了 `openWindow` 就是点了播放毫无动静(Emby 那 4 个调用点同理)。
    @Environment(\.openWindow) private var openWindow
    /// 主窗口顶栏:把「返回上一层」登记上去
    @Environment(\.browseChrome) private var chrome

    /// 待确认删除的条目(右键菜单里点了「删除…」)。
    /// 弹窗状态放 View 的 `@State` —— 与 `ServerListView` 同一惯例。
    @State private var pendingDeletion: SourceItem?

    /// 一次「按 TMDB 命名重命名」请求:要改的目录 + 这条流程自己的 ViewModel。
    ///
    /// ⚠️ 两样东西必须装在**同一个** `Identifiable` 载荷里交给 `.sheet(item:)`。
    /// 早先拆成两个 `@State`(目录一个、ViewModel 一个)、再在 sheet 内容里
    /// `if let` 取第二个,后果是**第一次右键弹出的是个空白面板**:sheet 的内容闭包
    /// 在状态提交落地之前就被求值,那次读到的还是上一次的值(nil),面板便建成了空的;
    /// 第二次点之所以看着"正常",只是因为上一轮写进去的那个 ViewModel 还在 ——
    /// 显示出来的是**上一部剧的进度**,不是这次点的目录。
    ///
    /// ⚠️ `id` 用 `UUID` 而不是目录的 `fsID`:同一个目录连着改两次时若 id 相同,
    /// `BaiduPanRenameSeriesView` 的 `@State didStart` 会被复用,第二次不会重新走
    /// `start` —— 面板就卡在上一轮的结果上。
    ///
    /// ⛔ ViewModel 仍然**不放进 `sheet` 的内容闭包**里新建:那个闭包会重算,
    /// 每重算一次就丢一次已经走到的进度。存成请求的一部分,闭包只读它。
    private struct RenameRequest: Identifiable {
        let id = UUID()
        let directory: BaiduPanFile
        let viewModel: BaiduPanRenameSeriesViewModel
    }

    @State private var renameRequest: RenameRequest?
    /// 删除失败的原因(面板关掉后由 alert 报出,见类型注释里的范式)。
    @State private var actionErrorMessage: String?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Metrics.posterMinWidth), spacing: Metrics.gridSpacing)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // 剧目录走详情页(`BaiduPanSeriesDetailView`),它自己有剧名,不再叠一行目录名
            if viewModel.directoryShape.seriesStructure == nil {
                PageHeader(title: viewModel.currentDirectoryName) {
                    HStack(spacing: Metrics.spacingS) {
                        sortMenu
                        filterMenu
                    }
                }
            }
            if let notice = viewModel.notice {
                OnboardingNotice(text: notice, style: .warning)
                    .padding(.horizontal, Metrics.spacingL)
                    .padding(.vertical, Metrics.spacingS)
                Divider()
            }
            if let scrapeFailure = viewModel.scrapeFailure {
                // 刮削失败只影响封面:目录照常能看,所以是提示而不是错误页
                // (CLAUDE.md 硬规则 4「不静默吞错」:失败原因如实说出来)。
                OnboardingNotice(text: scrapeFailure, style: .warning)
                    .padding(.horizontal, Metrics.spacingL)
                    .padding(.vertical, Metrics.spacingS)
                Divider()
            }
            content
        }
        // 「窗口」菜单与调度中心里的窗口名(页上的目录名在 `PageHeader`)
        .navigationTitle(viewModel.currentDirectoryName)
        // 返回上一层登记到主窗口顶栏。⚠️ 只退到**片库根为止**(`canGoUp`):片库根就是
        // 这一页的最外层,到了就不登记,顶栏上也就没有返回按钮。
        .onChange(of: viewModel.canGoUp, initial: true) { _, canGoUp in
            registerBackAction(canGoUp: canGoUp)
        }
        .onDisappear {
            chrome?.pageBackAction = nil
            chrome?.setRootHasHero(false, source: viewModel.sourceID)
        }
        // 剧目录走详情页(有 hero):顶栏栏底换成 hero 的压暗
        .onChange(of: viewModel.directoryShape.seriesStructure != nil, initial: true) { _, isSeries in
            chrome?.setRootHasHero(isSeries, source: viewModel.sourceID)
        }
        .sheet(item: $pendingDeletion) { item in
            BaiduPanDeleteItemView(item: item, viewModel: viewModel) { message in
                actionErrorMessage = message
            }
        }
        .sheet(item: $renameRequest) { request in
            BaiduPanRenameSeriesView(
                viewModel: request.viewModel,
                directory: request.directory
            ) {
                // 名字全变了,缓存里的旧目录已经不对了
                Task { await viewModel.refreshFiles() }
            }
        }
        // 与 `ServerListView` 破坏性操作同一范式:确认面板关掉后再报失败
        .alert("操作失败", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    // MARK: - 返回上一层

    private func registerBackAction(canGoUp: Bool) {
        guard canGoUp else {
            chrome?.pageBackAction = nil
            return
        }
        let viewModel = viewModel
        chrome?.pageBackAction = {
            Task { await viewModel.goUp() }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoadingFiles, viewModel.items.isEmpty {
            VStack(spacing: Metrics.spacingS) {
                ProgressView()
                Text("正在读取目录…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure = viewModel.directoryFailure {
            failurePane(failure)
        } else if let structure = viewModel.directoryShape.seriesStructure {
            // 这一层是一部剧(剧目录下直接是集文件,或下面是一层层的季文件夹)
            // → 走详情页,而不是再铺一层文件网格。判定见 `BaiduPanSeriesLayout`。
            BaiduPanSeriesDetailView(
                viewModel: viewModel,
                structure: structure,
                store: store
            )
        } else if viewModel.sortedItems.isEmpty, viewModel.resumeCards.isEmpty {
            // ⚠️ 判的是 `sortedItems` 不是 `items`:整目录都被隐藏时 `items` 非空,
            // 用它会既不画网格、也不给空状态,只剩一片白。
            if isFilterHidingEverything {
                ContentUnavailableView {
                    Label("当前筛选下没有条目", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("这个目录里有内容,只是都被「\(viewModel.watchFilter.title)」这一档筛掉了。")
                } actions: {
                    Button("显示全部") { viewModel.setWatchFilter(.all) }
                }
            } else {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptySymbol)
                } description: {
                    Text(emptyHint)
                } actions: {
                    Button("刷新") { Task { await viewModel.refreshFiles() } }
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.spacingXL) {
                    if !viewModel.resumeCards.isEmpty {
                        resumeShelf
                    }
                    // 片库根才给「最近添加」(Emby 首页那一行的对位物):
                    // 子目录里再摆一行与下面的网格高度重叠,反而乱。
                    if !viewModel.recentItems.isEmpty {
                        recentShelf
                    }
                    if !viewModel.sortedItems.isEmpty {
                        LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                            ForEach(viewModel.sortedItems) { item in
                                card(for: item)
                            }
                        }
                    }
                }
                .padding(Metrics.spacingXL)
            }
        }
    }

    /// 一张卡片 + 右键菜单。
    ///
    /// 抽出来是因为它有两个用武之地:主网格与「最近添加」那一行。⛔ 不各写一份 ——
    /// 两处的右键菜单必须完全一致(删除 / 改名 / 标记已看都在这里)。
    private func card(for item: SourceItem) -> some View {
        BaiduPanCard(
            item: item,
            store: store,
            resumeSeconds: viewModel.resumeSeconds(for: item),
            isWatched: viewModel.isFullyWatched(item),
            watchedEpisodeCount: viewModel.watchedEpisodeCount(for: item),
            episodeTotal: viewModel.episodeTotal(for: item)
        ) {
            open(item)
        }
        .contextMenu {
            // 观看状态只对**能播的**文件给。目录要标「整部已看」
            // 得先知道里面有哪些集 —— 那是列目录(2 请求 / 层,
            // 配额见 `docs/BAIDU_PAN_API.md` §7),不在右键里悄悄做。
            if item.kind.isPlayable {
                if viewModel.isWatched(item) {
                    Button("标记为未看", systemImage: "arrow.counterclockwise") {
                        Task { await viewModel.markPlayed([item], played: false) }
                    }
                } else {
                    Button("标记为已看", systemImage: "checkmark.circle") {
                        Task { await viewModel.markPlayed([item], played: true) }
                    }
                }
            }
            // 只对**目录**给:这个功能的对象是「一整个剧集目录」,
            // 单集文件没有季 / 剧的上下文,改不出标准命名。
            if item.kind.isContainer, let file = viewModel.file(for: item) {
                Button("按 TMDB 命名重命名…", systemImage: "arrow.triangle.2.circlepath") {
                    renameRequest = RenameRequest(
                        directory: file,
                        viewModel: viewModel.makeRenameViewModel())
                }
            }
            Button("删除…", systemImage: "trash", role: .destructive) {
                pendingDeletion = item
            }
        }
    }

    /// 片库根上的「最近添加」:按网盘 `server_mtime` 倒序的前几条。
    ///
    /// ⚠️ 卡片宽度要**自己钉住**:`MediaShelf` 里是横向 `LazyHStack`,
    /// 没有网格的列宽可借,不钉就会按图片比例乱撑。
    private var recentShelf: some View {
        MediaShelf(title: "最近添加") {
            ForEach(viewModel.recentItems) { item in
                card(for: item)
                    .frame(width: Metrics.posterMinWidth)
            }
        }
    }

    // MARK: - 排序 / 筛选

    /// 排序菜单(页头右侧)。
    ///
    /// ⚠️ 放在页头而不是主窗口工具栏:工具栏只有「返回上一层」一个控件
    /// (用户明确要的简法)。排序与筛选都是**这一页**的事,放这里才对得上。
    /// ⛔ 换档不重新请求目录 —— 排的是已经在手上的条目(配额见 `docs/BAIDU_PAN_API.md` §7)。
    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: Binding(
                get: { viewModel.sortOrder },
                set: { viewModel.setSortOrder($0) }
            )) {
                ForEach(BaiduPanSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button(
                viewModel.sortAscending ? "改为降序" : "改为升序",
                systemImage: viewModel.sortAscending ? "arrow.down" : "arrow.up"
            ) {
                viewModel.toggleSortDirection()
            }
        } label: {
            Label("排序", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("排序(只重排已取回的条目,不重新请求目录)")
        .accessibilityLabel("排序:\(viewModel.sortOrder.title)")
    }

    /// 观看状态筛选(全部 / 未看 / 已看)。数据全来自本地续播库,零请求。
    ///
    /// 图标的选中态用 ✓ 而不是只换文字:菜单收起后按钮上只剩一个词,
    /// 「已看」与「未看」两个词太像,带上图标一眼能分清。
    private var filterMenu: some View {
        Menu {
            Picker("筛选", selection: Binding(
                get: { viewModel.watchFilter },
                set: { viewModel.setWatchFilter($0) }
            )) {
                ForEach(BaiduPanWatchFilter.allCases) { filter in
                    Label(filter.title, systemImage: filter.symbol).tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(viewModel.watchFilter.title, systemImage: viewModel.watchFilter.symbol)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("按观看状态筛选(只筛已取回的条目,不重新请求目录)")
        .accessibilityLabel("筛选:\(viewModel.watchFilter.title)")
    }

    /// 筛选把这一屏筛空了(目录本身有内容)。
    ///
    /// ⚠️ 必须与「这个目录是空的」分开说:前者是用户自己设的条件,
    /// 端一句「这里还没有可播的文件」会让人以为片库坏了。
    private var isFilterHidingEverything: Bool {
        viewModel.watchFilter != .all && !viewModel.items.isEmpty
    }

    // MARK: - 继续观看

    /// 顶部「继续观看」区:跨目录把看过的东西捞出来(Emby 首页那一行的对位物)。
    /// 数据来自本地续播库(百度没有服务端进度),见 `BaiduPanSourceViewModel.resumeCards`。
    ///
    /// ⚠️ 交互也与 Emby 那一行对齐(用户要求):点播放按钮直接续播,点卡片其余位置进详情页。
    private var resumeShelf: some View {
        MediaShelf(title: "继续观看") {
            ForEach(viewModel.resumeCards) { card in
                BaiduResumeCardView(
                    card: card,
                    store: store,
                    isPreparing: viewModel.preparingPlaybackFileID == card.fileID,
                    onPlay: { play(card) },
                    onOpenDetail: { openDetail(card) }
                )
                .contextMenu {
                    Button("继续播放", systemImage: "play.fill") { play(card) }
                    Button("显示详情", systemImage: "info.circle") { openDetail(card) }
                    Divider()
                    Button("标记为已看", systemImage: "checkmark.circle") {
                        Task { await viewModel.markPlayed(card) }
                    }
                    Button("移出继续观看", systemImage: "eye.slash") {
                        Task { await viewModel.removeResumeCard(card) }
                    }
                }
            }
        }
    }

    // MARK: - 动作

    /// 目录 → 进去;可播文件 → 播;其余(图片等)不在这里出现(合成器已滤掉)。
    private func open(_ item: SourceItem) {
        if item.kind.isContainer {
            Task { await viewModel.enter(item) }
        } else if item.kind.isPlayable {
            viewModel.play(item)
            openWindow(id: PlayerSceneRoot.windowID)
        }
    }

    /// 续播卡片的播放按钮 → 直接续播(起播位置由本地续播库给)。
    ///
    /// ⚠️ 起播前要先补列它所在的目录(换集入口要兄弟集,见
    /// `BaiduPanSourceViewModel.play(_ card:)`),所以这里等它一次再开窗 ——
    /// 顺序反了会先弹一个黑窗口。
    private func play(_ card: BaiduResumeCard) {
        Task {
            if await viewModel.play(card) {
                openWindow(id: PlayerSceneRoot.windowID)
            }
        }
    }

    /// 续播卡片其余位置 → 进它的详情页(与 Emby 首页那一行同一套交互)。
    /// ⛔ 这里不 `openWindow`:详情页是主窗口里的一屏,不是播放窗口。
    private func openDetail(_ card: BaiduResumeCard) {
        Task { await viewModel.openDetail(for: card) }
    }

    /// 目录读失败。分两种处置:
    ///
    /// - **应用目录本身读不出来** → 给「核对应用目录名」(改那个名字),
    ///   而不是「重试」。因为这种失败九成是目录名与控制台里的应用名不一致,
    ///   重试多少次都是同一个结果(可访问范围完全由那一个值决定)。
    /// - 其余(子目录、网络、token)→ 老实的错误 + 重试。
    private func failurePane(_ failure: BaiduPanDirectoryFailure) -> some View {
        VStack(spacing: Metrics.spacingM) {
            if failure.isApplicationRootUnavailable {
                OnboardingFormHeader(
                    systemImage: "folder.badge.questionmark",
                    title: "读不到应用目录",
                    subtitle: applicationRootHint
                )
                Button("核对应用目录名") {
                    Task { await viewModel.beginConfigurationEdit() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                OnboardingNotice(text: failure.message, style: .error)
            }
            Button("重试") { Task { await viewModel.refreshFiles() } }
        }
        .padding(Metrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 空目录的引导。
    ///
    /// ⚠️ 刻意把「空的」与「还不存在」合在一段里说:对一个**不存在**的目录,
    /// 百度未必返回错误码 —— 也可能就是一个空 `list`。
    /// ⛔ 不猜它属于哪一种,把两种成因和各自的做法都摆出来。
    ///
    /// 另一件必须讲清的事:**`/apps` 这一层用户建不了**(百度把 `apps` 当保留
    /// 关键字,自建会报「apps 为关键字,无法创建」)。用户能碰的只有
    /// 「我的应用数据」**里面** —— 在那里新建一个与控制台应用名**完全一致**
    /// (含大小写)的文件夹。⛔ 绝不能写成「去网盘里建一个 apps 文件夹」。
    /// ⚠️ 整层都在、只是被隐藏了,与「本来就没有」是两件事:前者要告诉人
    /// 东西还在哪里能找回来,⛔ 不能混成一句「这里没有可播的文件」——
    /// 那会让人以为片子丢了。
    private var emptyTitle: String {
        viewModel.items.isEmpty ? "这里还没有可播的文件" : "这一层都被隐藏了"
    }

    private var emptySymbol: String {
        viewModel.items.isEmpty ? "folder" : "eye.slash"
    }

    private var emptyHint: String {
        guard viewModel.items.isEmpty else {
            return "这些条目只是在本机被隐藏了,网盘上的文件都还在。"
                + "设置 →「已隐藏」里可以逐条恢复。"
        }
        let name = viewModel.folderName ?? "应用目录"
        // 当前是应用目录根时,「空的」更可能是**整个应用目录还没建出来** ——
        // 给一段「去网盘里建同名文件夹」的引导;子目录里空的就只是空的。
        guard viewModel.currentDirectory == viewModel.rootDirectory else {
            return "这一层没有可播的文件。往上一级看看,或者把视频放进这个目录再回来刷新。"
        }
        return "第三方应用只能访问网盘里的「我的应用数据/\(name)」,访问不到其它地方。"
            + "如果网盘里还看不到这个目录:打开百度网盘的「我的应用数据」,新建一个名为"
            + " \(name) 的文件夹(名字要与开放平台控制台里的「应用名称」完全一致,"
            + "包括大小写),再把视频放进去,然后回来刷新。"
            + "也可能它还没生成 —— 网盘通常在应用第一次读取时自动建出这个目录。"
    }

    private var applicationRootHint: String {
        let name = viewModel.folderName ?? "应用目录"
        return "百度没给出 /apps/\(name) 这个目录。请核对开放平台控制台里的「应用名称」"
            + "与本 App 里填的完全一致,并确认网盘里的「我的应用数据/\(name)」确实存在。"
    }
}

/// 百度来源的一张卡片。
///
/// 视觉与 `MediaCard`(Emby 那边)保持一致:非玻璃卡片、`.fill` 的图只当 overlay
/// 绘制(否则会按自己的比例报告溢出尺寸、把网格撑乱)、续播用文字而不是只靠颜色
/// (DesignTokens.swift「界面规则」)。
private struct BaiduPanCard: View {
    let item: SourceItem
    let store: PosterImageStore
    /// 本地续播位置(秒);nil = 没看到一半(未看 / 已看完都是 nil)
    let resumeSeconds: Double?
    /// 已看完(本地续播库的显式标记,或自动判定过了 90%)
    let isWatched: Bool
    /// 目录卡:这一层之下本地已记录看过的集数(0 = 不显示)
    let watchedEpisodeCount: Int
    /// 目录卡:这一部剧**一共几集**。nil = 还没进过详情页,不知道总数
    /// (见 `BaiduPanSourceViewModel.episodeTotal(for:)`)
    let episodeTotal: Int?
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                // 尺寸由 Color.clear 钉死,图片只当 overlay(与 `MediaCard` 同一个理由)
                Color.clear
                    .aspectRatio(imageAspectRatio, contentMode: .fit)
                    .overlay {
                        PosterImage(
                            descriptor: item.poster,
                            store: store,
                            placeholderSystemImage: placeholderSymbol
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .overlay(alignment: .topTrailing) {
                        if isWatched { WatchedBadge() }
                    }
                    .scaleEffect(isHovering ? Self.hoverScale : 1)
                    .shadow(
                        color: .black.opacity(isHovering ? 0.25 : 0),
                        radius: Metrics.spacingS,
                        y: Metrics.spacingXS
                    )
                textBlock
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private static var hoverScale: CGFloat { 1.03 }

    /// 分集用 16:9 横版,其余用海报比例(2:3)。
    ///
    /// ⚠️ 为什么分集要换:分集拿的是**分集剧照**(16:9 横图,`docs/TMDB_API.md` §8),
    /// 塞进竖版框会被裁掉一大半画面。一屏全是分集的剧集目录因此长成 Emby 的分集视图。
    private var imageAspectRatio: Double {
        item.kind == .episode ? Metrics.landscapeAspectRatio : Metrics.posterAspectRatio
    }

    /// 标题 + 副标题。**高度固定**:文件名有的 1 行有的 2 行、有的条目又压根没有副标题,
    /// 高度跟着内容走就会让网格里的卡片高高低低。
    ///
    /// 钉高度的办法是叠一份**等行数的隐藏文本**当尺子(两行标题 + 一行副标题),
    /// 行高由系统按字体算 —— 写死像素值会在字体/缩放变化时对不上。
    @ViewBuilder
    private var textBlock: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            ZStack(alignment: .topLeading) {
                Text(Self.placeholderTwoLines)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    // 只是把高度撑起来的尺子,别让 VoiceOver 把它读出来
                    .accessibilityHidden(true)
                Text(displayTitle)
                    .font(.body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack(alignment: .topLeading) {
                Text(Self.placeholderOneLine)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .accessibilityHidden(true)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 撑两行标题用的隐藏文本。`\n` 让 `Text` 真的排两行,ASCII 是为了不落到中文回退字体
    /// (回退字体行高和 SF 不一致,尺子就量歪了)。
    private static let placeholderTwoLines = "X\nX"
    private static let placeholderOneLine = "X"

    /// 主标题:分集优先显示**集名** —— 集名才是这一集的标识,
    /// 而剧名(`琅琊榜`)整目录每一张都一样、看了等于没看。
    /// 没有集名(TMDB 未命中 / 未配置 token)时退回 `title`。
    private var displayTitle: String {
        item.episodeTitle ?? item.title
    }

    /// 副标题:进度类信息优先,其次是集号 / 时长 / 年份 / 文件夹。
    ///
    /// 顺序:续播位置 > 「第 n 集 · 已看」> 「已看」> 「第 n 集 · 时长」>
    /// 时长 > 年份 > 目录的「已看 N 集」/「文件夹」。⛔ 都没有就不显示,不填占位符。
    ///
    /// ⚠️ 时长来自 `filemetas` 那一趟(2026-10-21 起列表里就有);拿不到时
    /// 整段不出现,⛔ 不写「未知时长」。
    ///
    /// ⚠️ 目录卡的集数分三种形态:知道总数就是「已看 3 / 共 12 集」,只知道已看
    /// 就还是「已看 3 集」,两样都没有就是「文件夹」。总数来自**本地记录**
    /// (进过一次详情页才知道),⛔ 不为网格上的一个数字去列子目录(配额)。
    private var subtitle: String? {
        if let resumeSeconds, resumeSeconds > 0 {
            return "已看到 \(PlayerTime.text(resumeSeconds))"
        }
        if let episode = item.episodeNumber {
            let label = isWatched ? "第 \(episode) 集 · 已看" : "第 \(episode) 集"
            guard !isWatched, let runtime = MediaFormat.duration(seconds: item.durationSeconds ?? 0)
            else { return label }
            return "\(label) · \(runtime)"
        }
        if isWatched { return "已看" }
        if let runtime = MediaFormat.duration(seconds: item.durationSeconds ?? 0) {
            return runtime
        }
        if let year = item.year { return String(year) }
        if item.kind.isContainer {
            if let episodeTotal, watchedEpisodeCount > 0 {
                return "已看 \(watchedEpisodeCount) / 共 \(episodeTotal) 集"
            }
            if let episodeTotal { return "共 \(episodeTotal) 集" }
            return watchedEpisodeCount > 0 ? "已看 \(watchedEpisodeCount) 集" : "文件夹"
        }
        return nil
    }

    private var placeholderSymbol: String {
        switch item.kind {
        case .folder: return "folder.fill"
        case .audio: return "music.note"
        case .episode: return "tv"
        case .video, .movie: return "film"
        case .image: return "photo"
        case .unknown: return "doc"
        }
    }

    private var accessibilityText: String {
        var parts = [displayTitle]
        if item.kind.isContainer { parts.append("文件夹") }
        if let episode = item.episodeNumber { parts.append("第 \(episode) 集") }
        if isWatched { parts.append("已看") }
        if !isWatched, let runtime = MediaFormat.duration(seconds: item.durationSeconds ?? 0) {
            parts.append(runtime)
        }
        if item.kind.isContainer, watchedEpisodeCount > 0 {
            parts.append(
                episodeTotal.map { "本地记录已看 \(watchedEpisodeCount) 集,共 \($0) 集" }
                    ?? "本地记录已看 \(watchedEpisodeCount) 集")
        } else if item.kind.isContainer, let episodeTotal {
            parts.append("共 \(episodeTotal) 集")
        }
        if let year = item.year { parts.append(String(year)) }
        if let resumeSeconds, resumeSeconds > 0 {
            parts.append("已看到 \(PlayerTime.text(resumeSeconds))")
        }
        return parts.joined(separator: ",")
    }
}

/// 「继续观看」区的一张横版卡片。
///
/// 交互与 Emby 首页那一行的 `LandscapeCard` **完全对齐**(用户要求):悬停时画面上
/// 出现玻璃播放按钮,**点它直接续播**;**点卡片其余位置进详情页**。
/// ⚠️ 点空白处不再直接播 —— 那是这一版之前的行为,与 Emby 不一致。
///
/// 视觉与 `BaiduPanCard` 的差别:横版(续播用剧照比例,与 Emby 侧 `LandscapeCard` 一致)、
/// 副标题报「已看到 mm:ss」(「下一集」占位则报「下一集」)、有总时长时在图上画进度条。
private struct BaiduResumeCardView: View {
    let card: BaiduResumeCard
    let store: PosterImageStore
    /// 正在为这张卡片补列目录(换集入口要兄弟集)。转圈 + 禁止重复点击
    var isPreparing = false
    /// 点播放按钮:直接续播
    let onPlay: () -> Void
    /// 点卡片其余位置:进详情页
    let onOpenDetail: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            // 尺寸由 Color.clear 钉死,图片 / 播放按钮 / 进度条只当 overlay
            // (与 `BaiduPanCard` 同理)
            Color.clear
                .aspectRatio(Metrics.landscapeAspectRatio, contentMode: .fit)
                .frame(width: Metrics.landscapeCardWidth)
                .overlay {
                    PosterImage(
                        descriptor: card.poster,
                        store: store,
                        placeholderSystemImage: "play.rectangle"
                    )
                }
                .overlay {
                    // 补列目录期间给一个明确的「正在准备」—— 那一步要发两次请求,
                    // 没有它点了就像没反应
                    if isPreparing {
                        ZStack {
                            Color.black.opacity(0.45)
                            ProgressView()
                        }
                    }
                }
                .overlay {
                    // 悬停才出现的播放按钮(与 `LandscapeCard` 同一画法):
                    // 它是这张卡上**唯一**「点了就播」的地方,点别处去详情页
                    if isHovering, !isPreparing {
                        Button(action: onPlay) {
                            Image(systemName: "play.fill")
                                .font(.title2)
                                .padding(Metrics.spacingM)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .help("继续播放")
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let fraction = progressFraction {
                        CardProgressBar(fraction: fraction)
                            .padding(Metrics.spacingS)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .scaleEffect(isHovering ? Self.hoverScale : 1)
                .shadow(
                    color: .black.opacity(isHovering ? 0.25 : 0),
                    radius: Metrics.spacingS,
                    y: Metrics.spacingXS
                )
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text(card.title)
                    .font(.body)
                    .lineLimit(1)
                Text(isPreparing ? "正在准备…" : card.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: Metrics.landscapeCardWidth, alignment: .leading)
        }
        // 卡片整体可点(进详情),播放按钮盖在上面并先吃掉点击 ——
        // 与 `LandscapeCard` 同一个做法:Button 的命中优先于外层的手势。
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenDetail)
        // 补列目录期间整张卡不可点:此刻起播与跳转都还没准备好。
        // ⚠️ 两个都要:`.disabled` 是给辅助功能/控件的那一层,而这张卡的主体是
        // `onTapGesture`(不是 Button)—— 靠 `allowsHitTesting` 把命中一并关掉。
        .disabled(isPreparing)
        .allowsHitTesting(!isPreparing)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.title),\(card.subtitle)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpenDetail() }
        .accessibilityAction(named: "播放") { onPlay() }
    }

    private static var hoverScale: CGFloat { 1.03 }

    /// 进度条比例。百度侧**可能没有总时长**(续播库里 `durationSeconds` 为 nil),
    /// 那就**不画**进度条 —— ⛔ 不猜一个比例。
    ///
    /// 「下一集」占位(上一集刚看完)也不画:它一秒都还没看,画一条空条只是噪音。
    private var progressFraction: Double? {
        guard !card.isUpNext else { return nil }
        guard let duration = card.durationSeconds, duration > 0 else { return nil }
        return min(max(card.positionSeconds / duration, 0), 1)
    }
}
