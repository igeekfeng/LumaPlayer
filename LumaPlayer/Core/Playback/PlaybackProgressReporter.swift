import Foundation

/// 一次上报会话的定位信息(从 `PlaybackPlan` 提取,5.1 的前四个字段 + CanSeek)。
struct PlaybackReportContext: Sendable, Equatable {
    let itemID: String
    let mediaSourceID: String
    let playSessionID: String
    let method: PlaybackMethod

    /// DirectStream 可自由 seek;转码流不能(4.5)
    var canSeek: Bool { method == .directStream }
}

/// 上报那一刻的播放状态快照(`PlayerViewModel` 推入)。
struct PlaybackReportState: Sendable, Equatable {
    var positionSeconds: Double
    var isPaused: Bool
    var isMuted: Bool
    /// 0–100
    var volume: Double
    /// Emby 流索引(`StreamIndexMapper` 换算);对不齐或未知为 nil
    var audioStreamIndex: Int?
    /// Emby 流索引;字幕关闭时为 nil
    var subtitleStreamIndex: Int?
    /// mpv `speed` 读回值
    var playbackRate: Double = 1

    /// 秒,未知为 nil。Emby 上报不用,本地续播库靠它判「已看完」(`WatchProgressStore`)
    var durationSeconds: Double?

    var positionTicks: Int64? {
        TickConverter.ticks(fromSeconds: positionSeconds)
    }

    var volumeLevel: Int? {
        Int(volume.rounded())
    }
}

/// 播放进度上报(API_CONTRACT.md 5.3/5.4)。
///
/// 串行 + 代次:actor 方法在 `await send` 时可重入,直接发请求会让切媒体时新旧请求乱序,
/// 旧片进度覆盖新片。所以入口只把端点连同 generation 入队,单个 runner 逐条发(最多一个在飞),
/// 取出时 generation 已变的旧条目直接丢弃。
///
/// 失败不抛、不阻塞、不弹窗,下个周期照常(5.4)。
/// 间隔固定 10 秒,⛔ 不得调小(5.3 官方说不必更频繁)。
actor PlaybackProgressReporter {

    static let reportInterval: TimeInterval = 10

    private struct Entry: Sendable {
        let generation: Int
        let endpoint: EmbyEndpoint
    }

    /// 生产:`ServerConnection.reportPlayback`
    private let send: @Sendable (EmbyEndpoint) async throws -> Void
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    /// 每次 `begin` +1
    private var generation = 0
    private var queue: [Entry] = []
    private var runnerTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    /// nil = 没在播(定时器停、`reportNow` 空操作)
    private var context: PlaybackReportContext?
    private var state: PlaybackReportState?
    /// 诊断用,不上 UI
    private(set) var lastFailureDescription: String?

    init(
        send: @escaping @Sendable (EmbyEndpoint) async throws -> Void,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.send = send
        self.sleeper = sleeper
    }

    // MARK: - 会话生命周期

    /// `POST /Sessions/Playing`(播放器就绪并开始播放时,6.6)并启动定时器;上一会话残留条目作废。
    func begin(context: PlaybackReportContext, state: PlaybackReportState) {
        generation += 1
        self.context = context
        self.state = state
        enqueue(.sessionsPlaying(body(eventName: nil, context: context, state: state)))
        startTimer()
    }

    func update(_ state: PlaybackReportState) {
        self.state = state
    }

    /// 交互触发,不等定时器(5.2/5.3)。
    func reportNow(eventName: PlaybackEventName) {
        guard let context, let state else { return }
        enqueue(.sessionsPlayingProgress(
            body(eventName: eventName, context: context, state: state)
        ))
    }

    /// 结束会话(6.6):`sendFinalProgress`(关窗 / 切媒体)先补一次 Progress 再 Stopped;
    /// 自然播完直接 Stopped。只入队不等发送。
    func finish(finalState: PlaybackReportState, sendFinalProgress: Bool) {
        guard let context else { return }
        if sendFinalProgress {
            enqueue(.sessionsPlayingProgress(
                body(eventName: .timeUpdate, context: context, state: finalState)
            ))
        }
        enqueue(.sessionsPlayingStopped(
            body(eventName: nil, context: context, state: finalState)
        ))
        timerTask?.cancel()
        timerTask = nil
        self.context = nil
        self.state = nil
    }

    /// 等已入队条目处理完(发出、失败、被丢弃都算)。关窗后详情页要等 Stopped 到达服务端
    /// 再读续播位置,否则读回旧进度(Q22)。在 `finish` 之后调用。
    func drain() async {
        // 等待期间若又入队会起新 runner,再等一轮
        while let runnerTask {
            await runnerTask.value
        }
    }

    /// 测试观测用;不含已取出正在发的那条
    var pendingCount: Int { queue.count }

    // MARK: - 私有

    private func enqueue(_ endpoint: EmbyEndpoint) {
        queue.append(Entry(generation: generation, endpoint: endpoint))
        startRunnerIfNeeded()
    }

    /// `runnerTask != nil` 保证只有一个 runner;挂起期间追加的条目由 `while` 兜住。
    private func startRunnerIfNeeded() {
        guard runnerTask == nil else { return }
        runnerTask = Task {
            while !queue.isEmpty {
                let entry = queue.removeFirst()
                guard entry.generation == generation else { continue }
                do {
                    try await send(entry.endpoint)
                    lastFailureDescription = nil
                } catch {
                    lastFailureDescription = "\(error)"
                }
            }
            runnerTask = nil
        }
    }

    /// Task 在 actor 内创建,继承隔离,可直接读 `context` / `state`。
    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                do {
                    try await sleeper(Self.reportInterval)
                } catch {
                    return // 只可能是 cancel
                }
                // cancel 未必命中 await 点,会话已结束就在这里退出
                guard context != nil else { return }
                reportNow(eventName: .timeUpdate)
            }
        }
    }

    private func body(
        eventName: PlaybackEventName?,
        context: PlaybackReportContext,
        state: PlaybackReportState
    ) -> PlaybackReportBody {
        PlaybackReportBody(
            itemID: context.itemID,
            mediaSourceID: context.mediaSourceID,
            playSessionID: context.playSessionID,
            playMethod: context.method.rawValue,
            positionTicks: state.positionTicks,
            isPaused: state.isPaused,
            isMuted: state.isMuted,
            volumeLevel: state.volumeLevel,
            canSeek: context.canSeek,
            audioStreamIndex: state.audioStreamIndex,
            subtitleStreamIndex: state.subtitleStreamIndex,
            playbackRate: state.playbackRate,
            eventName: eventName?.rawValue
        )
    }
}

extension PlaybackProgressReporter: PlaybackReporting {}
