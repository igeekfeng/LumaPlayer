import Foundation

/// 一次图片请求的完整描述(API_CONTRACT.md 3.3)。
///
/// `tag` 参与缓存 key:它是图片内容的版本标识,内容变了 key 就变,
/// 这样两台共享媒体库(相同 item id)的服务器不会互相串图。
struct ImageSpec: Sendable, Equatable, Hashable {
    let serverID: UUID
    let itemID: String
    let type: EmbyImageType
    let tag: String?
    /// 必带(API_CONTRACT.md 3.3:不给会下载原图)
    let maxWidth: Int

    var cacheKey: String {
        "\(serverID.uuidString)|\(itemID)|\(type.rawValue)|\(tag ?? "notag")|\(maxWidth)"
    }
}
