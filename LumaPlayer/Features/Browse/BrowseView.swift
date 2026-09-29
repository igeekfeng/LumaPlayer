import SwiftUI

/// 侧边栏的选择项。
enum BrowseSelection: Hashable {
    case home
    case search
    /// 某个媒体库(`/Users/{UserId}/Views` 返回的 View 的 Id)
    case library(String)
}

/// 主窗口:`NavigationSplitView` 三栏 —— 侧边栏 / 内容 / 详情
/// (UI_DESIGN.md 第 3 节)。
struct BrowseView: View {
    let container: AppContainer

    @State private var viewModel: BrowseViewModel
    @State private var selection: BrowseSelection = .home
    @State private var selectedItem: EmbyItem?
    /// 首页 / 详情页的 ViewModel 放在这里而不是各自的 View 里:
    /// 切走再切回时视图会重建,ViewModel 留着才能保住已有内容、不闪 loading。
    /// 首页与侧边栏的状态按服务器分开存,切到别的服务器再切回来同样不闪(issue #3)
    @State private var homeViewModel: HomeViewModel
    @State private var detailViewModel: MediaDetailViewModel
    /// 从首页「查看全部」进入的媒体库 Id;有值且仍停在该库时,工具栏出现「返回首页」
    @State private var libraryOpenedFromHome: String?
    @State private var servers: [ServerProfile] = []
    @State private var actionErrorMessage: String?
    /// 手动刷新计数器:变化即触发子页面重新加载
    @State private var refreshToken = 0
    /// 工具栏搜索框里正在输入的文字
    @State private var searchText = ""
    /// 已提交(按了回车)的关键词与提交次数
    @State private var submittedSearch = ""
    @State private var searchSubmission = 0

    init(container: AppContainer) {
        self.container = container
        self._viewModel = State(initialValue: BrowseViewModel(container: container))
        self._homeViewModel = State(initialValue: HomeViewModel(container: container))
        self._detailViewModel = State(initialValue: MediaDetailViewModel(container: container))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
        .toolbar { toolbarContent }
        // 系统搜索框放在工具栏(macOS 原生位置)。提交式:回车才搜,
        // 不随输入逐字请求(服务器低频纪律,见 SearchViewModel)。
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索电影与剧集")
        .onSubmit(of: .search) {
            submittedSearch = searchText
            searchSubmission += 1
            selection = .search
        }
        .task { await reloadServers() }
        .onChange(of: container.state.currentServer?.id) {
            // 选中的项属于上一台服务器,换服务器必须清掉(不串台)
            selectedItem = nil
            selection = .home
            libraryOpenedFromHome = nil
            searchText = ""
            submittedSearch = ""
            Task { await reloadServers() }
        }
        // 列表/详情里的 401 会标出「需要重新登录的服务器」;这里给登录面板,
        // 否则「重新登录」按钮点了没反应。
        .sheet(item: Binding(
            get: { container.state.serverNeedingLogin },
            set: { if $0 == nil { container.state.serverNeedingLogin = nil } }
        )) { server in
            LoginView(container: container, server: server)
        }
        .onChange(of: container.state.serverNeedingLogin?.id) { _, newValue in
            // 重新登录成功(标记被清掉)→ 刷新当前页面,否则还停在失败态
            if newValue == nil { refreshToken += 1 }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        List(selection: $selection) {
            Label("首页", systemImage: "house")
                .tag(BrowseSelection.home)
            Section(currentServerName) {
                switch viewsState {
                case .idle, .loading:
                    HStack(spacing: Metrics.spacingM) {
                        ProgressView()
                        Text("正在加载媒体库…")
                            .font(.caption)
                    }
                case .failed(let failure):
                    VStack(alignment: .leading, spacing: Metrics.spacingS) {
                        Text(failure.message)
                            .font(.caption)
                        Button("重试") {
                            if let server = container.state.currentServer {
                                viewModel.loadViews(server: server)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                case .loaded(let views):
                    if views.isEmpty {
                        Text("这台服务器没有媒体库入口。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(views) { view in
                            Label(view.name ?? "未命名媒体库", systemImage: view.symbolName)
                                .tag(BrowseSelection.library(view.id))
                        }
                    }
                }
            }
            Section("服务器") {
                ForEach(servers) { server in
                    Button {
                        Task { await switchTo(server) }
                    } label: {
                        HStack {
                            Label(server.displayName, systemImage: "server.rack")
                            Spacer()
                            if container.state.currentServer?.id == server.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    container.state.route = .serverList
                } label: {
                    Label("管理服务器…", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(currentServerName)
        .task(id: container.state.currentServer?.id) {
            if let server = container.state.currentServer {
                viewModel.loadViews(server: server)
            }
        }
    }

    // MARK: - 内容列与详情列

    @ViewBuilder
    private var contentColumn: some View {
        if let server = container.state.currentServer {
            switch selection {
            case .home:
                HomeView(
                    container: container,
                    viewModel: homeViewModel,
                    server: server,
                    views: settledViews,
                    selection: $selectedItem,
                    refreshToken: refreshToken,
                    onOpenLibrary: {
                        libraryOpenedFromHome = $0
                        selection = .library($0)
                    }
                )
            case .search:
                SearchView(
                    container: container,
                    server: server,
                    term: submittedSearch,
                    submission: searchSubmission,
                    selection: $selectedItem
                )
            case .library(let viewID):
                if let view = libraryView(id: viewID) {
                    LibraryView(
                        container: container,
                        server: server,
                        view: view,
                        selection: $selectedItem,
                        refreshToken: refreshToken
                    )
                } else {
                    ContentUnavailableView(
                        "媒体库已不可用",
                        systemImage: "questionmark.folder",
                        description: Text("这台服务器上找不到该媒体库,请返回首页重新选择。")
                    )
                }
            }
        } else {
            ContentUnavailableView(
                "没有选中的服务器",
                systemImage: "server.rack",
                description: Text("先添加并选中一台 Emby 服务器。")
            )
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let server = container.state.currentServer, let selectedItem {
            // 剧集里的分集不再换掉整个详情页(单页合并),
            // 所以这里只需要把选中的项目交给详情列。
            MediaDetailView(
                container: container,
                viewModel: detailViewModel,
                server: server,
                item: selectedItem,
                onOpenItem: { self.selectedItem = $0 }
            )
        } else {
            ContentUnavailableView(
                "未选择内容",
                systemImage: "film",
                description: Text("在左侧选一个项目查看详情。")
            )
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 「查看全部」进来的媒体库:侧边栏收起或没注意到时也有明确的返回入口
        if case .library(let id) = selection, id == libraryOpenedFromHome {
            ToolbarItem(placement: .navigation) {
                Button {
                    libraryOpenedFromHome = nil
                    selection = .home
                } label: {
                    Label("返回首页", systemImage: "chevron.backward")
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("返回首页(⌘[)")
            }
        }
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(servers) { server in
                    Button {
                        Task { await switchTo(server) }
                    } label: {
                        if container.state.currentServer?.id == server.id {
                            Label(server.displayName, systemImage: "checkmark")
                        } else {
                            Text(server.displayName)
                        }
                    }
                }
            } label: {
                Label(currentServerName, systemImage: "server.rack")
            }
            .help("切换服务器")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("刷新当前页面")
        }
    }

    // MARK: - 动作

    private func switchTo(_ server: ServerProfile) async {
        do {
            try await container.switchCurrent(to: server)
            await reloadServers()
        } catch {
            actionErrorMessage = "切换服务器失败,请重试。"
        }
    }

    private func refresh() {
        guard let server = container.state.currentServer else { return }
        // 刷新 = 用户要最新数据:先作废接口缓存再触发各页重载,
        // 否则 TTL 内的缓存命中会让刷新看起来「没反应」
        Task {
            await container.invalidateResponses(for: server)
            // 子页面的 ViewModel 由各页面自己持有,用 refreshToken 触发它们的
            // `.task(id:)` 重新加载,而不是把内部结构暴露到这里。
            refreshToken += 1
            viewModel.loadViews(server: server)
        }
    }

    private func reloadServers() async {
        servers = await container.registry.all()
    }

    // MARK: - 辅助

    /// 当前服务器的媒体库入口(按服务器分开存,切服务器时不会露出别台的列表)
    private var viewsState: LoadState<[EmbyView]> {
        viewModel.viewsState(for: container.state.currentServer?.id)
    }

    private var currentServerName: String {
        container.state.currentServer?.displayName ?? "未选择服务器"
    }

    private func libraryView(id: String) -> EmbyView? {
        guard case .loaded(let views) = viewsState else { return nil }
        return views.first { $0.id == id }
    }

    /// 交给首页的媒体库入口。加载中(`.idle` / `.loading`)为 `nil`,首页据此先不发请求,
    /// 免得列表回来前后各加载一遍;失败时是空数组(首页照常加载,只是少几行「最新」)。
    private var settledViews: [EmbyView]? {
        switch viewsState {
        case .idle, .loading: return nil
        case .loaded(let views): return views
        case .failed: return []
        }
    }
}
