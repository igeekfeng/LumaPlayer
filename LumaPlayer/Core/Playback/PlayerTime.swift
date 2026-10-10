import Foundation

/// 播放器的时间文案。
///
/// ⚠️ 原先放在 `Features/Player/PlayerControlsView.swift` 里。`exp/avkit-rust-core`
/// 摘掉 libmpv 时那个视图文件整个删了,但本类型是**纯格式化、与内核对无关**,
/// 且钉着两个已修复的回归(docs/PITFALLS.md),因此单列一个文件留着。
enum PlayerTime {
    /// 时间标签。总时长未知(0 / 非有限值)时显示 `--:--`,
    /// ⛔ 不填 `0:00` 假装已知(API_CONTRACT.md 8.1)。
    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// VoiceOver 读的版本:「1 小时 2 分 3 秒」,不读冒号。
    static func spokenText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "未知" }
        let duration = Duration.seconds(Int(seconds.rounded()))
        return duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// 剩余时长的标签:比 `text` 多一个 `-` 前缀。
    ///
    /// 抽出来是因为**剩余为 0 和时长未知是两回事**,而两者都会让
    /// `text` 返回 `--:--`,拼上 `-` 就成了 `---:--`(2026-10-03 修复):
    ///
    /// - 时长未知(`duration <= 0`)→ `--:--`,⛔ 不加负号。负号在这里
    ///   是「相对总时长的差值」的语义,没有总量就没有差值。
    /// - 剩余为 0(拖到最右 / 播到结尾)→ `-00:00`,负号保留。这是「确实
    ///   剩 0 秒」,不是不知道 —— `text(0)` 的 `--:--` 语义在这里是错的。
    static func remainingText(_ seconds: Double, durationKnown: Bool) -> String {
        guard durationKnown else { return text(0) }
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        let total = Int(clamped.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "-%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "-%02d:%02d", minutes, secs)
    }

    /// 按剩余时长与当前倍速推算的结束时刻。
    ///
    /// 倍速必须参与计算:1.25× 下「还剩 44 分钟」实际只过 35 分钟,
    /// 不换算就会算出一个偏晚的时刻。显示层拿它回答「看完得到几点」。
    ///
    /// 返回 nil 的四种情况,都是「宁可不显示也不显示编出来的值」:
    /// 时长未知(`API_CONTRACT.md` 8.1)、已播完、倍速非正或非有限、
    /// 剩余时长非正。
    static func endsAt(
        position: Double,
        duration: Double,
        speed: Double,
        isEnded: Bool,
        now: Date = Date()
    ) -> Date? {
        guard duration.isFinite, duration > 0, !isEnded else { return nil }
        guard speed.isFinite, speed > 0 else { return nil }
        guard position.isFinite else { return nil }
        let remaining = duration - position
        guard remaining > 0 else { return nil }
        return now.addingTimeInterval(remaining / speed)
    }
}
