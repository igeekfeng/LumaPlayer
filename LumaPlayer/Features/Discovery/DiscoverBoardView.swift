import SwiftUI

/// 一组榜单的「查看全部」页:海报网格 + 按需翻页。
///
/// 为什么单独一页:货架是横滑的,一组几十上百条没法在一条横线上看完。
/// 这一页与「看什么」共用同一个 provider,但**独立持有分页状态**(`DiscoverBoardViewModel`),
/// 关掉再进会重新从第一页开始 —— 榜单是会变的,不该跨次缓存。
struct DiscoverBoardView: View {
    let container: AppContainer
    let board: DiscoverBoard
    let provider: any DiscoverProvider
    /// 点卡片上的「找资源」
    var onSearchResource: (String) -> Void

    @State private var viewModel: DiscoverBoardViewModel

    @MainActor
    init(
        container: AppContainer,
        board: DiscoverBoard,
        provider: any DiscoverProvider,
        onSearchResource: @escaping (String) -> Void
    ) {
        self.container = container
        self.board = board
        self.provider = provider
        self.onSearchResource = onSearchResource
        self._viewModel = State(
            initialValue: DiscoverBoardViewModel(board: board, provider: provider))
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Metrics.posterMinWidth), spacing: Metrics.gridSpacing)]
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: board.title, subtitle: "共 \(viewModel.titles.count) 条已加载")
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(board.title)
        .task { await viewModel.appear() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            SkeletonGrid()
        case .failed(let failure):
            ContentUnavailableView {
                Label("加载失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.message)
            } actions: {
                Button("重试") {
                    Task { await viewModel.reload() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .loaded(let titles):
            if titles.isEmpty {
                ContentUnavailableView {
                    Label("这个榜单现在是空的", systemImage: "theatermasks")
                } description: {
                    Text("来源暂时没有返回条目。")
                }
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                ForEach(viewModel.titles) { title in
                    DiscoveryCard(
                        title: title,
                        store: container.posters,
                        onSearch: { onSearchResource(title.searchKeyword) })
                }
            }
            .padding(Metrics.spacingXL)
            // 页脚放在网格**外面**:放进 `LazyVGrid` 的 cell 里时,它一旦被复用 / 布局抖动
            // 就会让 `.task` 反复取消重启,表现成「一直转圈、再也不往下翻」。
            loadMoreFooter
        }
        // 触底兜底:`.task` 依赖视图出现事件,而且会被 LazyVGrid 回收打断(见下面的注释);
        // 滚动位置是硬的,滚到离底一屏以内就翻页。
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
        } action: { _, distanceToBottom in
            guard distanceToBottom < Metrics.spacingXL * 4 else { return }
            Task { await viewModel.loadMore() }
        }
    }

    /// 页脚:还有下一页就显示。⛔ 不在 `.task` 里自动翻页 —— 失败或取消后那个 cell 不会
    /// 重新出现,页面就永远停在「加载更多…」。这里给明确按钮,滚动到附近也照样触发。
    @ViewBuilder
    private var loadMoreFooter: some View {
        if viewModel.hasMore || viewModel.isLoadingMore {
            VStack(spacing: Metrics.spacingS) {
                if let failure = viewModel.loadMoreFailure {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("重试") {
                        Task { await viewModel.loadMore() }
                    }
                    .buttonStyle(.bordered)
                } else if viewModel.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                    Text("加载更多…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("加载更多") {
                        Task { await viewModel.loadMore() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(Metrics.spacingXL)
            // 兜底:页脚真出现在屏幕上时也翻一页。`loadMore()` 内部有并发与「没有更多」保护
            .onAppear {
                guard viewModel.loadMoreFailure == nil else { return }
                Task { await viewModel.loadMore() }
            }
        }
    }
}
