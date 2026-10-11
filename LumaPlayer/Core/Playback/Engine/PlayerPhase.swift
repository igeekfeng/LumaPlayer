import Foundation

/// 播放引擎的生命周期状态(**与内核无关**)。
///
/// 这是 `PlayerViewModel` 唯一观察的相位来源,内核自己的状态枚举
/// (如 Erika 的 `ErikaPlaybackState`)只在 `Core/Erika/` 的适配器里出现,
/// 换成别的内核时这一层不变。
///
/// ```text
/// idle ──open()──▶ loading ──▶ playing ⇄ paused
///                    │            │
///                    └─失败─▶ failed
///   playing/paused/… ──stop()/close()──▶ stopped / closed
/// ```
///
/// 说明:
/// - `loading` 覆盖「打开 + 探测 + 起播准备」整段,UI 的忙碌态看它;
/// - `stopped` 既可能是自然播完、也可能是外部停止 —— 区分靠
///   `PlayerEvent.ended(PlayerEndReason)`,不靠相位(Erika 没有独立的
///   EOF 事件/状态,见 `EofDetector`);
/// - `closed` 是终态,`close()` 之后引擎不可复用,换媒体 = 新建引擎。
enum PlayerPhase: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case stopped
    case failed
    case closed
}
