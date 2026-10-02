import SwiftUI

/// 首页(主窗口导航栈的根页)。
///
/// 自上而下:我的媒体 → 继续观看(横版)→ 每个媒体库的「最新」(海报)。
/// 与 Emby Web 一样,**加载成功但为空的分区整行不显示**(不放「没有内容」占位);
/// 失败的分区照常显示错误与重试入口;全部为空时给一个整页空状态。
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
    /// 变化即重新加载(工具栏「刷新」)
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
            LazyVStack(alignment: .leading, spacing: Metrics.spacingXL) {
                HomeLibrariesRow(row: sections.views, context: context)
                HomeResumeRow(row: sections.resume, context: context)
                ForEach(HomeViewModel.latestViews(in: sections.views.state.value ?? [])) { view in
                    HomeLatestRow(view: view, row: sections.latest[view.id], context: context)
                }
                HomeEmptyState(sections: sections)
            }
            .padding(Metrics.spacingXL)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("首页")
        .task(id: "\(server.id.uuidString)-\(refreshToken)") {
            viewModel.load(server: server)
        }
        .onChange(of: container.state.lastFinishedPlayback) { _, finished in
            guard finished?.serverID == server.id else { return }
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
            HomeSectionPlaceholder(title: Self.title)
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
            HomeSectionPlaceholder(title: title)
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
            HomeSectionPlaceholder(title: title)
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

private struct HomeSectionPlaceholder: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text(title)
                .font(.title3.bold())
            HStack(spacing: Metrics.spacingM) {
                ProgressView()
                    .controlSize(.small)
                Text("加载中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Metrics.spacingL)
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

/// 「我的媒体」里的一个媒体库入口:封面 + 名称的横版块(非玻璃,UI_DESIGN.md 4.2)。
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
