import Foundation

/// 一次分页查询的结果。
struct PagedFetchResult: Sendable, Equatable {
    let items: [EmbyItem]
    /// 服务端总数;`nil` 表示服务端没给,此时不能假设「还有下一页」。
    let totalRecordCount: Int?
}

/// 分页列表的加载与状态机(@MainActor + @Observable,
/// CLAUDE.md「并发分层」的分层规则)。
///
/// **generation 检查**是本类型的核心(翻页时快速切换服务器
/// 不出现旧服务器内容):
/// 每次 `reload()` 都把 `generation + 1` 并取消上一次请求,
/// 回来时 generation 对不上的结果一律丢弃 —— 慢响应不会覆盖新服务器的数据。
///
/// 请求被取消映射为 `.cancelled`,**不**记为失败(API_CONTRACT.md 第 7 节:
/// 翻页、切服务器时的取消是正常流程)。
@MainActor
@Observable
final class PagedItemList {
    /// 每页条数。不是设计 token(与界面布局无关),故不进 `Metrics`。
    static let pageSize = 60

    private let fetch: @Sendable (Int, Int) async throws -> PagedFetchResult

    private(set) var items: [EmbyItem] = []
    /// 首次加载的状态;加载更多用 `isLoadingMore` / `loadMoreFailure` 单独表达,
    /// 避免「翻页失败」把已经显示出来的内容整片清空。
    private(set) var state: LoadState<[EmbyItem]> = .idle
    private(set) var isLoadingMore = false
    private(set) var loadMoreFailure: LoadFailure?
    /// 手动刷新(保留已显示内容)进行中。与首次加载分开:`state` 仍是 `.loaded`,
    /// 界面继续显示旧内容,工具栏的刷新图标转圈表示在刷新。
    private(set) var isRefreshing = false

    private var totalRecordCount: Int?
    /// 最近一页是否装满 `pageSize`。只在 `totalRecordCount` 不可信时兜底用。
    private var lastPageWasFull = false
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    init(fetch: @escaping @Sendable (Int, Int) async throws -> PagedFetchResult) {
        self.fetch = fetch
    }

    /// 还有没有下一页。
    ///
    /// 优先信 `TotalRecordCount`;但它比已加载条数还小时显然不可信 ——
    /// 带 `SearchTerm` 时 Emby 4.9.5.0 会有结果而总数恒为 0(docs/PITFALLS.md Q24)。
    /// 此时退回「上一页装满了就可能还有」:多发的至多是一次返回空页的请求。
    var hasMore: Bool {
        guard let total = totalRecordCount else { return false }
        if total >= items.count {
            return items.count < total
        }
        return lastPageWasFull
    }

    /// 服务端报的总数(媒体库标题旁的「共 N 部」)。
    /// ⚠️ 带 `SearchTerm` 时不可信(Q24,恒为 0),搜索页不要显示它。
    var totalCount: Int? { totalRecordCount }

    /// 首次加载或刷新进行中(顶栏加载线据此显示)。
    var isLoading: Bool { state.isLoading || isRefreshing }

    /// 标记已看 / 收藏成功后,用服务端返回的 UserData 就地替换这一项,不重拉整页。
    func updateUserData(_ userData: EmbyUserData, forItemID itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].userData = userData
        if case .loaded = state { state = .loaded(items) }
    }

    /// 重新加载第一页,**清空已显示的内容**并切回加载态。查询条件变了(换服务器 /
    /// 换媒体库 / 改排序筛选)时用它 —— 旧内容不属于新查询,不该留在屏幕上。
    /// **会取消**上一轮未完成的请求。
    func reload() {
        loadTask?.cancel()
        generation += 1
        items = []
        totalRecordCount = nil
        lastPageWasFull = false
        isLoadingMore = false
        loadMoreFailure = nil
        isRefreshing = false
        loadPage(startIndex: 0, mode: .initial)
    }

    /// 手动刷新:重新拉第一页,但**保留已显示的内容**。
    ///
    /// 与 `reload()` 的区别是查询条件没变,旧内容仍然有效 —— 只是用户按了「刷新」要
    /// 最新数据。因此不切回 `.loading`、不清空 `items`,只置 `isRefreshing`
    /// (顶栏加载线据此显示);新结果回来后整页替换,失败则保留旧内容
    /// (与首页 / 详情页的后台刷新同一立场)。翻过的后续页会丢掉,回到第一页。
    func refresh() {
        loadTask?.cancel()
        generation += 1
        isLoadingMore = false
        loadMoreFailure = nil
        loadPage(startIndex: 0, mode: .refresh)
    }

    /// 加载下一页。没有更多 / 正在加载 / 正在刷新时不重复发请求。
    func loadMore() {
        guard hasMore, !isLoadingMore, !state.isLoading, !isRefreshing else { return }
        loadPage(startIndex: items.count, mode: .append)
    }

    // MARK: - 内部

    /// 一次请求的意图:决定进入哪个加载态、结果怎么落地。
    private enum LoadMode {
        /// 首次加载 / 查询变化:清空并切回 `.loading`
        case initial
        /// 加载下一页:追加
        case append
        /// 手动刷新:保留内容,只置 `isRefreshing`
        case refresh
    }

    private func loadPage(startIndex: Int, mode: LoadMode) {
        let myGeneration = generation
        switch mode {
        case .append:
            isLoadingMore = true
            loadMoreFailure = nil
        case .initial:
            state = .loading
        case .refresh:
            isRefreshing = true
        }
        loadTask = Task {
            do {
                let page = try await fetch(startIndex, Self.pageSize)
                apply(page, generation: myGeneration, mode: mode)
            } catch let error as EmbyAPIError {
                handle(error, generation: myGeneration, mode: mode)
            } catch {
                handle(.transport(.unknown), generation: myGeneration, mode: mode)
            }
        }
    }

    private func apply(_ page: PagedFetchResult, generation: Int, mode: LoadMode) {
        guard generation == self.generation else { return }
        switch mode {
        case .append:
            items.append(contentsOf: page.items)
        case .initial, .refresh:
            items = page.items
        }
        totalRecordCount = page.totalRecordCount
        lastPageWasFull = page.items.count >= Self.pageSize
        isLoadingMore = false
        isRefreshing = false
        loadMoreFailure = nil
        state = .loaded(items)
    }

    private func handle(_ error: EmbyAPIError, generation: Int, mode: LoadMode) {
        guard generation == self.generation else { return }
        isLoadingMore = false
        // 取消不是错误:静默丢弃,保留当前状态(API_CONTRACT.md 第 7 节)。
        // 刷新被取消时清掉标记,免得刷新图标一直转;新的一轮加载会重新决定状态。
        if error == .cancelled {
            if mode == .refresh { isRefreshing = false }
            return
        }
        switch mode {
        case .append:
            loadMoreFailure = LoadFailure(error)
        case .refresh:
            // 刷新失败保留原内容(与首页 / 详情页的后台刷新同一立场):旧内容仍可用,
            // 401 等问题会在用户下一次操作时由正常加载路径暴露。
            isRefreshing = false
        case .initial:
            state = .failed(LoadFailure(error))
        }
    }
}
