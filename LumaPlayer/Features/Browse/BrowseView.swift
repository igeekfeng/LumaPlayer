import SwiftUI

/// 内容页的选择项。
enum BrowseSelection: Hashable {
    case home
    case search
    /// 某个媒体库(`/Users/{UserId}/Views` 返回的 View 的 Id)
    case library(String)
}

/// 导航栈上的一页详情。
///
/// `NavigationStack(path:)` 要求元素 `Hashable`,而 `EmbyItem` 只有 `Equatable`
/// (给它补 `Hashable` 要连带 `EmbyPerson` / `EmbyMediaStream` 等一堆模型)。
/// 这里按 Id 判定同一页就够了:同一项不会在栈上出现两次。
private struct DetailRoute: Hashable {
    let item: EmbyItem

    static func == (lhs: DetailRoute, rhs: DetailRoute) -> Bool {
        lhs.item.id == rhs.item.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(item.id)
    }
}

/// 主窗口:`NavigationStack` —— 内容(首页 / 媒体库 / 搜索)占满整窗,
/// 点项目 push 到详情页(UI_DESIGN.md 第 3 节)。
///
/// 2026-10-01 改版:原先的第三栏(左栏)已去掉 —— 媒体库入口在首页「我的媒体」,
/// 服务器管理在设置窗口的「服务器」标签页,切换在工具栏的服务器菜单。
/// 2026-10-01 再改:详情页不再占右边的第二栏 —— 440 的列宽装不下 hero、剧集列表与
/// 演职员,改成 push 一整页,内容页也拿回全部宽度。
struct BrowseView: View {
    let container: AppContainer

    @State private var viewModel: BrowseViewModel
    @State private var selection: BrowseSelection = .home
    /// 导航栈上已 push 的详情页(点相似推荐会再叠一页,返回栈逐级退)
    @State private var detailPath: [DetailRoute] = []
    /// 首页的 ViewModel 放在这里而不是在 `HomeView` 里:
    /// 切到媒体库 / 搜索再切回时视图会重建,ViewModel 留着才能保住已有内容、不闪 loading。
    /// 首页与媒体库入口的状态按服务器分开存,切到别的服务器再切回来同样不闪(issue #3)
    @State private var homeViewModel: HomeViewModel
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
    /// 工具栏服务器菜单里的「管理服务器…」——打开设置窗口(⌘,)
    @Environment(\.openSettings) private var openSettings

    init(container: AppContainer) {
        self.container = container
        self._viewModel = State(initialValue: BrowseViewModel(container: container))
        self._homeViewModel = State(initialValue: HomeViewModel(container: container))
    }

    var body: some View {
        NavigationStack(path: $detailPath) {
            rootPage
        }
        // 工具栏与搜索框声明在**导航栈**上(而不是内容页上):栈内所有页面都能用到
        // 切服务器 / 刷新 / 搜索;声明在内容页上,push 到详情后就只剩返回按钮了。
        .toolbar { toolbarContent }
        // 系统搜索框放在工具栏(macOS 原生位置)。提交式:回车才搜,
        // 不随输入逐字请求(服务器低频纪律,见 SearchViewModel)。
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索电影与剧集")
        .onSubmit(of: .search) {
            submittedSearch = searchText
            searchSubmission += 1
            // 从详情页里搜索:先退回内容页,否则结果页被压在详情页下面看不见
            detailPath.removeAll()
            selection = .search
        }
        .task { await reloadServers() }
        // 媒体库入口由主窗口统一加载(首页「我的媒体」与媒体库页都用这一份)
        .task(id: container.state.currentServer?.id) {
            if let server = container.state.currentServer {
                viewModel.loadViews(server: server)
            }
        }
        .onChange(of: container.state.currentServer?.id) {
            // 栈上的详情页属于上一台服务器,换服务器必须清掉(不串台)
            detailPath.removeAll()
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

    // MARK: - 内容页与详情页

    /// 导航栈的根:内容页,以及详情页的 `navigationDestination`
    @ViewBuilder
    private var rootPage: some View {
        if let server = container.state.currentServer {
            contentPage(server: server)
                // 详情页在这里注册:同一个导航栈里,内容页与详情页各占一整页。
                // 点相似推荐再 append 一项即可叠上下一页。
                .navigationDestination(for: DetailRoute.self) { route in
                    MediaDetailView(
                        container: container,
                        server: server,
                        item: route.item,
                        onOpenItem: { detailPath.append(DetailRoute(item: $0)) }
                    )
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
    private func contentPage(server: ServerProfile) -> some View {
        switch selection {
        case .home:
            HomeView(
                container: container,
                viewModel: homeViewModel,
                server: server,
                viewsState: viewsState,
                onOpenItem: { detailPath.append(DetailRoute(item: $0)) },
                refreshToken: refreshToken,
                onOpenLibrary: {
                    libraryOpenedFromHome = $0
                    selection = .library($0)
                },
                onReloadLibraries: { viewModel.loadViews(server: server) }
            )
        case .search:
            SearchView(
                container: container,
                server: server,
                term: submittedSearch,
                submission: searchSubmission,
                onOpenItem: { detailPath.append(DetailRoute(item: $0)) }
            )
        case .library(let viewID):
            if let view = libraryView(id: viewID) {
                LibraryView(
                    container: container,
                    server: server,
                    view: view,
                    onOpenItem: { detailPath.append(DetailRoute(item: $0)) },
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
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 「查看全部」进来的媒体库:给一个明确的返回首页入口(⌘[)
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
                Divider()
                // 服务器管理(增 / 改 / 删 / 登录)在设置窗口的「服务器」标签页
                Button {
                    openSettings()
                } label: {
                    Label("管理服务器…", systemImage: "gearshape")
                }
            } label: {
                Label(currentServerName, systemImage: "server.rack")
            }
            .help("切换服务器;「管理服务器…」在设置窗口(⌘,)")
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
}
