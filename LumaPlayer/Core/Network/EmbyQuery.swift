import Foundation

/// ⛔ 键名只能取 `API_CONTRACT.md` 3.2 / 3.3 表格里出现过的名字。
struct EmbyQueryItem: Sendable, Equatable, Hashable {
    let name: String
    let value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// `/Users/{UserId}/Items` 与 `.../Items/Resume` 的查询条件(API_CONTRACT.md 3.2)。
/// 每个字段都是「不给就不拼」:显式传空值会改掉 Emby 自己的默认语义。
struct EmbyItemsQuery: Sendable, Equatable {
    var parentID: String?
    var recursive: Bool?
    /// 如 `Movie` / `Episode` / `Series`
    var includeItemTypes: [String] = []
    /// ✅ 按媒体大类过滤,视频是 `Video`。Emby Web 查「继续观看」用的是它,不是 `IncludeItemTypes`。
    var mediaTypes: [String] = []
    var sortBy: [String] = []
    var sortOrder: [String] = []
    var fields: [String] = []
    var filters: [String] = []
    /// 🔶 官方 OpenAPI 只在 `/Search/Hints` 上列出,`/Items` 上待真机核实(KNOWN_ISSUES.md Q12)。
    var searchTerm: String?
    /// ✅ 分页偏移
    var startIndex: Int?
    var limit: Int?

    /// 固定顺序,便于测试断言。
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

/// `/Users/{UserId}/Items/Latest`(API_CONTRACT.md 3.2)。端点没有 `StartIndex` / `SortBy`,
/// 故不提供分页与排序。
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

/// `/Shows/{Id}/Episodes`(API_CONTRACT.md 3.2)。用 `SeasonId`(季对象的 Id),
/// 不用季号 `Season`:季号对特别篇等场景不可靠。
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

/// `/Shows/NextUp`(API_CONTRACT.md 3.2)。⚠️ `SeriesId` 是查询参数,不是 `/Shows/{Id}/NextUp`(Q25)。
/// `seriesID` 为 nil = 跨所有剧集(首页「下一集」行)。
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

/// `/Items/{Id}/Similar`(API_CONTRACT.md 3.2)。必须带 `UserId`,否则响应里没有 `UserData`。
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

/// `/Items/{Id}/Images/{Type}`(API_CONTRACT.md 3.3)。`MaxWidth` / `MaxHeight` 至少给一个,
/// 否则返回原图(可能几十 MB)。
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
