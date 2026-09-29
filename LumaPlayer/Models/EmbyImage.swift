import Foundation

/// 图片类型(`/Items/{Id}/Images/{Type}` 的 `{Type}`,API_CONTRACT.md 3.3)。
///
/// 官方取值有 Primary / Art / Backdrop / Banner / Logo / Thumb / Disc / Box /
/// Screenshot / Menu / Chapter;目前只用到前四种,需要时再补(不预留空壳)。
enum EmbyImageType: String, Sendable, Equatable, Hashable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case logo = "Logo"
    case thumb = "Thumb"
}
