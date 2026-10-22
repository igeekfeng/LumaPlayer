import SwiftUI

/// 某个媒体库的页面:海报网格 + 分页。
/// 空态 / 错误态 / 重试齐全;加载更多的失败只在页脚提示,不清空已加载内容。
struct LibraryView: View {
    let container: AppContainer
    let server: ServerProfile
    let view: EmbyView?
    var onOpenItem: (EmbyItem) -> Void
    /// 变化即重新加载(⌘R)
    var refreshToken: Int = 0

    @State private var viewModel: LibraryViewModel
    @Environment(\.openWindow) private var openWindow

    init(
        container: AppContainer,
        server: ServerProfile,
        view: EmbyView?,
        onOpenItem: @escaping (EmbyItem) -> Void,
        refreshToken: Int = 0
    ) {
        self.container = container
        self.server = server
        self.view = view
        self.onOpenItem = onOpenItem
        self.refreshToken = refreshToken
        self._viewModel = State(initialValue: LibraryViewModel(container: container))
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: title, subtitle: countText) {
                pageTools
            }
            pageContent
        }
        // 加载 / 刷新中整页不可点(顶栏下沿的加载线在走),避免对旧内容做操作
        .allowsHitTesting(!viewModel.isLoading)
        .navigationTitle(title)
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { viewModel.userDataError != nil },
                set: { if !$0 { viewModel.userDataError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.userDataError ?? "")
        }
        // 服务器 / 媒体库 / 刷新任一变化都重新配置:刷新只重拉首页,查询变了才重建。
        .task(id: "\(server.id.uuidString)-\(view?.id ?? "")-\(refreshToken)") {
            viewModel.configure(server: server, view: view)
        }
        .reportsPageLoading(viewModel.isLoading, page: .library, to: container.state)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch viewModel.list?.state ?? .idle {
        case .idle, .loading:
            // 首屏还没有内容:灰色骨架占位,不闪白屏(刷新时 state 仍是 .loaded,不会走到这)
            SkeletonGrid()
        case .failed(let failure):
            ErrorStateView(
                failure: failure,
                retry: { viewModel.list?.reload() },
                login: { container.state.serverNeedingLogin = server }
            )
        case .loaded:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if let list = viewModel.list, list.items.isEmpty {
            if viewModel.filter == .all {
                ContentUnavailableView(
                    "这个媒体库是空的",
                    systemImage: "rectangle.stack",
                    description: Text("服务器上没有可显示的项目。")
                )
            } else {
                ContentUnavailableView {
                    Label("没有「\(viewModel.filter.title)」的内容", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("显示全部") { viewModel.filter = .all }
                }
            }
        } else if let list = viewModel.list {
            ScrollView {
                ItemGridView(
                    items: list.items,
                    serverID: server.id,
                    store: container.posters,
                    onOpenItem: onOpenItem,
                    actions: ItemGridActions(
                        play: { item, fromBeginning in play(item, fromBeginning: fromBeginning) },
                        togglePlayed: { viewModel.togglePlayed($0) },
                        toggleFavorite: { viewModel.toggleFavorite($0) },
                        updatingIDs: viewModel.updatingItemIDs
                    )
                )
                loadMoreFooter(list)
            }
        }
    }

    // MARK: - 页内工具:排序 / 筛选

    private var title: String { view?.name ?? "媒体库" }

    /// 排序 / 筛选菜单,放在 `PageHeader` 右侧(无边框按钮,不是玻璃:它们不浮在媒体上)
    @ViewBuilder
    private var pageTools: some View {
        HStack(spacing: Metrics.spacingM) {
            Menu {
                Picker("排序方式", selection: $viewModel.sort) {
                    ForEach(LibrarySort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(.inline)
                Picker("顺序", selection: $viewModel.ascending) {
                    Text("升序").tag(true)
                    Text("降序").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Label("排序:\(viewModel.sort.title)", systemImage: "arrow.up.arrow.down")
            }
            .help("排序:\(viewModel.sort.title)(\(viewModel.ascending ? "升序" : "降序"))")

            Menu {
                Picker("筛选", selection: $viewModel.filter) {
                    ForEach(LibraryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(
                    "筛选:\(viewModel.filter.title)",
                    systemImage: viewModel.filter == .all
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
            .help("筛选:\(viewModel.filter.title)")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }

    /// 「共 42 项」。总数没给就不显示(不填 0,API_CONTRACT.md 8.1)。
    private var countText: String {
        guard let total = viewModel.list?.totalCount else { return "" }
        return viewModel.filter == .all ? "共 \(total) 项" : "\(viewModel.filter.title) · \(total) 项"
    }

    private func play(_ item: EmbyItem, fromBeginning: Bool) {
        container.play(item, on: server, fromBeginning: fromBeginning)
        openWindow(id: PlayerSceneRoot.windowID)
    }

    @ViewBuilder
    private func loadMoreFooter(_ list: PagedItemList) -> some View {
        if list.hasMore {
            HStack(spacing: Metrics.spacingM) {
                if list.isLoadingMore {
                    ProgressView()
                    Text("加载更多…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let failure = list.loadMoreFailure {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(failure.message)
                        .font(.caption)
                    Button("重试") { list.loadMore() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(Metrics.spacingXL)
            .onAppear {
                // 页脚出现即加载下一页;`loadMore()` 内部有并发与「没有更多」保护
                list.loadMore()
            }
        }
    }
}
