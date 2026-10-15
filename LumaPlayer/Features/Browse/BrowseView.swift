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

/// 主窗口:单个 `NavigationStack`,根页随**当前来源**变化
/// (Emby → 首页;百度网盘 → 它的授权/浏览页),媒体库 / 搜索结果 / 详情 push 上来。
///
/// 没有系统工具栏:返回 / 搜索 / 来源 / 刷新画在浮动顶栏上(`BrowseChromeBar.swift`),
/// 页面名称与页内工具在各页自己的 `PageHeader` 里。
/// 来源管理在设置窗口的「来源」标签页,切换在顶栏的来源菜单。
struct BrowseView: View {
    let container: AppContainer

    @State private var path: [BrowseRoute] = []
    @State private var sources: [SourceProfile] = []
    @State private var actionErrorMessage: String?
    /// 手动刷新计数器:变化即触发各页重新加载
    @State private var refreshToken = 0
    /// 工具栏搜索框里正在输入的文字
    @State private var searchText = ""
    /// 搜索提交次数(见 `BrowseRoute.search`)
    @State private var searchSubmission = 0
    /// 顶栏来源菜单里的「管理来源…」——打开设置窗口(⌘,)
    @Environment(\.openSettings) private var openSettings
    /// 浮动顶栏的全屏 / 自动隐藏状态,以及页面登记的返回动作
    @State private var chrome = BrowseChromeController()

    init(container: AppContainer) {
        self.container = container
    }

    var body: some View {
        NavigationStack(path: $path) {
            rootPage
        }
        // 顶栏挂在**导航栈外**,每一页共用一条(DesignTokens.swift「界面规则」)。
        // 详情页是一整页 hero:栏底换成很轻的黑色压暗,不在背景图上盖出一条窗口底色。
        .browseChrome(chrome, scrim: isShowingDetail ? .hero : .page) {
            chromeBar
        }
        // 设置窗口里增 / 改 / 删来源后重读,菜单里的名称跟着变
        .task(id: container.state.serverListRevision) { await reloadSources() }
        .onChange(of: container.state.currentSource?.id) {
            // 栈上的页属于上一个来源,换来源必须清掉(不串台)
            path.removeAll()
            searchText = ""
            Task { await reloadSources() }
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

    /// 导航栈的根:**按当前来源分派**。Emby 是首页,百度网盘是它自己的页。
    @ViewBuilder
    private var rootPage: some View {
        switch container.state.currentSource {
        case .some(.emby(let server)):
            HomeView(
                container: container,
                server: server,
                onOpenItem: openItem,
                onOpenLibrary: { path.append(.library($0)) },
                refreshToken: refreshToken
            )
            .navigationDestination(for: BrowseRoute.self) { route in
                page(for: route, server: server)
            }
        case .some(.baiduPan(let source)):
            // ⛔ 百度来源没有 Emby 那套库 / 搜索 / 详情,所以顶栏不给搜索框;
            // 刷新走 `refreshToken`,由它自己重读授权状态与目录;
            // 「上一层」由它经 `BrowseChromeController.pageBackAction` 登记到顶栏。
            BaiduPanSourceView(container: container, source: source, refreshToken: refreshToken)
        case .none:
            ContentUnavailableView(
                "没有选中的来源",
                systemImage: "rectangle.stack.badge.plus",
                description: Text("先在设置里添加一个 Emby 服务器或百度网盘。")
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

    // MARK: - 顶栏

    /// 顶栏内容:左边返回,右边搜索 / 来源 / 刷新。
    @ViewBuilder
    private var chromeBar: some View {
        HStack(spacing: Metrics.spacingM) {
            if let backAction {
                ChromeBackButton(action: backAction)
            }
            Spacer(minLength: 0)
            if case .emby? = container.state.currentSource {
                ChromeSearchField(text: $searchText, chrome: chrome, onSubmit: submitSearch)
            }
            // 来源切换器不上详情页:详情页属于当前这台服务器,而切换会清掉
            // 整个导航栈(见 `onChange(of: container.state.currentSource?.id)`),
            // 在一页详情上切来源没有意义。
            if !isShowingDetail {
                sourceMenu
            }
            // 加载 / 刷新中图标转圈并禁用;状态由当前内容页经 `AppState.isPageLoading` 上报
            RefreshToolbarButton(isLoading: container.state.isPageLoading) {
                refresh()
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
    }

    private var sourceMenu: some View {
        Menu {
            // inline Picker:系统在当前来源那一项前画原生勾选标记
            Picker("来源", selection: currentSourceSelection) {
                ForEach(sources) { source in
                    Text("\(source.displayName) · \(source.kindDescription)")
                        .tag(Optional(source.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            // 来源管理(增 / 改 / 删 / 登录)在设置窗口的「来源」标签页
            Button {
                openSettings()
            } label: {
                Label("管理来源…", systemImage: "gearshape")
            }
        } label: {
            Label(currentSourceName, systemImage: currentSourceSymbol)
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .fixedSize()
        .help("来源:\(currentSourceName)。切换来源;「管理来源…」在设置窗口(⌘,)")
        .accessibilityLabel("来源:\(currentSourceName)")
    }

    /// 返回:导航栈不空时弹栈;栈空时用页面自己登记的返回(百度目录的上一层);都没有就不显示。
    private var backAction: (@MainActor () -> Void)? {
        if !path.isEmpty {
            return { path.removeLast() }
        }
        return chrome.pageBackAction
    }

    /// 搜索提交:结果页直接叠在首页上(替换掉栈上原有的页):从详情页里搜索也不会被压在下面,
    /// 返回一次就回到首页
    private func submitSearch() {
        searchSubmission += 1
        path = [.search(term: searchText, submission: searchSubmission)]
    }

    // MARK: - 动作

    private func openItem(_ item: EmbyItem) {
        path.append(.detail(DetailItem(item: item)))
    }

    private func switchTo(_ source: SourceProfile) async {
        do {
            try await container.switchCurrent(to: source)
            await reloadSources()
        } catch {
            actionErrorMessage = "切换来源失败,请重试。"
        }
    }

    private func refresh() {
        Task {
            // Emby 来源:刷新 = 用户要最新数据,先作废接口缓存,
            // 否则 TTL 内的缓存命中会让刷新看起来「没反应」
            if case .emby(let server)? = container.state.currentSource {
                await container.invalidateResponses(for: server)
            }
            // 各页的 ViewModel 由各页自己持有,用 refreshToken 触发它们的
            // `.task(id:)` 重新加载,而不是把内部结构暴露到这里。
            refreshToken += 1
        }
    }

    private func reloadSources() async {
        sources = await container.sources()
    }

    // MARK: - 辅助

    private var isShowingDetail: Bool {
        if case .detail = path.last { return true }
        return false
    }

    /// 来源菜单里 Picker 的选中值:读当前来源,选中别的即切换
    private var currentSourceSelection: Binding<UUID?> {
        Binding(
            get: { container.state.currentSource?.id },
            set: { id in
                guard let source = sources.first(where: { $0.id == id }) else { return }
                Task { await switchTo(source) }
            }
        )
    }

    private var currentSourceName: String {
        container.state.currentSource?.displayName ?? "未选择来源"
    }

    private var currentSourceSymbol: String {
        switch container.state.currentSource {
        case .some(.emby): return "server.rack"
        case .some(.baiduPan): return "cloud.fill"
        case .none: return "rectangle.stack.badge.plus"
        }
    }
}
