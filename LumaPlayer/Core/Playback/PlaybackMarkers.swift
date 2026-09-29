import Foundation

/// 片头区间与片尾起点(纯值,无网络无 IO,靠单元测试覆盖)。
///
/// 数据来自 `MediaSource.Chapters` 里 `MarkerType` 为 `IntroStart` / `IntroEnd` /
/// `CreditsStart` 的条目(API_CONTRACT.md 4.3.1)。这些标记要服务端生成:
/// Emby 自带的片头检测需要 Premiere 且只对剧集生效,片尾大多靠插件写入 ——
/// 所以**没有标记是常态**,本类型的每个结果都是可选的,调用方不得假设存在。
struct PlaybackMarkers: Sendable, Equatable {
    /// 片头 [起点, 终点)(秒)。只有两个标记都在、且终点晚于起点时才有值。
    let intro: Range<Double>?
    /// 片尾开始的位置(秒)
    let creditsStart: Double?

    static let none = PlaybackMarkers(intro: nil, creditsStart: nil)

    init(intro: Range<Double>?, creditsStart: Double?) {
        self.intro = intro
        self.creditsStart = creditsStart
    }

    init(chapters: [EmbyChapter]?) {
        func position(of marker: String) -> Double? {
            chapters?
                .first { $0.markerType == marker }?
                .startPositionTicks
                .map { TickConverter.seconds(fromTicks: $0) }
        }
        if let start = position(of: EmbyChapter.Marker.introStart),
           let end = position(of: EmbyChapter.Marker.introEnd),
           start >= 0, end > start {
            intro = start..<end
        } else {
            intro = nil
        }
        creditsStart = position(of: EmbyChapter.Marker.creditsStart).flatMap { $0 > 0 ? $0 : nil }
    }

    /// 当前位置是否该显示「跳过片头」。
    ///
    /// 片头最后 `tailTolerance` 秒不再显示:此时跳过只省一两秒,按钮刚出现就消失反而像闪烁;
    /// 也避免「跳到终点 → time-pos 落在终点前一点点 → 又判为片头内」的来回。
    func isInIntro(_ seconds: Double, tailTolerance: Double) -> Bool {
        guard let intro else { return false }
        return seconds >= intro.lowerBound && seconds < intro.upperBound - tailTolerance
    }

    /// 从哪个位置起提示「下一集」。
    ///
    /// 有 `CreditsStart` 就用它;没有就退回到「结束前 `fallbackLead` 秒」。
    /// 时长未知时返回 nil(不猜)。片尾标记晚于时长(脏数据)时同样退回兜底值。
    func upNextTrigger(duration: Double, fallbackLead: Double) -> Double? {
        guard duration > 0 else { return nil }
        if let creditsStart, creditsStart < duration {
            return creditsStart
        }
        return max(0, duration - fallbackLead)
    }
}
