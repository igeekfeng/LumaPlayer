import Foundation

/// 时长、日期文案,各页面共用。⛔ 缺字段返回 nil,不填「未知」「0 分钟」这类假值(API_CONTRACT.md 8.1)。
enum MediaFormat {
    /// 「1 小时 42 分钟」。不足 1 分钟按 1 分钟算。
    static func runtime(ticks: Int64?) -> String? {
        guard let ticks, ticks > 0 else { return nil }
        return duration(seconds: TickConverter.seconds(fromTicks: ticks))
    }

    /// 已看了一部分时的剩余时长;没有进度或已看完返回 nil。
    static func remaining(for item: EmbyItem) -> String? {
        guard let runtime = item.runTimeTicks, runtime > 0,
              let position = item.userData?.playbackPositionTicks, position > 0,
              position < runtime else { return nil }
        return duration(seconds: TickConverter.seconds(fromTicks: runtime - position))
    }

    static func duration(seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let minutes = max(1, Int((seconds / 60).rounded()))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(minutes) 分钟" }
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分钟"
    }

    /// 从现在播放 / 续播,预计几点结束。
    static func endsAt(for item: EmbyItem, now: Date = Date()) -> Date? {
        guard let runtime = item.runTimeTicks, runtime > 0 else { return nil }
        let position = item.userData?.playbackPositionTicks ?? 0
        let left = runtime - (position < runtime ? position : 0)
        return now.addingTimeInterval(TickConverter.seconds(fromTicks: left))
    }

    /// 只取原文的 `yyyy-MM-dd`:Emby 给 7 位小数秒,系统 ISO8601 解析器不认。
    static func date(_ iso: String?) -> String? {
        guard let iso, iso.count >= 10 else { return nil }
        let day = String(iso.prefix(10))
        // 形如 0001-01-01 的占位日期是「没有」,不是公元 1 年
        return day.hasPrefix("0001") ? nil : day
    }

    /// 社区评分,保留一位小数。
    static func rating(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        return value.formatted(.number.precision(.fractionLength(1)))
    }
}
