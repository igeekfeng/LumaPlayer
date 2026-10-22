import Foundation

/// 列表类响应外壳:`{ "Items": [...], "TotalRecordCount": n }`(API_CONTRACT.md 3.2)。
struct EmbyItemsResponse<Element: Decodable & Sendable>: Decodable, Sendable {
    let items: [Element]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

/// `/Users/{UserId}/Views` 的一个媒体库入口。术语统一为 View,不叫 Library(API_CONTRACT.md 第 10 节)。
struct EmbyView: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String?
    /// `movies` / `tvshows` / ...;混合媒体库为 null,⛔ 不得按必填解码(API_CONTRACT.md 3.2)
    let collectionType: String?
    /// 媒体库封面是它的 `Primary` 图(API_CONTRACT.md 3.3)
    let imageTags: [String: String]?
    /// 同 `EmbyItem`,两个都解(Q13)
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case imageTags = "ImageTags"
        case primaryImageTag = "PrimaryImageTag"
    }

    /// 没有就不请求(会 404),退回图标占位。
    var primaryImageTagValue: String? {
        imageTags?["Primary"] ?? primaryImageTag
    }
}
