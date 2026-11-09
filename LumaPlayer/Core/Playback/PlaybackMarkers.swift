import Foundation

/// 片头区间与片尾标记。
///
/// 来源:服务端 `MediaSource.Chapters` 的 `IntroStart` / `IntroEnd` / `CreditsStart`(API_CONTRACT.md 4.3.1),
/// 或用户手动标注 `ManualMarkers`,两者同一套校验。服务端标记要 Premiere / 插件,
/// 没有是常态,调用方不得假设存在。
struct PlaybackMarkers: Sendable, Equatable {
    /// [起点, 终点)。两端都在且终点晚于起点时才有值
    let intro: Range<Double>?
    /// 片尾标记。服务端给的是具体这一集的绝对时刻;手动标注按剧共用、每集长度不同,
    /// 所以用「结尾前 N 秒」,跨集自动适配。
    let credits: Credits?

    /// 片尾的两种表达。
    enum Credits: Sendable, Equatable {
        /// 固定时刻(从片首算秒):服务端标记,或兼容旧的绝对时刻手动标注。
        case at(Double)
        /// 距结尾时长(秒):手动标注的默认形式。
        case beforeEnd(Double)

        var isBeforeEnd: Bool {
            if case .beforeEnd = self { return true }
            return false
        }
    }

    static let none = PlaybackMarkers(intro: nil, credits: nil)

    init(intro: Range<Double>?, credits: Credits?) {
        self.intro = intro
        self.credits = credits
    }

    /// 片头要两端都在且 `end > start`,`credits` 要有效,否则当作没标。
    /// 兼容旧的「绝对时刻」入口(服务端章节 / 手动标注旧数据)。
    init(introStart: Double?, introEnd: Double?, creditsStart: Double?) {
        self.init(introStart: introStart, introEnd: introEnd, credits: creditsStart.map { .at($0) })
    }

    /// 手动标注走这里:片尾可以是「结尾前 N 秒」。
    init(introStart: Double?, introEnd: Double?, credits: Credits?) {
        if let start = introStart, let end = introEnd, start >= 0, end > start {
            intro = start..<end
        } else {
            intro = nil
        }
        switch credits {
        case .at(let seconds) where seconds > 0:
            self.credits = .at(seconds)
        case .beforeEnd(let lead) where lead > 0:
            self.credits = .beforeEnd(lead)
        default:
            self.credits = nil
        }
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

    /// 片尾在本集里的绝对时刻(秒)。相对标记要拿时长换算;时长未知、标记不合法时 nil。
    func creditsStart(duration: Double) -> Double? {
        guard duration > 0 else { return nil }
        switch credits {
        case .at(let seconds) where seconds > 0 && seconds < duration:
            return seconds
        case .beforeEnd(let lead) where lead > 0 && lead < duration:
            return duration - lead
        default:
            return nil
        }
    }

    /// 自动换集的切换点:有效的片尾,否则片尾(时长);时长未知时 nil。
    /// 相对标记按本集时长换算,所以每集长度不同也能落到正确的点。
    func upNextSwitchPoint(duration: Double) -> Double? {
        guard duration > 0 else { return nil }
        switch credits {
        case .at(let seconds) where seconds > 0 && seconds < duration:
            return seconds
        case .beforeEnd(let lead) where lead > 0 && lead < duration:
            return duration - lead
        default:
            return duration
        }
    }

    /// 从哪起提示「下一集」并开始倒计时:切换点前 `fallbackLead` 秒。
    /// 倒数在这 10 秒里跟着播放位置走完,到切换点就换集;⛔ 不是播完了才另计 10 秒。
    func upNextTrigger(duration: Double, fallbackLead: Double) -> Double? {
        guard let point = upNextSwitchPoint(duration: duration) else { return nil }
        return max(0, point - fallbackLead)
    }
}
