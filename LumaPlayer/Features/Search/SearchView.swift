import SwiftUI

/// 搜索结果页。
///
/// 输入框是主窗口工具栏上的 `.searchable`(macOS 原生位置,⌘F 可达),
/// 本页只负责展示「已提交」的关键词的结果;提交式搜索,结果复用媒体库网格与分页。
struct SearchView: View {
    let container: AppContainer
    let server: ServerProfile
    /// 已提交的关键词(工具栏搜索框里按回车后才变)
    let term: String
    /// 每次提交 +1:同一关键词再按一次回车也要重新搜
    let submission: Int
    @Binding var selection: EmbyItem?

    @State private var viewModel: SearchViewModel
    @Environment(\.openWindow) private var openWindow

    init(
        container: AppContainer,
        server: ServerProfile,
        term: String,
        submission: Int,
        selection: Binding<EmbyItem?>
    ) {
        self.container = container
        self.server = server
        self.term = term
        self.submission = submission
        self._selection = selection
        self._viewModel = State(initialValue: SearchViewModel(container: container))
    }

    var body: some View {
        results
            .navigationTitle(term.isEmpty ? "搜索" : "搜索「\(term)」")
            // 换服务器后旧结果属于别的服务器:按新服务器重搜(不串台)
            .task(id: "\(server.id.uuidString)-\(submission)-\(term)") {
                viewModel.search(term, server: server)
            }
    }

    @ViewBuilder
    private var results: some View {
        if let list = viewModel.list {
            switch list.state {
            case .idle, .loading:
                LoadingStateView(title: "正在搜索…")
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
                            selection: $selection,
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
                description: Text("在窗口右上角的搜索框输入关键词后按回车,在「\(server.displayName)」上搜索。")
            )
        }
    }
}
