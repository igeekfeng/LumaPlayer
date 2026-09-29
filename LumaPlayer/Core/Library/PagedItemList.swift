import Foundation

/// 一次分页查询的结果。
struct PagedFetchResult: Sendable, Equatable {
    let items: [EmbyItem]
    /// 服务端总数;`nil` 表示服务端没给,此时不能假设「还有下一页」。
    let totalRecordCount: Int?
}

/// 分页列表的加载与状态机(@MainActor + @Observable,
/// ARCHITECTURE.md 3.1.2 的分层规则)。
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

    /// 标记已看 / 收藏成功后,用服务端返回的 UserData 就地替换这一项,不重拉整页。
    func updateUserData(_ userData: EmbyUserData, forItemID itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].userData = userData
        if case .loaded = state { state = .loaded(items) }
    }

    /// 重新加载第一页。**会取消**上一轮未完成的请求。
    func reload() {
        loadTask?.cancel()
        generation += 1
        items = []
        totalRecordCount = nil
        lastPageWasFull = false
        isLoadingMore = false
        loadMoreFailure = nil
        loadPage(startIndex: 0, appending: false)
    }

    /// 加载下一页。没有更多 / 正在加载时不重复发请求。
    func loadMore() {
        guard hasMore, !isLoadingMore, !state.isLoading else { return }
        loadPage(startIndex: items.count, appending: true)
    }

    // MARK: - 内部

    private func loadPage(startIndex: Int, appending: Bool) {
        let myGeneration = generation
        if appending {
            isLoadingMore = true
            loadMoreFailure = nil
        } else {
            state = .loading
        }
        loadTask = Task {
            do {
                let page = try await fetch(startIndex, Self.pageSize)
                apply(page, generation: myGeneration, appending: appending)
            } catch let error as EmbyAPIError {
                handle(error, generation: myGeneration, appending: appending)
            } catch {
                handle(.transport(.unknown), generation: myGeneration, appending: appending)
            }
        }
    }

    private func apply(_ page: PagedFetchResult, generation: Int, appending: Bool) {
        guard generation == self.generation else { return }
        if appending {
            items.append(contentsOf: page.items)
        } else {
            items = page.items
        }
        totalRecordCount = page.totalRecordCount
        lastPageWasFull = page.items.count >= Self.pageSize
        isLoadingMore = false
        loadMoreFailure = nil
        state = .loaded(items)
    }

    private func handle(_ error: EmbyAPIError, generation: Int, appending: Bool) {
        guard generation == self.generation else { return }
        isLoadingMore = false
        // 取消不是错误:静默丢弃,保留当前状态(API_CONTRACT.md 第 7 节)
        if error == .cancelled { return }
        if appending {
            loadMoreFailure = LoadFailure(error)
        } else {
            state = .failed(LoadFailure(error))
        }
    }
}
