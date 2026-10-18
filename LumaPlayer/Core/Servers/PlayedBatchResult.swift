import Foundation

/// 批量标记已看 / 未看的结果(API_CONTRACT.md 5.8)。
///
/// Emby **没有批量端点**,`ServerConnection.setPlayed(itemIDs:played:)` 是逐条发
/// 5.5 的请求,而且失败不中断(网络抖一下就丢掉后面几十集比「有几集没标上」更糟)。
/// 因此结果必须同时带上「成功写回的 UserData」与「失败的条目 Id」,
/// 由调用方把失败摆到用户面前并重读列表(CLAUDE.md 硬规则 4:不静默吞错)。
struct PlayedBatchResult: Sendable, Equatable {
    /// 服务端写回后的 `UserData`,按条目 Id。界面用服务端的值,不自己推算
    /// `PlayCount` 之类的派生值(与单条写入同一立场,API_CONTRACT.md 5.5)。
    var written: [String: EmbyUserData] = [:]
    /// 失败的条目 Id(按发送顺序)
    var failedItemIDs: [String] = []
    /// 第一个失败原因(UI 文案用)。全部成功时 nil。
    var firstError: EmbyAPIError?

    /// 全部写成功(空批次也算成功)
    var isComplete: Bool { failedItemIDs.isEmpty }
}
