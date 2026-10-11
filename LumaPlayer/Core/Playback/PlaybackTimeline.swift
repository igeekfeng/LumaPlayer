import Foundation

/// 起播耗时时间线(只记「花在哪一段」,不含 URL / token)。
///
/// 起播慢时要分清是服务端(PlaybackInfo)、本机(视频表面挂接)还是内核拉流探测慢,
/// 所以按阶段记录相邻两个时间点的间隔。值类型、时钟由调用方传入 → 可以脱离真实时间单测。
struct PlaybackTimeline: Sendable, Equatable {
    /// 阶段,按发生顺序
    enum Stage: String, Sendable, CaseIterable {
        /// `PlaybackInfo`(含决策)返回
        case playbackInfo
        /// 引擎建好、视频表面挂接完成
        case surfaceReady
        /// 已开始播放(拉流 + 探测容器 + 缓冲到能起播)
        case playing
        /// 收到第一个播放位置(≈ 出第一帧)
        case firstFrame
    }

    private(set) var marks: [(stage: Stage, at: Duration)] = []
    private(set) var isFinished = false

    static func == (lhs: PlaybackTimeline, rhs: PlaybackTimeline) -> Bool {
        lhs.isFinished == rhs.isFinished
            && lhs.marks.count == rhs.marks.count
            && zip(lhs.marks, rhs.marks).allSatisfy { $0.stage == $1.stage && $0.at == $1.at }
    }

    /// 记一个阶段。每个阶段只记第一次;`firstFrame` 记下后时间线结束。
    /// - Parameter elapsed: 距起点的时长
    /// - Returns: 这次调用是否**结束了**时间线(第一次记下 `firstFrame`)。调用方据此只写一次日志。
    @discardableResult
    mutating func mark(_ stage: Stage, elapsed: Duration) -> Bool {
        guard !isFinished, !marks.contains(where: { $0.stage == stage }) else { return false }
        marks.append((stage, elapsed))
        if stage == .firstFrame { isFinished = true }
        return isFinished
    }

    /// 起播耗时时间线的可读文本。
    ///
    /// `{时间} TIMING method=DirectStream host=… dsu=provided total=3.42s | playbackInfo=0.52s surfaceReady=0.05s playing=2.60s firstFrame=0.25s`
    /// 各阶段是**相对上一个阶段**的间隔,total 是起点到最后一个阶段。
    func line(method: String, host: String?, directStreamURLProvided: Bool, date: Date = .now) -> String {
        var previous = Duration.zero
        var parts: [String] = []
        for (stage, at) in marks {
            parts.append("\(stage.rawValue)=\(Self.format(at - previous))")
            previous = at
        }
        let total = marks.last?.at ?? .zero
        return [
            date.ISO8601Format(), "TIMING", "method=\(method)", "host=\(host ?? "?")",
            "dsu=\(directStreamURLProvided ? "provided" : "absent")",
            "total=\(Self.format(total))", "|", parts.joined(separator: " "),
            isFinished ? "" : "(未出画面)",
        ].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2fs", seconds)
    }
}
