import Foundation

/// `/Items/{Id}/Images/{Type}` 的 `{Type}`(API_CONTRACT.md 3.3)。只列用到的,需要时再补。
enum EmbyImageType: String, Sendable, Equatable, Hashable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case logo = "Logo"
    case thumb = "Thumb"
}
