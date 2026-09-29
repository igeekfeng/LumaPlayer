import Foundation

/// 一个 URL 查询参数。
///
/// ⛔ 键名只能取 `API_CONTRACT.md` 3.2 / 3.3 表格里出现过的名字
/// (CLAUDE.md:禁止发明端点与参数)。
struct EmbyQueryItem: Sendable, Equatable, Hashable {
    let name: String
    let value: String

    /// 位置参数写法:调用处是 `EmbyQueryItem("Limit", "20")`,
    /// 参数名在键名里已经写了一遍,再加标签只是噪音。
    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// `/Users/{UserId}/Items` 与 `/Users/{UserId}/Items/Resume` 的查询条件
/// (API_CONTRACT.md 3.2 的参数表)。
///
/// 每个字段都是「不给就不拼」:Emby 对默认值有自己的一套,
/// 显式传空字符串会把意图改掉。
struct EmbyItemsQuery: Sendable, Equatable {
    var parentID: String?
    var recursive: Bool?
    /// 逗号分隔,如 `Movie` / `Episode` / `Series`(API_CONTRACT.md 3.2)
    var includeItemTypes: [String] = []
    /// 🔶→✅ 按媒体大类过滤,视频是 `Video`。官方 OpenAPI 4.1.1.0 已把它列在
    /// `/Items/Resume` 等端点上(2026-09-23 核实),Emby Web 自己查「继续观看」
    /// 用的就是 `MediaTypes=Video`,不是 `IncludeItemTypes`。
    var mediaTypes: [String] = []
    var sortBy: [String] = []
    var sortOrder: [String] = []
    var fields: [String] = []
    var filters: [String] = []
    /// 🔶 搜索关键词。官方 4.1.1.0 OpenAPI 未把它列在 `/Items` 上
    /// (只在 `/Search/Hints` 上列出),`API_CONTRACT.md` 3.2 标 🔶 允许实现,
    /// 仍需在 4.7 真机上核实(docs/KNOWN_ISSUES.md Q12)。
    var searchTerm: String?
    /// 🔶 分页偏移。已由官方 OpenAPI 核实 ✅(2026-09-22)
    var startIndex: Int?
    var limit: Int?

    /// 固定顺序拼装,便于测试断言与回归比对。
    var queryItems: [EmbyQueryItem] {
        var items: [EmbyQueryItem] = []
        if let parentID { items.append(.init("ParentId", parentID)) }
        if let recursive { items.append(.init("Recursive", recursive ? "true" : "false")) }
        if !includeItemTypes.isEmpty { items.append(.init("IncludeItemTypes", includeItemTypes.joined(separator: ","))) }
        if !mediaTypes.isEmpty { items.append(.init("MediaTypes", mediaTypes.joined(separator: ","))) }
        if !sortBy.isEmpty { items.append(.init("SortBy", sortBy.joined(separator: ","))) }
        if !sortOrder.isEmpty { items.append(.init("SortOrder", sortOrder.joined(separator: ","))) }
        if !fields.isEmpty { items.append(.init("Fields", fields.joined(separator: ","))) }
        if !filters.isEmpty { items.append(.init("Filters", filters.joined(separator: ","))) }
        if let searchTerm { items.append(.init("SearchTerm", searchTerm)) }
        if let startIndex { items.append(.init("StartIndex", String(startIndex))) }
        if let limit { items.append(.init("Limit", String(limit))) }
        return items
    }
}

/// `/Users/{UserId}/Items/Latest` 的查询条件(API_CONTRACT.md 3.2)。
///
/// 该端点**没有** `StartIndex` / `SortBy` —— 官方 OpenAPI 只列出
/// Limit / ParentId / Fields / IncludeItemTypes(2026-09-22 核实),
/// 因此这里不提供分页与排序,免得拼出服务端不认的参数。
struct EmbyLatestQuery: Sendable, Equatable {
    var parentID: String?
    var includeItemTypes: [String] = []
    var fields: [String] = []
    var limit: Int?

    var queryItems: [EmbyQueryItem] {
        var items: [EmbyQueryItem] = []
        if let parentID { items.append(.init("ParentId", parentID)) }
        if !includeItemTypes.isEmpty { items.append(.init("IncludeItemTypes", includeItemTypes.joined(separator: ","))) }
        if !fields.isEmpty { items.append(.init("Fields", fields.joined(separator: ","))) }
        if let limit { items.append(.init("Limit", String(limit))) }
        return items
    }
}

/// `/Shows/{Id}/Episodes` 的查询条件(API_CONTRACT.md 3.2)。
///
/// 官方 OpenAPI 列出的可用参数:UserId / Fields / Season / SeasonId /
/// StartIndex / Limit / SortBy / SortOrder(2026-09-22 核实)。
/// `Season` 是季号数字,与 `SeasonId` 二选一;LumaPlayer 用 `SeasonId`
/// (来自季对象的 Id),不用季号——季号对特别篇等场景不可靠。
struct EmbyEpisodesQuery: Sendable, Equatable {
    var userID: String?
    var seasonID: String?
    var fields: [String] = []
    var sortBy: [String] = []
    var sortOrder: [String] = []
    var startIndex: Int?
    var limit: Int?

    var queryItems: [EmbyQueryItem] {
        var items: [EmbyQueryItem] = []
        if let userID { items.append(.init("UserId", userID)) }
        if let seasonID { items.append(.init("SeasonId", seasonID)) }
        if !fields.isEmpty { items.append(.init("Fields", fields.joined(separator: ","))) }
        if !sortBy.isEmpty { items.append(.init("SortBy", sortBy.joined(separator: ","))) }
        if !sortOrder.isEmpty { items.append(.init("SortOrder", sortOrder.joined(separator: ","))) }
        if let startIndex { items.append(.init("StartIndex", String(startIndex))) }
        if let limit { items.append(.init("Limit", String(limit))) }
        return items
    }
}

/// `/Shows/NextUp` 的查询条件(API_CONTRACT.md 3.2)。
///
/// ⚠️ 官方 OpenAPI 4.1.1.0 里的路径是 **`/Shows/NextUp`**,`SeriesId` 是查询参数,
/// 不是 `/Shows/{Id}/NextUp`(2026-09-23 核实,Q25 之前就是卡在这里)。
/// 该端点还列出 `ParentId` / `Fields` / `Limit` / `StartIndex` 等。
/// `SeriesId` 可选(4.1.1.0 核实 2026-09-23):nil = 跨所有剧集(首页「下一集」行)。
struct EmbyNextUpQuery: Sendable, Equatable {
    var userID: String
    var seriesID: String?
    var fields: [String] = []
    var limit: Int?

    var queryItems: [EmbyQueryItem] {
        var items: [EmbyQueryItem] = [.init("UserId", userID)]
        if let seriesID { items.append(.init("SeriesId", seriesID)) }
        if !fields.isEmpty { items.append(.init("Fields", fields.joined(separator: ","))) }
        if let limit { items.append(.init("Limit", String(limit))) }
        return items
    }
}

/// `/Items/{Id}/Similar` 的查询条件(API_CONTRACT.md 3.2)。
///
/// 官方 OpenAPI 4.1.1.0 列出 UserId / Limit / Fields / IncludeItemTypes 等(2026-09-23 核实)。
/// 必须带 `UserId`:否则响应里没有 `UserData`,卡片上的已看 / 进度标记无从显示。
struct EmbySimilarQuery: Sendable, Equatable {
    var userID: String
    var limit: Int?
    var fields: [String] = []

    var queryItems: [EmbyQueryItem] {
        var items: [EmbyQueryItem] = [.init("UserId", userID)]
        if let limit { items.append(.init("Limit", String(limit))) }
        if !fields.isEmpty { items.append(.init("Fields", fields.joined(separator: ","))) }
        return items
    }
}

/// `/Items/{Id}/Images/{Type}` 的查询条件(API_CONTRACT.md 3.3)。
///
/// `MaxWidth` / `MaxHeight` 至少给一个:不给服务端会返回原图(可能几十 MB)。
struct EmbyImageQuery: Sendable, Equatable {
    var maxWidth: Int?
    var maxHeight: Int?
    var tag: String?
    var format: String?

    var queryItems: [EmbyQueryItem] {
        var items: [EmbyQueryItem] = []
        if let maxWidth { items.append(.init("MaxWidth", String(maxWidth))) }
        if let maxHeight { items.append(.init("MaxHeight", String(maxHeight))) }
        if let tag { items.append(.init("Tag", tag)) }
        if let format { items.append(.init("Format", format)) }
        return items
    }
}
