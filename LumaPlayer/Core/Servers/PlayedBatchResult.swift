import Foundation

/// 批量标记已看 / 未看的结果(API_CONTRACT.md 5.8)。逐条发送、失败不中断,
/// 调用方必须把失败展示给用户并重读列表(见 `ServerConnection.setPlayed(itemIDs:played:)`)。
struct PlayedBatchResult: Sendable, Equatable {
    /// 服务端写回的 `UserData`,按条目 Id。界面用它,不自己推算派生值
    var written: [String: EmbyUserData] = [:]
    /// 按发送顺序
    var failedItemIDs: [String] = []
    /// UI 文案用。全部成功时 nil
    var firstError: EmbyAPIError?

    /// 空批次也算成功
    var isComplete: Bool { failedItemIDs.isEmpty }
}
