import Foundation

/// 片头区间与片尾起点(秒)。
///
/// 来源:服务端 `MediaSource.Chapters` 的 `IntroStart` / `IntroEnd` / `CreditsStart`(API_CONTRACT.md 4.3.1),
/// 或用户手动标注 `ManualMarkers`,两者同一套校验。服务端标记要 Premiere / 插件,
/// 没有是常态,调用方不得假设存在。
struct PlaybackMarkers: Sendable, Equatable {
    /// [起点, 终点)。两端都在且终点晚于起点时才有值
    let intro: Range<Double>?
    let creditsStart: Double?

    static let none = PlaybackMarkers(intro: nil, creditsStart: nil)

    init(intro: Range<Double>?, creditsStart: Double?) {
        self.intro = intro
        self.creditsStart = creditsStart
    }

    /// 片头要两端都在且 `end > start`,`creditsStart` 要 `> 0`,否则当作没标。
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

    /// 是否该显示「跳过片头」。片头最后 `tailTolerance` 秒不显示:避免按钮闪烁,
    /// 也避免跳到终点后 time-pos 略早于终点又被判为片头内。
    func isInIntro(_ seconds: Double, tailTolerance: Double) -> Bool {
        guard let intro else { return false }
        return seconds >= intro.lowerBound && seconds < intro.upperBound - tailTolerance
    }

    /// 从哪起提示「下一集」:有效的 `creditsStart`,否则结束前 `fallbackLead` 秒;时长未知时 nil。
    func upNextTrigger(duration: Double, fallbackLead: Double) -> Double? {
        guard duration > 0 else { return nil }
        if let creditsStart, creditsStart < duration {
            return creditsStart
        }
        return max(0, duration - fallbackLead)
    }
}
