import SwiftUI

/// 首页(主窗口导航栈的根页)。自上而下:hero(`HomeHeroCarousel`,随机推荐)→ 我的媒体
/// → 继续观看(横版)→ 每个媒体库的「最新」(海报)。
/// 与 Emby Web 一样,**加载成功但为空的分区整行不显示**(不放「没有内容」占位);失败的分区照常露错误与重试。
/// 「继续观看」是刚需,不能因为没有 hero 就不露出。
///
/// 「我的媒体」是媒体库的唯一入口,加载态与失败态必须露出来 —— 静默少一行,用户只会以为这台服务器没有媒体库。
///
/// 媒体库多时的两点约束(别回退):外层 `LazyVStack` 让屏幕外的行不建、也不提前发图片请求;
/// 每一行是独立的子视图,只读自己那行的 `Row`,一行数据到了只让这一行重算,`body` 只依赖媒体库列表。
struct HomeView: View {
    let container: AppContainer
    let server: ServerProfile
    /// 打开某一项的详情
    let onOpenItem: (EmbyItem) -> Void
    /// 打开某个媒体库
    let onOpenLibrary: (EmbyView) -> Void
    /// 变化即重新加载(⌘R)
    let refreshToken: Int

    /// 首页是导航栈的根,push 别的页时不会销毁;状态按服务器分开存,切走再切回来不闪 loading
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

    /// hero 还垫在顶栏底下。滚出去之后顶栏下面是货架,栏底要换回窗口底色的压暗
    @State private var isHeroUnderChrome = true

    /// hero 骨架按它算高度。用真实宽度而不是 0:hero 高度是宽度的函数,骨架若按 0 算(夹到下限 300),
    /// 数据到达时 hero 会突然长高,整页内容被往下推。
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        // 只取当前服务器的那份:切服务器后、新一轮 `load` 之前也不会露出别台的内容
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
                HomeHeroSlot(
                    sections: sections,
                    context: context,
                    isUnderChrome: isHeroUnderChrome,
                    viewportWidth: viewportWidth
                )
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        // ⛔ 关掉顶部的系统滚动边缘效果:它会在 hero 顶上盖一条窗口底色的柔边(浅色下是白带)
        .scrollEdgeEffectHidden(true, for: .top)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, scrolled in
            updateHeroUnderChrome(scrolled)
        }
        .navigationTitle("首页")
        // 加载 / 刷新中整页不可点,避免对旧内容做操作
        .allowsHitTesting(!viewModel.isLoading)
        .task(id: "\(server.id.uuidString)-\(refreshToken)") {
            viewModel.load(server: server)
        }
        // 设置窗口在另一个场景里,改完开关这里不会自动重新 `load`,推荐数据得有人去发请求 / 清旧行。
        // ⛔ 不整页 `load`:改的是一个显示开关,不该把媒体库、继续观看、各「最新」全部重来一遍。
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

    /// hero 是否还垫在顶栏底下。
    ///
    /// 阈值两侧各留 `heroChromeHysteresis`:正好停在临界高度时,行高哪怕变一两像素都会把判定翻回去,
    /// 而判定一变顶栏底色就换一套(还连带一次整页求值),看起来是页面在那个位置来回晃。
    private func updateHeroUnderChrome(_ scrolled: CGFloat) {
        let threshold = HomeHero.height(forWidth: viewportWidth) - Metrics.chromeBarHeight
        if isHeroUnderChrome {
            if scrolled > threshold + Self.heroChromeHysteresis { isHeroUnderChrome = false }
        } else if scrolled < threshold - Self.heroChromeHysteresis {
            isHeroUnderChrome = true
        }
    }

    private static let heroChromeHysteresis: CGFloat = 24
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

/// hero 的位置。要读各行状态所以单独成视图,任何一行变化只让它重新求值。
/// 有 hero(含加载骨架)时图铺到窗口最上沿,没有时留一块顶栏高度的空白。
/// 有没有 hero 经 `BrowseChromeController.setRootHasHero` 告诉顶栏(决定栏底压暗方式)。
private struct HomeHeroSlot: View {
    let sections: HomeViewModel.Sections
    let context: HomeRowContext
    let isUnderChrome: Bool
    let viewportWidth: CGFloat

    @Environment(\.openWindow) private var openWindow
    @Environment(\.browseChrome) private var chrome

    var body: some View {
        let pick = HomeViewModel.heroPick(
            recommended: sections.recommended.state,
            views: sections.views.state,
            resume: sections.resume.state,
            latest: { sections.latest[$0.id]?.state ?? .idle },
            // 设置里关掉「首页推荐」时整块不画(⛔ 不走退路,见 `heroPick`)
            recommendationsEnabled: context.container.homeAppearance.showsHeroRecommendations
        )
        Group {
            switch pick {
            case .pending:
                // 与真实 hero 同高(同一个宽度公式),数据到达时不改布局
                SkeletonBlock(cornerRadius: 0)
                    .frame(height: HomeHero.height(forWidth: viewportWidth))
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
                // 换了一批就整块重建(轮播回到第一张)。同一批不重建:行对象被刷新时用户停在第 3 张
                // 不该被弹回第 1 张 —— 所以 id 取的是条目 id 列表,不是行对象。
                .id(items.map(\.id).joined(separator: ","))
            }
        }
        // ⚠️ 监听「服务器 + 有没有 hero」而不是单个布尔:切服务器时这个视图不重建,前后两台都有 hero
        // 布尔就一直是 true、`onChange` 不触发,新服务器的 id 从没登记过,顶栏会退回错的压暗方式。
        .onChange(of: HeroReport(source: context.server.id, hasHero: pick != .none && isUnderChrome), initial: true) { _, report in
            chrome?.setRootHasHero(report.hasHero, source: report.source)
        }
    }
}

/// `HomeHeroSlot` 上报给顶栏的内容
private struct HeroReport: Equatable {
    let source: UUID
    let hasHero: Bool
}

// MARK: - 我的媒体

/// 媒体库入口。这里是唯一的入口,加载态与失败态都要露出来:失败时少一行而不报错,等于骗用户「没有媒体库」。
private struct HomeLibrariesRow: View {
    let row: HomeViewModel.Row<[EmbyView]>
    let context: HomeRowContext

    private static let title = "我的媒体"

    var body: some View {
        switch row.state {
        case .idle, .loading:
            // 首屏还没有内容:横版骨架占位,不闪白屏
            SkeletonShelf(
                title: Self.title,
                cardWidth: Metrics.libraryTileWidth,
                aspectRatio: Metrics.landscapeAspectRatio,
                count: 4,
                textHeight: Metrics.libraryTileTextHeight
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
                count: 4,
                textHeight: Metrics.landscapeCardTextHeight
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
        // 标题就是库名,不加「最新 ·」前缀
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

/// 所有可见分区都加载完且都为空时的整页提示。要读所有行状态所以单独成视图:任何一行变化只让它重新求值。
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
                // 重试即整页重新加载:已加载的分区保持原样不闪
                retry: { context.viewModel.load(server: context.server) },
                login: { context.container.state.serverNeedingLogin = context.server }
            )
            .frame(height: Metrics.posterMinWidth)
        }
    }
}

/// 「我的媒体」里的一个媒体库入口:封面 + 名称的横版块(非玻璃)。有 `Primary` 图就用封面,否则退回按类型选的图标。
private struct LibraryTile: View {
    let view: EmbyView
    let serverID: UUID
    let store: PosterImageStore

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            // 尺寸由 Color.clear 钉死,图片只当 overlay:横向 ScrollView 不给高度提议,
            // 直接 .aspectRatio(.fit) 会让高度跟着源图比例走(2:3 封面高出 2.7 倍)
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
