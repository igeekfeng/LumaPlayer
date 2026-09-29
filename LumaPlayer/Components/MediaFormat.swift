import Foundation

/// 详情 / 卡片上的时长、日期文案。集中在这里,各页面不各写一套。
///
/// ⛔ 缺字段一律返回 nil,由调用方决定不显示 —— 不填「未知」「0 分钟」
/// 这类假值(API_CONTRACT.md 8.1)。
enum MediaFormat {
    /// 「1 小时 42 分钟」「45 分钟」。不足 1 分钟按 1 分钟算,免得显示「0 分钟」。
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

    /// 从现在开始完整播放 / 继续播放,预计几点结束(Emby Web 详情页的「结束于」)。
    static func endsAt(for item: EmbyItem, now: Date = Date()) -> Date? {
        guard let runtime = item.runTimeTicks, runtime > 0 else { return nil }
        let position = item.userData?.playbackPositionTicks ?? 0
        let left = runtime - (position < runtime ? position : 0)
        return now.addingTimeInterval(TickConverter.seconds(fromTicks: left))
    }

    /// 首映日期:只取 ISO 8601 原文的 `yyyy-MM-dd` 部分。
    /// Emby 给的是 7 位小数秒(`2024-01-01T00:00:00.0000000Z`),系统的
    /// ISO8601 解析器不认;而展示只需要年月日,不值得为它写解析。
    static func date(_ iso: String?) -> String? {
        guard let iso, iso.count >= 10 else { return nil }
        let day = String(iso.prefix(10))
        // 形如 0001-01-01 的占位日期是「没有」,不是公元 1 年
        return day.hasPrefix("0001") ? nil : day
    }

    /// 社区评分:保留一位小数。
    static func rating(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        return value.formatted(.number.precision(.fractionLength(1)))
    }
}
