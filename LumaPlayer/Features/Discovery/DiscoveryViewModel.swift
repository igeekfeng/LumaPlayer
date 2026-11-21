import Foundation

/// 「看什么」的数据源:豆瓣榜单(默认) + TMDB 榜单(配了 token 才有)。
///
/// 为什么要这一层:网盘里有什么取决于用户存了什么,「今晚看什么」不能靠翻目录解决。
/// 这一层把各来源的榜单包成**可直接展示 + 可直接拿去搜资源**的形状(`DiscoverTitle`),
/// 并保证**一个来源挂了不影响另一个**。
///
/// 为什么豆瓣在前:TMDB 要用户自己去申请 token,而没配 token 的人打开这一页原本是一块空引导页。
/// 豆瓣不需要凭据,能直接出内容;TMDB 保留成「配了就更准」的第二档,刮削也仍然只走 TMDB。
@MainActor
@Observable
final class DiscoveryViewModel {
    private let providers: [any DiscoverProvider]

    /// 榜单清单(顺序 = 展示顺序),来自各 provider 的静态声明。
    private(set) var boards: [DiscoverBoard] = []

    /// 每组的状态。`LoadState` 只装一种值,这里按组各存一份。
    private(set) var states: [String: LoadState<[DiscoverTitle]>] = [:]

    /// 每组还有没有下一页。货架上的「查看全部」与详情页的翻页都看它。
    private(set) var hasMore: [String: Bool] = [:]

    /// 这一轮**用不了**的来源及原因(token 没配 / 接口不可用)。⛔ 不让它们以「空榜单」出现。
    private(set) var unavailable: [DiscoverUnavailable] = []

    /// 上一次加载失败的原因(取第一个失败的组)
    private(set) var lastFailure: String?

    /// 是否已经跑过一轮。首次进入前为 false:视图据此显示转圈,⛔ 不闪一下「暂时没有榜单」。
    private(set) var hasLoaded = false

    init(providers: [any DiscoverProvider]) {
        self.providers = providers
    }

    var isLoading: Bool {
        states.values.contains { $0.isLoading }
    }

    /// 首次进入时加载。已有内容时不再重发(返回这一页不该重新拉一遍)。
    func appear() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        hasLoaded = true
        lastFailure = nil

        // ① 先问各来源可不可用。不可用的整组不请求,也不进 `states`
        var active: [any DiscoverProvider] = []
        var unavailable: [DiscoverUnavailable] = []
        for provider in providers {
            if let reason = await provider.availability() {
                unavailable.append(reason)
            } else {
                active.append(provider)
            }
        }
        self.unavailable = unavailable

        let activeBoards = active.flatMap(\.boards)
        boards = activeBoards
        // 已经消失的组的旧状态要清掉,否则切了来源还留着上一份
        states = states.filter { key, _ in activeBoards.contains { $0.id == key } }
        hasMore = hasMore.filter { key, _ in activeBoards.contains { $0.id == key } }
        for board in activeBoards where states[board.id]?.value == nil {
            // 已有内容的组不退回 loading:原地刷新,不闪屏
            states[board.id] = .loading
        }

        guard !activeBoards.isEmpty else { return }

        // ② 全部榜单并发:每组独立失败,一组挂了另外几组照常出
        let jobs: [(any DiscoverProvider, DiscoverBoard)] = active.flatMap { provider in
            provider.boards.map { (provider, $0) }
        }

        await withTaskGroup(of: (String, LoadState<[DiscoverTitle]>, Bool).self) { group in
            for (provider, board) in jobs {
                group.addTask {
                    do {
                        let page = try await provider.load(board, page: 0)
                        return (board.id, .loaded(page.items), page.hasMore)
                    } catch is CancellationError {
                        return (board.id, .failed(LoadFailure(message: "已取消")), false)
                    } catch let error as DiscoverError {
                        return (board.id, .failed(LoadFailure(message: error.userMessage)), false)
                    } catch {
                        return (board.id, .failed(LoadFailure(message: "加载失败,请稍后重试。")), false)
                    }
                }
            }
            for await (id, state, more) in group {
                states[id] = state
                hasMore[id] = more
                if case .failed(let failure) = state, lastFailure == nil {
                    lastFailure = failure.message
                }
            }
        }
    }

    // MARK: - 单个榜单(「查看全部」页用)

    /// 某个榜单的 provider。找不到 = 配置问题,视图该显示「这个榜单还没实现」。
    func provider(for board: DiscoverBoard) -> (any DiscoverProvider)? {
        providers.first { $0.kind == board.source }
    }
}

/// 一组榜单的**分页加载**状态,给「查看全部」页用。
///
/// 与 `DiscoveryViewModel` 分开:首页只要第一页(三到七组并发),详情页只要一组(要翻页、要保状态)。
/// 塞进同一个类会让「谁在翻谁的页」变成隐式约定。
@MainActor
@Observable
final class DiscoverBoardViewModel {
    let board: DiscoverBoard
    private let provider: any DiscoverProvider

    private(set) var titles: [DiscoverTitle] = []
    private(set) var state: LoadState<[DiscoverTitle]> = .idle
    /// 还有没有下一页。首屏没加载完之前恒为 false,⛔ 不让「加载更多」按钮先亮一下。
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    /// 翻页失败的原因。首屏失败走 `state`,这里只装「下一页」的失败。
    private(set) var loadMoreFailure: String?

    /// 已取到第几页(0 起)
    private var loadedPage = -1

    init(board: DiscoverBoard, provider: any DiscoverProvider) {
        self.board = board
        self.provider = provider
    }

    func appear() async {
        guard case .idle = state else { return }
        await reload()
    }

    func reload() async {
        state = titles.isEmpty ? .loading : state
        loadMoreFailure = nil
        do {
            let page = try await provider.load(board, page: 0)
            titles = page.items
            hasMore = page.hasMore
            loadedPage = 0
            state = .loaded(page.items)
        } catch is CancellationError {
            state = .failed(LoadFailure(message: "已取消"))
        } catch let error as DiscoverError {
            state = .failed(LoadFailure(message: error.userMessage))
        } catch {
            state = .failed(LoadFailure(message: "加载失败,请稍后重试。"))
        }
    }

    /// 翻下一页。⛔ 不并发:`isLoadingMore` 挡住连点,否则同一页会被请求两次、结果互相覆盖。
    func loadMore() async {
        guard hasMore, !isLoadingMore, case .loaded = state else { return }
        isLoadingMore = true
        loadMoreFailure = nil
        defer { isLoadingMore = false }
        do {
            let page = try await provider.load(board, page: loadedPage + 1)
            // 按 id 去重:分页期间榜单在变,同一条可能出现在相邻两页
            let known = Set(titles.map(\.id))
            titles.append(contentsOf: page.items.filter { !known.contains($0.id) })
            hasMore = page.hasMore
            loadedPage += 1
            state = .loaded(titles)
        } catch is CancellationError {
            return
        } catch let error as DiscoverError {
            loadMoreFailure = error.userMessage
        } catch {
            loadMoreFailure = "加载失败,请稍后重试。"
        }
    }
}
