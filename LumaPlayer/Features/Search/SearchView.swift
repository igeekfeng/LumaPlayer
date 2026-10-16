import SwiftUI

/// 搜索结果页。
///
/// 输入框在主窗口浮动顶栏上(`ChromeSearchField`,⌘F 可达),
/// 本页只负责展示「已提交」的关键词的结果;提交式搜索,结果复用媒体库网格与分页。
struct SearchView: View {
    let container: AppContainer
    let server: ServerProfile
    /// 已提交的关键词(工具栏搜索框里按回车后才变)
    let term: String
    /// 每次提交 +1:同一关键词再按一次回车也要重新搜
    let submission: Int
    /// 打开某一项的详情(主窗口 push 详情页)
    var onOpenItem: (EmbyItem) -> Void

    @State private var viewModel: SearchViewModel
    @Environment(\.openWindow) private var openWindow

    init(
        container: AppContainer,
        server: ServerProfile,
        term: String,
        submission: Int,
        onOpenItem: @escaping (EmbyItem) -> Void
    ) {
        self.container = container
        self.server = server
        self.term = term
        self.submission = submission
        self.onOpenItem = onOpenItem
        self._viewModel = State(initialValue: SearchViewModel(container: container))
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: title)
            results
                // 空态 / 引导页(`ContentUnavailableView`)在 macOS 上不吃满剩余高度:
                // 不撑开的话整页按内容高度排、被窗口垂直居中,顶栏跟着掉到窗口中间
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 加载 / 刷新中整页不可点(顶栏下沿的加载线在走),避免对旧结果做操作
        .allowsHitTesting(!viewModel.isLoading)
        .navigationTitle(title)
        // 换服务器后旧结果属于别的服务器:按新服务器重搜(不串台)
        .task(id: "\(server.id.uuidString)-\(submission)-\(term)") {
            viewModel.search(term, server: server)
        }
        .reportsPageLoading(viewModel.isLoading, page: .search, to: container.state)
    }

    private var title: String { term.isEmpty ? "搜索" : "搜索「\(term)」" }

    @ViewBuilder
    private var results: some View {
        if let list = viewModel.list {
            switch list.state {
            case .idle, .loading:
                // 首屏还没有结果:灰色骨架占位,不闪白屏(重新搜索时 state 仍是 .loaded)
                SkeletonGrid()
            case .failed(let failure):
                ErrorStateView(
                    failure: failure,
                    retry: { viewModel.search(term, server: server) },
                    login: { container.state.serverNeedingLogin = server }
                )
            case .loaded:
                if list.items.isEmpty {
                    ContentUnavailableView(
                        "没有找到匹配的内容",
                        systemImage: "magnifyingglass",
                        description: Text("换个关键词试试。")
                    )
                } else {
                    ScrollView {
                        ItemGridView(
                            items: list.items,
                            serverID: server.id,
                            store: container.posters,
                            onOpenItem: onOpenItem,
                            actions: ItemGridActions(play: { item, fromBeginning in
                                container.play(item, on: server, fromBeginning: fromBeginning)
                                openWindow(id: PlayerSceneRoot.windowID)
                            })
                        )
                        if list.hasMore {
                            Button("加载更多") { list.loadMore() }
                                .padding(Metrics.spacingXL)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "搜索",
                systemImage: "magnifyingglass",
                description: Text("在窗口右上角的搜索框(⌘F)输入关键词后按回车,在「\(server.displayName)」上搜索。")
            )
        }
    }
}
