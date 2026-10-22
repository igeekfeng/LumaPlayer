import Foundation

/// 起播耗时时间线,分清慢在服务端、GL 还是 mpv 拉流探测。不含 URL / token;时钟由调用方传入。
struct PlaybackTimeline: Sendable, Equatable {
    /// 按发生顺序
    enum Stage: String, Sendable, CaseIterable {
        /// `PlaybackInfo`(含决策)返回
        case playbackInfo
        /// mpv 创建完、GL 渲染上下文挂好
        case glReady
        /// mpv 报已开始播放(拉流 + 探测 + 缓冲)
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

    /// 每个阶段只记第一次;`firstFrame` 记下后结束。
    /// - Parameter elapsed: 距起点的时长
    /// - Returns: 这次是否结束了时间线(调用方据此只写一次日志)
    @discardableResult
    mutating func mark(_ stage: Stage, elapsed: Duration) -> Bool {
        guard !isFinished, !marks.contains(where: { $0.stage == stage }) else { return false }
        marks.append((stage, elapsed))
        if stage == .firstFrame { isFinished = true }
        return isFinished
    }

    /// 超过即附带 mpv 明细(`TIMING-MPV`)
    static let slowThreshold: Duration = .seconds(3)

    var isSlow: Bool {
        (marks.last?.at ?? .zero) >= Self.slowThreshold
    }

    /// `{时间} TIMING method=DirectStream host=… dsu=provided total=3.42s | playbackInfo=0.52s glReady=0.05s playing=2.60s firstFrame=0.25s`
    /// 各阶段是相对上一阶段的间隔,total 是起点到最后一个阶段。
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
