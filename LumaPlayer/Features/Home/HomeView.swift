import SwiftUI

/// 首页(主窗口导航栈的根页)。
///
/// 自上而下:hero(`HomeHeroCarousel`,几项**随机推荐**轮流铺满顶部)→ 我的媒体
/// → 继续观看(横版)→ 每个媒体库的「最新」(海报)。
/// 与 Emby Web 一样,**加载成功但为空的分区整行不显示**(不放「没有内容」占位);
/// 失败的分区照常显示错误与重试入口;全部为空时给一个整页空状态。
///
/// ⚠️ 「继续观看」**既是一行货架,也曾是 hero 的数据源**(旧 `heroPick` 抢第一个
/// 有背景图的)。2026-10-15 起 hero 改吃随机推荐,这一行不再喂 hero,位置也不变 ——
/// 「看一半接着看」是刚需,不能因为没有 hero 就不露出。
///
/// 「我的媒体」是媒体库的唯一入口,所以它的加载态与失败态必须露出来 ——
/// 失败时静默少一行,用户只会以为这台服务器没有媒体库。
///
/// 媒体库多时的两点约束(别回退):
/// - 外层是 `LazyVStack`:屏幕外的行不建,它的卡片也就不提前发图片请求,
///   首屏的图片不被下方的行挤着排队;
/// - 每一行是独立的子视图,只读自己那一行的 `HomeViewModel.Row`:
///   一行的数据到了只让这一行重新求值,不让整页跟着重算。
///   本视图的 `body` 只依赖媒体库列表(决定有哪些「最新」行)。
struct HomeView: View {
    let container: AppContainer
    let server: ServerProfile
    /// 打开某一项的详情(主窗口 push 详情页)
    let onOpenItem: (EmbyItem) -> Void
    /// 打开某个媒体库(主窗口 push 媒体库页)
    let onOpenLibrary: (EmbyView) -> Void
    /// 变化即重新加载(「Reload」(⌘R))
    let refreshToken: Int

    /// 首页是导航栈的根,push 别的页时不会销毁,ViewModel 一直留着;
    /// 状态按服务器分开存,切到别的服务器再切回来也不闪 loading(issue #3)
    @State private var viewModel: HomeViewModel

    init(
        container: AppContainer,
        server: ServerProfile,
        onOpenItem: @escaping (EmbyItem) -> Void,
        onOpenLibrary: @escaping (EmbyView) -> Void,
        refreshToken: Int
    ) {
        self.container = container
        self.server = server
        self.onOpenItem = onOpenItem
        self.onOpenLibrary = onOpenLibrary
        self.refreshToken = refreshToken
        self._viewModel = State(initialValue: HomeViewModel(container: container))
    }

    /// hero 还垫在顶栏底下(没被滚出去)。滚出去之后顶栏下面是货架,
    /// 栏底要换回窗口底色那种压暗,否则白底货架直接从按钮底下穿过
    @State private var isHeroUnderChrome = true

    var body: some View {
        // 只取当前服务器的那份:切服务器后、新一轮 `load` 之前,也不会露出别台的内容
        let sections = viewModel.sections(for: server.id)
        let context = HomeRowContext(
            container: container,
            server: server,
            viewModel: viewModel,
            onOpenItem: onOpenItem,
            onOpenLibrary: onOpenLibrary
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // hero 铺到窗口最上沿(压在浮动顶栏下面);没有 hero 时它只留出顶栏的高度
                HomeHeroSlot(sections: sections, context: context, isUnderChrome: isHeroUnderChrome)
                LazyVStack(alignment: .leading, spacing: Metrics.spacingXL) {
                    HomeLibrariesRow(row: sections.views, context: context)
                    HomeResumeRow(row: sections.resume, context: context)
                    ForEach(HomeViewModel.latestViews(in: sections.views.state.value ?? [])) { view in
                        HomeLatestRow(view: view, row: sections.latest[view.id], context: context)
                    }
                    HomeEmptyState(sections: sections)
                }
                .padding(Metrics.spacingXL)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(.container, edges: .top)
        // ⛔ 关掉顶部的系统滚动边缘效果:它在 hero 顶上盖出一条窗口底色的柔边(浅色模式下是
        // 白带,2026-10-15 截图)。顶栏自己垫压暗(`BrowseChromeScrim`),滚过 hero 后换成
        // 窗口底色那种,见 `isHeroUnderChrome`
        .scrollEdgeEffectHidden(true, for: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let scrolled = geometry.contentOffset.y + geometry.contentInsets.top
            return scrolled < HomeHero.height(forWidth: geometry.containerSize.width) - Metrics.chromeBarHeight
        } action: { _, under in
            isHeroUnderChrome = under
        }
        .navigationTitle("首页")
        // 加载 / 刷新中整页不可点(顶栏下沿的加载线在走),避免对旧内容做操作
        .allowsHitTesting(!viewModel.isLoading)
        .task(id: "\(server.id.uuidString)-\(refreshToken)") {
            viewModel.load(server: server)
        }
        // 设置窗口在**另一个场景**里,改完开关这里不会自动重新 `load`。
        // hero 的显示本身是自动的(`HomeHeroSlot` 读了 `@Observable` 的这一项),
        // 但推荐数据得有人去发这一路请求 / 把旧行清掉。
        // ⛔ 不在这里整页 `load` —— 改的是一个显示开关,不该把媒体库、继续观看、
        // 各「最新」全部重来一遍(真实服务器使用纪律:低频率)
        .onChange(of: container.homeAppearance.showsHeroRecommendations) {
            viewModel.recommendationsPreferenceChanged(server: server)
        }
        .reportsPageLoading(viewModel.isLoading, page: .home, to: container.state)
        .onChange(of: container.state.lastFinishedPlayback) { _, finished in
            guard let finished, finished.serverID == server.id else { return }
            viewModel.refreshProgress(server: server)
        }
        .alert("移出继续观看", isPresented: Binding(
            get: { viewModel.resumeActionError != nil },
            set: { if !$0 { viewModel.resumeActionError = nil } }
        )) {
            Button("好", role: .cancel) { }
        } message: {
            Text(viewModel.resumeActionError ?? "")
        }
        .alert("无法播放", isPresented: Binding(
            get: { viewModel.seriesPlayError != nil },
            set: { if !$0 { viewModel.seriesPlayError = nil } }
        )) {
            Button("好", role: .cancel) { }
        } message: {
            Text(viewModel.seriesPlayError ?? "")
        }
    }
}

/// 首页各行共用的依赖与动作(MainActor:只在视图里构造与调用)
@MainActor
private struct HomeRowContext {
    let container: AppContainer
    let server: ServerProfile
    let viewModel: HomeViewModel
    let onOpenItem: (EmbyItem) -> Void
    let onOpenLibrary: (EmbyView) -> Void

    func play(_ item: EmbyItem, fromBeginning: Bool = false, openWindow: OpenWindowAction) {
        container.play(item, on: server, fromBeginning: fromBeginning)
        openWindow(id: PlayerSceneRoot.windowID)
    }
}

// MARK: - hero

/// hero 的位置。要读继续观看与各「最新」行的状态,所以单独成一个视图
/// (与 `HomeEmptyState` 同理):任何一行变化只让它重新求值,不连带整页。
///
/// 首页整页 `ignoresSafeArea(edges: .top)`:有 hero(含加载中的骨架)时图铺到窗口最上沿;
/// 没有 hero 时这里放一块顶栏高度的空白,货架从顶栏下沿开始。
/// 有没有 hero 经 `BrowseChromeController.setRootHasHero` 告诉顶栏(决定栏底压暗方式);
/// hero 被滚出顶栏之后也报「没有」(`isUnderChrome`,由 `HomeView` 按滚动位置算)。
private struct HomeHeroSlot: View {
    let sections: HomeViewModel.Sections
    let context: HomeRowContext
    let isUnderChrome: Bool

    @Environment(\.openWindow) private var openWindow
    @Environment(\.browseChrome) private var chrome

    var body: some View {
        let pick = HomeViewModel.heroPick(
            recommended: sections.recommended.state,
            views: sections.views.state,
            resume: sections.resume.state,
            latest: { sections.latest[$0.id]?.state ?? .idle },
            // 设置 → 通用 →「首页推荐」关掉时整块 hero 不画(⛔ 不走退路,见 `heroPick`)
            recommendationsEnabled: context.container.homeAppearance.showsHeroRecommendations
        )
        Group {
            switch pick {
            case .pending:
                SkeletonBlock(cornerRadius: 0)
                    .frame(height: HomeHero.height(forWidth: 0))
            case .none:
                Color.clear
                    .frame(height: Metrics.chromeBarHeight)
            case .items(let items):
                HomeHeroCarousel(
                    items: items,
                    serverID: context.server.id,
                    store: context.container.posters,
                    onPlay: { item in
                        // 剧集先定位该播的分集(看过接着看,没看过第一集),再起播
                        if item.kind == .series {
                            context.viewModel.playSeries(item, server: context.server) { episode in
                                context.play(episode, openWindow: openWindow)
                            }
                        } else {
                            context.play(item, openWindow: openWindow)
                        }
                    },
                    resolvingItemID: context.viewModel.resolvingSeriesID,
                    onOpenDetail: { context.onOpenItem($0) }
                )
                // 换了一批就整块重建(轮播回到第一张,各项的 Logo 标记也不串)。
                // 同一批不重建:行对象被刷新(⌘R 之外的重新加载)时用户停在第 3 张,
                // 不该被弹回第 1 张 —— 所以 id 取的是**条目 id 列表**,不是行对象
                .id(items.map(\.id).joined(separator: ","))
            }
        }
        // ⚠️ 监听的是「服务器 + 有没有 hero」,不只是那个布尔值:切服务器时这个视图不重建,
        // 前后两台都有 hero 的话布尔值一直是 true,`onChange` 不触发,新服务器的 id 就从没
        // 登记过 —— 顶栏退回窗口底色那种压暗,hero 顶上一条白带(2026-10-15 截图复现)
        .onChange(of: HeroReport(source: context.server.id, hasHero: pick != .none && isUnderChrome), initial: true) { _, report in
            chrome?.setRootHasHero(report.hasHero, source: report.source)
        }
    }
}

/// `HomeHeroSlot` 上报给顶栏的内容(见那里 `onChange` 的注释)
private struct HeroReport: Equatable {
    let source: UUID
    let hasHero: Bool
}

// MARK: - 我的媒体

/// 媒体库入口。这里是**唯一**的媒体库入口,加载态与失败态都要露出来:
/// 失败时少一行而不报错,等于骗用户「这台服务器没有媒体库」。
private struct HomeLibrariesRow: View {
    let row: HomeViewModel.Row<[EmbyView]>
    let context: HomeRowContext

    private static let title = "我的媒体"

    var body: some View {
        switch row.state {
        case .idle, .loading:
            // 首屏还没有内容:灰色骨架占位(横版块),不闪白屏
            SkeletonShelf(
                title: Self.title,
                cardWidth: Metrics.libraryTileWidth,
                aspectRatio: Metrics.landscapeAspectRatio,
                count: 4
            )
        case .failed(let failure):
            HomeSectionError(title: Self.title, failure: failure, context: context)
        case .loaded(let views):
            if views.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.spacingS) {
                    Text(Self.title)
                        .font(.title3.bold())
                    Text("这台服务器没有媒体库入口。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                MediaShelf(title: Self.title) {
                    ForEach(views) { view in
                        Button {
                            context.onOpenLibrary(view)
                        } label: {
                            LibraryTile(view: view, serverID: context.server.id, store: context.container.posters)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - 继续观看(横版)

private struct HomeResumeRow: View {
    let row: HomeViewModel.Row<[EmbyItem]>
    let context: HomeRowContext

    @Environment(\.openWindow) private var openWindow

    private static let title = "继续观看"

    var body: some View {
        let title = Self.title
        switch row.state {
        case .idle:
            EmptyView()
        case .loading:
            SkeletonShelf(
                title: title,
                cardWidth: Metrics.landscapeCardWidth,
                aspectRatio: Metrics.landscapeAspectRatio,
                count: 4
            )
        case .failed(let failure):
            HomeSectionError(title: title, failure: failure, context: context)
        case .loaded(let items):
            if !items.isEmpty {
                MediaShelf(title: title) {
                    ForEach(items) { item in
                        LandscapeCard(
                            item: item,
                            serverID: context.server.id,
                            store: context.container.posters,
                            onPlay: { context.play(item, openWindow: openWindow) }
                        )
                        .onTapGesture { context.onOpenItem(item) }
                        .contextMenu { HomeItemMenu(item: item, canHideFromResume: true, context: context) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { context.onOpenItem(item) }
                        .accessibilityAction(named: "播放") { context.play(item, openWindow: openWindow) }
                    }
                }
            }
        }
    }
}

// MARK: - 最新

private struct HomeLatestRow: View {
    let view: EmbyView
    /// 媒体库列表刚回来、`loadLatest` 还没建行时为 nil,按 `.idle` 处理
    let row: HomeViewModel.Row<[EmbyItem]>?
    let context: HomeRowContext

    var body: some View {
        // 标题就是库名,不加「最新 ·」前缀(2026-10-02 用户要求);没名字时与「我的媒体」里的入口块一致
        let title = view.name ?? "未命名媒体库"
        switch row?.state ?? .idle {
        case .idle:
            EmptyView()
        case .loading:
            SkeletonShelf(title: title, count: 6)
        case .failed(let failure):
            HomeSectionError(title: title, failure: failure, context: context)
        case .loaded(let items):
            if !items.isEmpty {
                MediaShelf(title: title, seeAll: { context.onOpenLibrary(view) }) {
                    ForEach(items) { item in
                        Button {
                            context.onOpenItem(item)
                        } label: {
                            MediaCard(item: item, serverID: context.server.id, store: context.container.posters)
                                .frame(width: Metrics.posterMinWidth)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { HomeItemMenu(item: item, context: context) }
                    }
                }
            }
        }
    }
}

// MARK: - 整页空状态

/// 所有可见分区都加载完且都为空时的整页提示。要读所有行的状态,
/// 所以单独成一个视图:任何一行变化只让它(很轻)重新求值,不连带整页。
private struct HomeEmptyState: View {
    let sections: HomeViewModel.Sections

    var body: some View {
        if HomeViewModel.isEverythingEmpty(
            views: sections.views.state,
            resume: sections.resume.state,
            latest: sections.latest.values.map(\.state)
        ) {
            ContentUnavailableView(
                "这台服务器上还没有可看的内容",
                systemImage: "film.stack",
                description: Text("媒体库里添加了影片或剧集后,会出现在这里。")
            )
            .padding(.top, Metrics.spacingXL)
        }
    }
}

// MARK: - 共用

private struct HomeItemMenu: View {
    let item: EmbyItem
    var canHideFromResume = false
    let context: HomeRowContext

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if item.kind == .movie || item.kind == .episode {
            Button(item.progressFraction == nil ? "播放" : "继续播放", systemImage: "play.fill") {
                context.play(item, openWindow: openWindow)
            }
            if item.progressFraction != nil {
                Button("从头播放", systemImage: "arrow.counterclockwise") {
                    context.play(item, fromBeginning: true, openWindow: openWindow)
                }
            }
            Divider()
        }
        Button("显示详情", systemImage: "info.circle") {
            context.onOpenItem(item)
        }
        if canHideFromResume {
            Divider()
            Button("移出继续观看", systemImage: "eye.slash") {
                context.viewModel.hideFromResume(item, server: context.server)
            }
            .disabled(context.viewModel.updatingResumeIDs.contains(item.id))
        }
    }
}

private struct HomeSectionError: View {
    let title: String
    let failure: LoadFailure
    let context: HomeRowContext

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text(title)
                .font(.title3.bold())
            ErrorStateView(
                failure: failure,
                // 重试即整页重新加载:已加载的分区保持原样不闪(见 `HomeViewModel.load`)
                retry: { context.viewModel.load(server: context.server) },
                login: { context.container.state.serverNeedingLogin = context.server }
            )
            .frame(height: Metrics.posterMinWidth)
        }
    }
}

/// 「我的媒体」里的一个媒体库入口:封面 + 名称的横版块(非玻璃,DesignTokens.swift「界面规则」)。
/// 媒体库有 `Primary` 图就显示封面,没有则退回按类型选的图标。
private struct LibraryTile: View {
    let view: EmbyView
    let serverID: UUID
    let store: PosterImageStore

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            // 尺寸由 Color.clear 钉死,图片只当 overlay:横向 ScrollView 不给高度提议,
            // 直接 .aspectRatio(.fit) 会让高度跟着源图固有比例走(2:3 封面高出 2.7 倍)
            Color.clear
                .aspectRatio(Metrics.landscapeAspectRatio, contentMode: .fit)
                .frame(width: Self.width)
                .overlay {
                    PosterImage(spec: imageSpec, store: store, placeholderSystemImage: view.symbolName)
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card)
                        .stroke(Color.accentColor, lineWidth: isHovering ? 2 : 0)
                }
            Text(view.name ?? "未命名媒体库")
                .font(.body)
                .lineLimit(1)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .accessibilityElement(children: .combine)
    }

    private static var width: CGFloat { Metrics.libraryTileWidth }

    private var imageSpec: ImageSpec? {
        view.primaryImageTagValue.map {
            ImageSpec(serverID: serverID, itemID: view.id, type: .primary, tag: $0, maxWidth: Int(Self.width * 2))
        }
    }
}
