import SwiftUI

/// 主窗口导航栈上的一页(首页是栈根,不在这里)。
private enum BrowseRoute: Hashable {
    /// 某个媒体库(首页「我的媒体」或「最新」的「查看全部」进入)
    case library(EmbyView)
    /// 搜索结果。`submission` 每次回车 +1:同一关键词再按一次回车也要重新搜
    case search(term: String, submission: Int)
    case detail(DetailItem)
}

/// 详情页的路由值。
///
/// `NavigationStack(path:)` 要求元素 `Hashable`,而 `EmbyItem` 只有 `Equatable`
/// (给它补 `Hashable` 要连带 `EmbyPerson` / `EmbyMediaStream` 等一堆模型)。
/// 这里按 Id 判定同一页就够了:同一项不会在栈上出现两次。
private struct DetailItem: Hashable {
    let item: EmbyItem

    static func == (lhs: DetailItem, rhs: DetailItem) -> Bool {
        lhs.item.id == rhs.item.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(item.id)
    }
}

/// 主窗口:单个 `NavigationStack`,首页是根,媒体库 / 搜索结果 / 详情都 push 上来,
/// 返回由系统处理(工具栏返回按钮 / ⌘[)(UI_DESIGN.md 第 3 节)。
///
/// 服务器管理在设置窗口的「服务器」标签页,切换在工具栏的服务器菜单。
struct BrowseView: View {
    let container: AppContainer

    @State private var path: [BrowseRoute] = []
    @State private var servers: [ServerProfile] = []
    @State private var actionErrorMessage: String?
    /// 手动刷新计数器:变化即触发各页重新加载
    @State private var refreshToken = 0
    /// 工具栏搜索框里正在输入的文字
    @State private var searchText = ""
    /// 搜索提交次数(见 `BrowseRoute.search`)
    @State private var searchSubmission = 0
    /// 工具栏服务器菜单里的「管理服务器…」——打开设置窗口(⌘,)
    @Environment(\.openSettings) private var openSettings

    init(container: AppContainer) {
        self.container = container
    }

    var body: some View {
        NavigationStack(path: $path) {
            rootPage
        }
        // 工具栏声明在**导航栈**上(而不是各页上):每一页共用;
        // 服务器切换器不上详情页(见 `toolbarContent`)。搜索框不在这里,见 `searchField`。
        .toolbar { toolbarContent }
        // 详情页是一整页 hero(详情页用 `backgroundExtensionEffect` 把背景图铺到标题栏下面):
        // 标题栏不再铺自己的背景色,否则会在背景图上盖出一条同色栏(UI_DESIGN.md 6.2)。
        .toolbarBackgroundVisibility(isShowingDetail ? .hidden : .automatic, for: .windowToolbar)
        // 设置窗口里增 / 改 / 删服务器后重读,菜单里的名称跟着变
        .task(id: container.state.serverListRevision) { await reloadServers() }
        .onChange(of: container.state.currentServer?.id) {
            // 栈上的页属于上一台服务器,换服务器必须清掉(不串台)
            path.removeAll()
            searchText = ""
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

    // MARK: - 页面

    /// 导航栈的根:首页,以及其余各页的 `navigationDestination`
    @ViewBuilder
    private var rootPage: some View {
        if let server = container.state.currentServer {
            HomeView(
                container: container,
                server: server,
                onOpenItem: openItem,
                onOpenLibrary: { path.append(.library($0)) },
                refreshToken: refreshToken
            )
            .modifier(searchField)
            .navigationDestination(for: BrowseRoute.self) { route in
                page(for: route, server: server)
                    .modifier(searchField)
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
    private func page(for route: BrowseRoute, server: ServerProfile) -> some View {
        switch route {
        case .library(let view):
            LibraryView(
                container: container,
                server: server,
                view: view,
                onOpenItem: openItem,
                refreshToken: refreshToken
            )
        case .search(let term, let submission):
            SearchView(
                container: container,
                server: server,
                term: term,
                submission: submission,
                onOpenItem: openItem
            )
        case .detail(let detail):
            // 点相似推荐再 push 一页,返回栈逐级退
            MediaDetailView(
                container: container,
                server: server,
                item: detail.item,
                onOpenItem: openItem,
                refreshToken: refreshToken
            )
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 服务器切换器不上详情页:详情页属于当前这台服务器,而切换会清掉
        // 整个导航栈(见 `onChange(of: container.state.currentServer?.id)`),
        // 在一页详情上切服务器没有意义。
        if !isShowingDetail {
            ToolbarItem(placement: .navigation) {
                Menu {
                    // inline Picker:系统在当前服务器那一项前画原生勾选标记
                    Picker("服务器", selection: currentServerSelection) {
                        ForEach(servers) { server in
                            Text(server.displayName).tag(Optional(server.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
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
        }
        ToolbarItem(placement: .primaryAction) {
            // 加载 / 刷新中图标转圈并禁用;状态由当前内容页经 `AppState.isPageLoading` 上报
            RefreshToolbarButton(isLoading: container.state.isPageLoading) {
                refresh()
            }
        }
    }

    /// 工具栏搜索框,栈根与每个 push 上来的页都要挂(PITFALLS.md 第 4 节)。
    ///
    /// ⚠️ 不能像 `.toolbar` 那样挂在 `NavigationStack` 外面:macOS 27 上那样挂
    /// 搜索框整个不出现(2026-10-01 从 `NavigationSplitView` 改成 `NavigationStack` 时丢的)。
    private var searchField: ToolbarSearchField {
        ToolbarSearchField(text: $searchText) {
            searchSubmission += 1
            // 结果页直接叠在首页上(替换掉栈上原有的页):从详情页里搜索也不会被压在下面,
            // 返回一次就回到首页
            path = [.search(term: searchText, submission: searchSubmission)]
        }
    }

    // MARK: - 动作

    private func openItem(_ item: EmbyItem) {
        path.append(.detail(DetailItem(item: item)))
    }

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
            // 各页的 ViewModel 由各页自己持有,用 refreshToken 触发它们的
            // `.task(id:)` 重新加载,而不是把内部结构暴露到这里。
            refreshToken += 1
        }
    }

    private func reloadServers() async {
        servers = await container.registry.all()
    }

    // MARK: - 辅助

    private var isShowingDetail: Bool {
        if case .detail = path.last { return true }
        return false
    }

    /// 服务器菜单里 Picker 的选中值:读当前服务器,选中别的服务器即切换
    private var currentServerSelection: Binding<UUID?> {
        Binding(
            get: { container.state.currentServer?.id },
            set: { id in
                guard let server = servers.first(where: { $0.id == id }) else { return }
                Task { await switchTo(server) }
            }
        )
    }

    private var currentServerName: String {
        container.state.currentServer?.displayName ?? "未选择服务器"
    }
}

/// 系统搜索框放在工具栏(macOS 原生位置)。提交式:回车才搜,
/// 不随输入逐字请求(服务器低频纪律,见 SearchViewModel)。
/// 各页共用同一份 `text`,push / 返回时输入框里的字不丢。
private struct ToolbarSearchField: ViewModifier {
    @Binding var text: String
    let onSubmit: () -> Void

    func body(content: Content) -> some View {
        content
            .searchable(text: $text, placement: .toolbar, prompt: "搜索电影与剧集")
            .onSubmit(of: .search, onSubmit)
    }
}
