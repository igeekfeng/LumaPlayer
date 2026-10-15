import Foundation

/// 搜索结果。
///
/// 用 `SearchTerm` 走 `/Users/{UserId}/Items`(API_CONTRACT.md 3.2 标 🔶:
/// 允许实现,但要在真机核实 —— 官方 4.1.1.0 OpenAPI 只把 `SearchTerm` 列在
/// `/Search/Hints` 上,见 docs/KNOWN_ISSUES.md Q12)。
///
/// 不做输入防抖:搜索在**提交**时发起(工具栏搜索框里按回车),
/// 空关键词不请求 —— 免得每敲一个字就打一次服务器(服务器不是我们的,
/// 见项目 MEMORY.md 的低频纪律)。
///
/// 只搜电影 / 剧集 / 单集(`IncludeItemTypes`,3.2 ✅):不限定时服务端会把人物、
/// 音乐、文件夹也混进来,而 LumaPlayer 是视频播放器。
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

    /// 搜索支持的类型(见类型注释)
    static let searchItemTypes = ["Movie", "Series", "Episode"]

    /// 提交搜索。关键词为空视为「清空搜索」,不发请求。
    /// 同一服务器、同一关键词再提交一次 = 重新搜索(用户按回车就是想刷新)。
    func search(_ rawTerm: String, server: ServerProfile) {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            list = nil
            configuredTerm = nil
            return
        }
        // 同一服务器、同一关键词再提交 = 重新搜索:保留已显示的结果,只重拉第一页
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
