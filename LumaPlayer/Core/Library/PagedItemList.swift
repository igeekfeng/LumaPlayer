import Foundation

struct PagedFetchResult: Sendable, Equatable {
    let items: [EmbyItem]
    /// nil = 服务端没给,不能假设还有下一页
    let totalRecordCount: Int?
}

/// 分页列表的加载状态机。`reload()` / `refresh()` 时 generation +1 并取消上一轮,
/// generation 对不上的结果一律丢弃,慢响应不会覆盖新查询的数据。取消不记为失败。
@MainActor
@Observable
final class PagedItemList {
    static let pageSize = 60

    private let fetch: @Sendable (Int, Int) async throws -> PagedFetchResult

    private(set) var items: [EmbyItem] = []
    /// 只表达首次加载;翻页另用 `isLoadingMore` / `loadMoreFailure`,免得翻页失败清空已显示内容。
    private(set) var state: LoadState<[EmbyItem]> = .idle
    private(set) var isLoadingMore = false
    private(set) var loadMoreFailure: LoadFailure?
    /// 手动刷新中;`state` 仍是 `.loaded`,继续显示旧内容。
    private(set) var isRefreshing = false

    private var totalRecordCount: Int?
    /// 只在 `totalRecordCount` 不可信时兜底用
    private var lastPageWasFull = false
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    init(fetch: @escaping @Sendable (Int, Int) async throws -> PagedFetchResult) {
        self.fetch = fetch
    }

    /// 优先信 `TotalRecordCount`;它比已加载条数还小时不可信(带 `SearchTerm` 恒为 0,PITFALLS.md Q24),
    /// 退回「上一页装满就可能还有」,最多多发一次空页请求。
    var hasMore: Bool {
        guard let total = totalRecordCount else { return false }
        if total >= items.count {
            return items.count < total
        }
        return lastPageWasFull
    }

    /// ⛔ 带 `SearchTerm` 时不可信(Q24),搜索页不要显示。
    var totalCount: Int? { totalRecordCount }

    var isLoading: Bool { state.isLoading || isRefreshing }

    /// 写操作成功后就地替换 UserData,不重拉整页。
    func updateUserData(_ userData: EmbyUserData, forItemID itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].userData = userData
        if case .loaded = state { state = .loaded(items) }
    }

    /// 查询条件变了时用:清空已显示内容、切回加载态。
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

    /// 查询条件没变时的手动刷新:保留旧内容只置 `isRefreshing`,成功后整页替换(翻过的页丢掉),失败保留旧内容。
    func refresh() {
        loadTask?.cancel()
        generation += 1
        isLoadingMore = false
        loadMoreFailure = nil
        loadPage(startIndex: 0, mode: .refresh)
    }

    func loadMore() {
        guard hasMore, !isLoadingMore, !state.isLoading, !isRefreshing else { return }
        loadPage(startIndex: items.count, mode: .append)
    }

    // MARK: - 内部

    private enum LoadMode {
        case initial
        case append
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
        // 取消不是错误(API_CONTRACT.md 第 7 节);刷新被取消时清掉标记,免得图标一直转
        if error == .cancelled {
            if mode == .refresh { isRefreshing = false }
            return
        }
        switch mode {
        case .append:
            loadMoreFailure = LoadFailure(error)
        case .refresh:
            // 保留原内容;401 等问题会在下一次正常加载时暴露
            isRefreshing = false
        case .initial:
            state = .failed(LoadFailure(error))
        }
    }
}
