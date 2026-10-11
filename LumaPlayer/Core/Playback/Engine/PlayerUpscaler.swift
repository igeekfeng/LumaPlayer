import Foundation

/// 神经超分档位(**与内核无关**)。当前内核映射到 Erika 的 ArtCNN 亮度超分。
///
/// 只在 Apple Silicon 上有意义;`off` 是不做任何超分。
enum PlayerUpscaler: String, Sendable, CaseIterable, Equatable {
    /// 关闭超分(默认)
    case off
    /// ArtCNN 动漫 2× 亮度超分(C4F16)
    case artCNN

    /// 设置页显示名
    var label: String {
        switch self {
        case .off: "关闭"
        case .artCNN: "ArtCNN 动漫超分"
        }
    }
}
