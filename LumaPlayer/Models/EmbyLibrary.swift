import Foundation

/// 列表类响应的外壳:{ "Items": [...], "TotalRecordCount": n }
/// (API_CONTRACT.md 3.2 的 `/Users/{UserId}/Views`)。
///
/// 泛型是为了各列表端点复用同一外壳。
struct EmbyItemsResponse<Element: Decodable & Sendable>: Decodable, Sendable {
    let items: [Element]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

/// `/Users/{UserId}/Views` 返回的一个媒体库入口。
/// 术语统一为 View,不要叫 Library(API_CONTRACT.md 第 10 节)。
struct EmbyView: Decodable, Sendable, Hashable, Identifiable {
    /// BaseItem 的 Id 与 Name 必填(API_CONTRACT.md 8.1)
    let id: String
    let name: String?
    /// `movies` / `tvshows` / ...;**可能为 null**(混合媒体库),
    /// ⛔ 不得按必填解码(API_CONTRACT.md 3.2)
    let collectionType: String?
    /// 如 `{"Primary": "tag"}`;媒体库封面就是它的 `Primary` 图(API_CONTRACT.md 3.3 / 8.1)
    let imageTags: [String: String]?
    /// 口径差异见 docs/KNOWN_ISSUES.md Q13,与 `EmbyItem` 一样两个都解
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case imageTags = "ImageTags"
        case primaryImageTag = "PrimaryImageTag"
    }

    /// 封面图的 tag;没有就不请求(否则 404,API_CONTRACT.md 3.3),退回图标占位。
    var primaryImageTagValue: String? {
        imageTags?["Primary"] ?? primaryImageTag
    }
}
