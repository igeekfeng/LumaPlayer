import Foundation

/// 搜索结果。`SearchTerm` 走 `/Users/{UserId}/Items`(API_CONTRACT.md 3.2 标 🔶,
/// 待真机核实,见 docs/KNOWN_ISSUES.md Q12)。
///
/// 只在**提交**时搜索、空关键词不请求(服务器不是我们的);只搜电影 / 剧集 / 单集,
/// 不限定时服务端会把人物、音乐、文件夹也混进来。
@MainActor
@Observable
final class SearchViewModel {
    private let container: AppContainer

    private(set) var list: PagedItemList?

    private var configuredServerID: UUID?
    private var configuredTerm: String?

    /// 首次搜索或重新搜索进行中(顶栏加载线据此显示)。
    var isLoading: Bool { list?.isLoading ?? false }

    init(container: AppContainer) {
        self.container = container
    }

    static let searchItemTypes = ["Movie", "Series", "Episode"]

    /// 提交搜索。关键词为空视为清空搜索,不发请求;同服务器同关键词再提交 = 重新搜索。
    func search(_ rawTerm: String, server: ServerProfile) {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            list = nil
            configuredTerm = nil
            return
        }
        if configuredServerID == server.id, configuredTerm == term, let list {
            list.refresh()
            return
        }
        configuredServerID = server.id
        configuredTerm = term
        let itemTypes = Self.searchItemTypes
        list = PagedItemList { startIndex, limit in
            var query = EmbyItemsQuery()
            query.searchTerm = term
            query.recursive = true
            query.includeItemTypes = itemTypes
            query.startIndex = startIndex
            query.limit = limit
            let response = try await self.container.connection(for: server).items(query)
            return PagedFetchResult(items: response.items, totalRecordCount: response.totalRecordCount)
        }
        list?.reload()
    }

    /// 切换服务器后旧结果不再属于当前服务器。
    func reset() {
        list = nil
        configuredServerID = nil
        configuredTerm = nil
    }
}
