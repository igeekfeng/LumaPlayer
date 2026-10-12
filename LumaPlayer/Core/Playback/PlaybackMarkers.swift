import Foundation

/// 片头区间与片尾起点(纯值,无网络无 IO,靠单元测试覆盖)。
///
/// 数据有两个来源,校验是同一套:
/// - **服务端**:`MediaSource.Chapters` 里 `MarkerType` 为 `IntroStart` / `IntroEnd` /
///   `CreditsStart` 的条目(API_CONTRACT.md 4.3.1)。这些标记要服务端生成:
///   Emby 自带的片头检测需要 Premiere 且只对剧集生效,片尾大多靠插件写入 ——
///   所以**没有标记是常态**,本类型的每个结果都是可选的,调用方不得假设存在。
/// - **用户手动标注**:`ManualMarkers`(服务端检测不出来时自己标,见 `ManualMarkersStore`)。
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

    /// 从三个**原始位置**构造(用户手动标注的形态)。
    ///
    /// 校验与 `init(chapters:)` **同一套**:片头要两端都在且 `end > start`,
    /// `creditsStart` 要 `> 0` —— 少一个端、顺序颠倒、或片尾为 0 都当作「没标」。
    /// 手动输入同样可能只填了一半,不能因为「是用户填的」就放行。
    init(introStart: Double?, introEnd: Double?, creditsStart: Double?) {
        if let start = introStart, let end = introEnd, start >= 0, end > start {
            intro = start..<end
        } else {
            intro = nil
        }
        self.creditsStart = creditsStart.flatMap { $0 > 0 ? $0 : nil }
    }

    init(chapters: [EmbyChapter]?) {
        func position(of marker: String) -> Double? {
            chapters?
                .first { $0.markerType == marker }?
                .startPositionTicks
                .map { TickConverter.seconds(fromTicks: $0) }
        }
        self.init(
            introStart: position(of: EmbyChapter.Marker.introStart),
            introEnd: position(of: EmbyChapter.Marker.introEnd),
            creditsStart: position(of: EmbyChapter.Marker.creditsStart))
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
