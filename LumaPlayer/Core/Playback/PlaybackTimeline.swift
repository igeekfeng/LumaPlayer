import Foundation

/// 起播耗时时间线(只记「花在哪一段」,不含 URL / token)。
///
/// 起播慢时要分清是服务端(`PlaybackInfo`)、本机(放流 + 等 `readyToPlay`)
/// 还是拉流缓冲慢,所以按阶段记录相邻两个时间点的间隔。值类型、时钟由调用方传入
/// → 可以脱离真实时间单测。
///
/// ⚠️ `exp/avkit-rust-core`:原 `glReady` 阶段是 libmpv 的 GL 渲染上下文挂接
/// (那是 `vo=libmpv` 特有的等待)。换 AVKit 后那一等没有了,取而代之的是
/// 「内核 `load()` 返回」—— 语义相近(流已就绪、还没起播),改名 `ready`。
struct PlaybackTimeline: Sendable, Equatable {
    /// 阶段,按发生顺序
    enum Stage: String, Sendable, CaseIterable {
        /// `PlaybackInfo`(含 Rust 决策)返回
        case playbackInfo
        /// 内核放流完成、`AVPlayerItem` 已就绪(尚未 `play()`)
        case ready
        /// `play()` 已发出 → 真的在播
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

    /// 起播总时长超过这个值就算慢,值得附带 mpv 明细(`TIMING-MPV`)
    static let slowThreshold: Duration = .seconds(3)

    var isSlow: Bool {
        (marks.last?.at ?? .zero) >= Self.slowThreshold
    }

    /// `{时间} TIMING method=DirectStream host=… dsu=provided total=3.42s | playbackInfo=0.52s ready=0.05s playing=2.60s firstFrame=0.25s`
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
