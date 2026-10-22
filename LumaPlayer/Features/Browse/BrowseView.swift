import SwiftUI

/// 主窗口导航栈上的一页(首页是栈根,不在这里)。
private enum BrowseRoute: Hashable {
    /// 某个媒体库
    case library(EmbyView)
    /// 搜索结果。`submission` 每次回车 +1:同一关键词再按一次回车也要重新搜
    case search(term: String, submission: Int)
    case detail(DetailItem)
}

/// 详情页的路由值。`EmbyItem` 只有 `Equatable`,按 id 判等就够了:同一项不会在栈上出现两次。
private struct DetailItem: Hashable {
    let item: EmbyItem

    static func == (lhs: DetailItem, rhs: DetailItem) -> Bool {
        lhs.item.id == rhs.item.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(item.id)
    }
}

/// 主窗口:单个 `NavigationStack`,栈根随**当前来源**变化,媒体库 / 搜索 / 详情 push 上来。
///
/// 没有系统工具栏:返回 / 搜索 / 来源画在浮动顶栏(`BrowseChromeBar.swift`),页名在各页 `PageHeader`。
struct BrowseView: View {
    let container: AppContainer

    @State private var path: [BrowseRoute] = []
    @State private var sources: [SourceProfile] = []
    @State private var actionErrorMessage: String?
    /// 手动刷新计数器:变化即触发各页重新加载
    @State private var refreshToken = 0
    @State private var searchText = ""
    /// 搜索提交次数(见 `BrowseRoute.search`)
    @State private var searchSubmission = 0
    /// 「管理来源…」:打开设置窗口(⌘,)
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
        // 顶栏挂在**导航栈外**共用一条;hero 页栏底用轻压暗,不盖窗口底色(DesignTokens.swift「界面规则」)。
        .browseChrome(
            chrome,
            scrim: isOverHero ? .hero : .page,
            // 状态由当前内容页经 `AppState.isPageLoading` 上报
            isLoading: container.state.isPageLoading,
            back: backAction
        ) {
            chromeBar
        }
        // 菜单栏 View → Reload(⌘R)与 Source 菜单(`BrowseCommands`)
        .focusedSceneValue(\.browseActions, BrowseActions(
            isLoading: container.state.isPageLoading,
            reload: refresh,
            sources: sources,
            currentSourceID: container.state.currentSource?.id,
            switchTo: { source in Task { await switchTo(source) } }
        ))
        // 设置窗口增删改来源后重读,菜单名称跟着变
        .task(id: container.state.serverListRevision) { await reloadSources() }
        .onChange(of: container.state.currentSource?.id) {
            // 栈上的页属于上一个来源,换来源必须清掉(不串台)
            path.removeAll()
            searchText = ""
            Task { await reloadSources() }
        }
        // 401 标出的服务器在这里给登录面板,否则「重新登录」点了没反应
        .sheet(item: Binding(
            get: { container.state.serverNeedingLogin },
            set: { if $0 == nil { container.state.serverNeedingLogin = nil } }
        )) { server in
            LoginView(container: container, server: server)
        }
        .onChange(of: container.state.serverNeedingLogin?.id) { _, newValue in
            // 重新登录成功(标记清空)→ 刷新当前页,否则停在失败态
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

    /// 导航栈的根:按当前来源分派。
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
                    // ⛔ 系统返回按钮会让 SwiftUI 建出 NSToolbar:红绿灯被挤进工具栏带、
                    // 全屏冒出实色栏(Q37)。返回放浮动顶栏。
                    .navigationBarBackButtonHidden(true)
            }
        case .some(.baiduPan(let source)):
            // ⛔ 百度来源没有库 / 搜索 / 详情,顶栏不给搜索框;刷新走 `refreshToken`,
            // 「上一层」由它经 `BrowseChromeController.pageBackAction` 登记到顶栏。
            BaiduPanSourceView(container: container, source: source, refreshToken: refreshToken)
                // ⚠️ 按来源 id 重建,别省:`FileSourceViewModel` 在 init 时收下 `source`
                // (片库根 / 隐藏项 / 续播库 / 封面分区全按 `source.id`),而它是 `@State`,
                // 只在视图身份变化时重新初始化。百度 → 百度切换时视图类型与 `refreshToken`
                // 都没变,两个 `.task(id:)` 不重跑,会停在**上一个来源**的目录上。
                .id(source.id)
        case .some(.localFolder(let source)):
            // 与百度同一个浏览页(`FileSourceBrowserView`),没有授权那两屏;按来源 id 重建的理由同上。
            LocalFolderSourceView(container: container, source: source, refreshToken: refreshToken)
                .id(source.id)
        case .none:
            ContentUnavailableView(
                "没有选中的来源",
                systemImage: "rectangle.stack.badge.plus",
                description: Text("先在设置里添加一个 Emby 服务器、百度网盘或本地文件夹。")
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

    /// 顶栏右侧:搜索 / 来源(返回由 `browseChrome(back:)` 定位在红绿灯旁)。
    /// ⛔ 不放刷新按钮:刷新走菜单栏「Reload」(⌘R),加载状态看栏下沿的加载线。
    @ViewBuilder
    private var chromeBar: some View {
        HStack(spacing: Metrics.spacingM) {
            Spacer(minLength: 0)
            if case .emby? = container.state.currentSource {
                ChromeSearchField(text: $searchText, chrome: chrome, onSubmit: submitSearch)
            }
            // 详情页不给来源切换器:切换会清空整个导航栈
            if !isShowingDetail {
                sourceMenu
            }
        }
    }

    private var sourceMenu: some View {
        Menu {
            Picker("来源", selection: currentSourceSelection) {
                ForEach(sources) { source in
                    Text("\(source.displayName) · \(source.kindDescription)")
                        .tag(Optional(source.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
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
        .help("来源:\(currentSourceName)。切换来源(⌘1…⌘9);「管理来源…」在设置窗口(⌘,)")
        .accessibilityLabel("来源:\(currentSourceName)")
    }

    /// 返回:栈不空时弹栈,否则用页面登记的返回(百度目录的上一层);都没有就不显示。
    private var backAction: (@MainActor () -> Void)? {
        if !path.isEmpty {
            return { path.removeLast() }
        }
        return chrome.pageBackAction
    }

    /// 搜索提交:结果页替换整个栈(从详情页搜索也不会被压住),返回一次即回首页
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
            // Emby:刷新前先作废接口缓存,否则 TTL 内的命中会让刷新「没反应」
            if case .emby(let server)? = container.state.currentSource {
                await container.invalidateResponses(for: server)
            }
            // 各页 ViewModel 自己持有,用 refreshToken 触发它们的 `.task(id:)`
            refreshToken += 1
        }
    }

    private func reloadSources() async {
        sources = await container.sources()
    }

    // MARK: - 辅助

    /// 顶栏压在 hero 图上:详情页,或栈空时根页顶部有 hero(Emby 首页 / 百度剧集详情)
    private var isOverHero: Bool {
        if isShowingDetail { return true }
        guard path.isEmpty, let source = container.state.currentSource?.id else { return false }
        return chrome.heroRootSources.contains(source)
    }

    private var isShowingDetail: Bool {
        if case .detail = path.last { return true }
        return false
    }

    /// 来源菜单的选中值:选中别的即切换
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
        case .some(.localFolder): return "folder.fill"
        case .none: return "rectangle.stack.badge.plus"
        }
    }
}
