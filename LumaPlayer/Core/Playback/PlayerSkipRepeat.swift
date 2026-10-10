import Foundation

/// 连点累加的跳转倍数(纯值 + 显式时间参数,无 IO 无 SwiftUI,靠单元测试覆盖)。
///
/// ⚠️ 原先放在 `Features/Player/PlayerControlsView.swift` 里。`exp/avkit-rust-core`
/// 摘掉 libmpv 时那个视图文件整个删了,但本类型是**纯状态机、与内核对无关**。
///
/// 单独成类型而不是塞在按钮视图里:视图里的 `@State` + `Date()` 没法测,
/// 而「第几次点击跳几倍」「什么时候归零」正是最容易写错的地方。
struct PlayerSkipRepeat {
    /// 上一次点击的时刻;nil = 还没点过
    private(set) var lastClick: Date?
    /// 上一次点击用的倍数
    private(set) var multiple = 0

    init() {}

    /// 记一次点击,返回这次该跳的倍数。
    ///
    /// 距上次点击超过 `Metrics.seekRepeatResetDelay` 就重新从 1 开始;
    /// 否则在上一档上加 1,到 `Metrics.seekRepeatMaxMultiple` 封顶
    /// (不封顶的话连点几十次会一次跳走几小时)。
    mutating func advance(now: Date) -> Int {
        let expired = isExpired(now)
        multiple = expired ? 1 : min(multiple + 1, Metrics.seekRepeatMaxMultiple)
        lastClick = now
        return multiple
    }

    /// 下一次点击会用几倍 —— tooltip 要预告这个数,不是上一次已经用过的。
    func upcoming(now: Date) -> Int {
        let current = isExpired(now) ? 0 : min(multiple, Metrics.seekRepeatMaxMultiple)
        return min(current + 1, Metrics.seekRepeatMaxMultiple)
    }

    private func isExpired(_ now: Date) -> Bool {
        lastClick.map { now.timeIntervalSince($0) > Metrics.seekRepeatResetDelay } ?? true
    }
}
