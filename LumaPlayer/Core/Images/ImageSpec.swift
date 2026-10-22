import Foundation

/// Emby 图片请求(API_CONTRACT.md 3.3)。`tag` 是内容版本,参与缓存 key。
struct ImageSpec: Sendable, Equatable, Hashable {
    let serverID: UUID
    let itemID: String
    let type: EmbyImageType
    let tag: String?
    /// 必带,不给会下载原图
    let maxWidth: Int

    var cacheKey: String {
        "\(serverID.uuidString)|\(itemID)|\(type.rawValue)|\(tag ?? "notag")|\(maxWidth)"
    }
}
