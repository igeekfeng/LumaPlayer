import SwiftUI

/// 首页(主窗口内容列的默认页)。
///
/// 自上而下:我的媒体 → 继续观看(横版)→ 下一集(横版)→ 每个媒体库的「最新」(海报)。
/// 与 Emby Web 一样,**加载成功但为空的分区整行不显示**(不放「没有内容」占位);
/// 失败的分区照常显示错误与重试入口;全部为空时给一个整页空状态。
///
/// 「我的媒体」是媒体库的唯一入口(主窗口左栏已去掉),所以它的加载态与失败态
/// 必须露出来 —— 失败时静默少一行,用户只会以为这台服务器没有媒体库。
struct HomeView: View {
    let container: AppContainer
    let server: ServerProfile
    /// 当前服务器的媒体库入口状态(主窗口已加载的那份,不重复请求)。
    /// `.idle` / `.loading` 时首页**先不发请求**,见 `HomeViewModel.loadKey`
    let viewsState: LoadState<[EmbyView]>
    /// 打开某一项的详情(主窗口 push 详情页)
    var onOpenItem: (EmbyItem) -> Void
    /// 变化即重新加载(工具栏「刷新」)
    var refreshToken: Int = 0
    var onOpenLibrary: (String) -> Void = { _ in }
    /// 重新加载媒体库入口(「我的媒体」失败时的重试入口)
    var onReloadLibraries: () -> Void = {}

    @State private var viewModel: HomeViewModel
    @Environment(\.openWindow) private var openWindow

    /// - Parameter viewModel: 由主窗口持有,切到媒体库 / 别的服务器再回来时首页内容不丢,
    ///   重新进入就不会先回退到 loading
    init(
        container: AppContainer,
        viewModel: HomeViewModel,
        server: ServerProfile,
        viewsState: LoadState<[EmbyView]>,
        onOpenItem: @escaping (EmbyItem) -> Void,
        refreshToken: Int = 0,
        onOpenLibrary: @escaping (String) -> Void = { _ in },
        onReloadLibraries: @escaping () -> Void = {}
    ) {
        self.container = container
        self.server = server
        self.viewsState = viewsState
        self.onOpenItem = onOpenItem
        self.refreshToken = refreshToken
        self.onOpenLibrary = onOpenLibrary
        self.onReloadLibraries = onReloadLibraries
        self._viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacingXL) {
                librariesSection
                landscapeSection(title: "继续观看", state: sections.resume, isResume: true)
                if HomeViewModel.showsNextUpRow(sections.nextUp) {
                    landscapeSection(title: "下一集", state: nextUpState)
                }
                ForEach(HomeViewModel.latestViews(in: settledViews ?? [])) { view in
                    latestSection(view)
                }
                if isEverythingEmpty {
                    ContentUnavailableView(
                        "这台服务器上还没有可看的内容",
                        systemImage: "film.stack",
                        description: Text("媒体库里添加了影片或剧集后,会出现在这里。")
                    )
                    .padding(.top, Metrics.spacingXL)
                }
            }
            .padding(Metrics.spacingXL)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("首页")
        .task(id: loadKey) {
            guard let settledViews else { return }
            viewModel.load(server: server, views: settledViews)
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

    private var loadKey: String {
        HomeViewModel.loadKey(serverID: server.id, refreshToken: refreshToken, views: settledViews)
    }

    /// 已有媒体库列表(加载中 / 失败时为 `nil`):首页据此先不发「最新」的请求,
    /// 免得列表回来前后各加载一遍;失败时首页照常加载,只是少几行「最新」。
    private var settledViews: [EmbyView]? {
        switch viewsState {
        case .idle, .loading: return nil
        case .loaded(let views): return views
        case .failed: return []
        }
    }

    /// 只取当前服务器的那份:切服务器后、新一轮 `load` 之前,也不会露出别台的内容
    private var sections: HomeViewModel.Sections {
        viewModel.sections(for: server.id)
    }

    /// 「下一集」里去掉已经出现在「继续观看」里的集:看到一半的集两个接口都会返回,
    /// 同一集在相邻两行各出现一次只是噪音。
    private var nextUpState: LoadState<[EmbyItem]> {
        let sections = sections
        guard case .loaded(let next) = sections.nextUp,
              case .loaded(let resume) = sections.resume else { return sections.nextUp }
        let resumeIDs = Set(resume.map(\.id))
        return .loaded(next.filter { !resumeIDs.contains($0.id) })
    }

    private var isEverythingEmpty: Bool {
        let sections = sections
        return HomeViewModel.isEverythingEmpty(
            resume: sections.resume,
            nextUp: sections.nextUp,
            latest: Array(sections.latest.values)
        )
    }

    // MARK: - 我的媒体

    /// 媒体库入口。这里是**唯一**的媒体库入口(主窗口左栏已去掉),
    /// 加载态与失败态都要露出来:失败时少一行而不报错,等于骗用户「这台服务器没有媒体库」。
    @ViewBuilder
    private var librariesSection: some View {
        switch viewsState {
        case .idle, .loading:
            sectionPlaceholder(title: "我的媒体")
        case .failed(let failure):
            sectionError(title: "我的媒体", failure: failure, retry: onReloadLibraries)
        case .loaded(let views):
            if views.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.spacingS) {
                    Text("我的媒体")
                        .font(.title3.bold())
                    Text("这台服务器没有媒体库入口。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                librariesShelf(views)
            }
        }
    }

    private func librariesShelf(_ views: [EmbyView]) -> some View {
        MediaShelf(title: "我的媒体") {
            ForEach(views) { view in
                Button {
                    onOpenLibrary(view.id)
                } label: {
                    LibraryTile(view: view, serverID: server.id, store: container.posters)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 横版分区(继续观看 / 下一集)

    /// - Parameter isResume: 只有「继续观看」有「移出继续观看」(API_CONTRACT.md 5.7)——
    ///   隐藏态是服务端的 per-item 状态,「下一集」里的条目本来就不在继续观看里。
    @ViewBuilder
    private func landscapeSection(title: String, state: LoadState<[EmbyItem]>, isResume: Bool = false) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading:
            sectionPlaceholder(title: title)
        case .failed(let failure):
            sectionError(title: title, failure: failure)
        case .loaded(let items):
            if !items.isEmpty {
                MediaShelf(title: title) {
                    ForEach(items) { item in
                        LandscapeCard(
                            item: item,
                            serverID: server.id,
                            store: container.posters,
                            onPlay: { play(item) }
                        )
                        .onTapGesture { onOpenItem(item) }
                        .contextMenu { itemMenu(item, canHideFromResume: isResume) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onOpenItem(item) }
                        .accessibilityAction(named: "播放") { play(item) }
                    }
                }
            }
        }
    }

    // MARK: - 最新

    @ViewBuilder
    private func latestSection(_ view: EmbyView) -> some View {
        let title = "最新 · \(view.name ?? "媒体库")"
        switch sections.latest[view.id] ?? .idle {
        case .idle:
            EmptyView()
        case .loading:
            sectionPlaceholder(title: title)
        case .failed(let failure):
            sectionError(title: title, failure: failure)
        case .loaded(let items):
            if !items.isEmpty {
                MediaShelf(title: title, seeAll: { onOpenLibrary(view.id) }) {
                    ForEach(items) { item in
                        Button {
                            onOpenItem(item)
                        } label: {
                            MediaCard(item: item, serverID: server.id, store: container.posters)
                                .frame(width: Metrics.posterMinWidth)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { itemMenu(item) }
                    }
                }
            }
        }
    }

    // MARK: - 共用

    @ViewBuilder
    private func itemMenu(_ item: EmbyItem, canHideFromResume: Bool = false) -> some View {
        if item.kind == .movie || item.kind == .episode {
            Button(item.progressFraction == nil ? "播放" : "继续播放", systemImage: "play.fill") {
                play(item)
            }
            if item.progressFraction != nil {
                Button("从头播放", systemImage: "arrow.counterclockwise") {
                    play(item, fromBeginning: true)
                }
            }
            Divider()
        }
        Button("显示详情", systemImage: "info.circle") {
            onOpenItem(item)
        }
        if canHideFromResume {
            Divider()
            Button("移出继续观看", systemImage: "eye.slash") {
                viewModel.hideFromResume(item, server: server)
            }
            .disabled(viewModel.updatingResumeIDs.contains(item.id))
        }
    }

    private func play(_ item: EmbyItem, fromBeginning: Bool = false) {
        container.play(item, on: server, fromBeginning: fromBeginning)
        openWindow(id: PlayerSceneRoot.windowID)
    }

    private func sectionPlaceholder(title: String) -> some View {
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

    private func sectionError(
        title: String,
        failure: LoadFailure,
        retry: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text(title)
                .font(.title3.bold())
            ErrorStateView(
                failure: failure,
                // 「我的媒体」的重试打在媒体库入口上,其余分区重试自己的内容
                retry: retry ?? { viewModel.load(server: server, views: settledViews ?? []) },
                login: { container.state.serverNeedingLogin = server }
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
