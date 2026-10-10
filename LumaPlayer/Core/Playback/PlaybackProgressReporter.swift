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

/// 上报那一刻的播放状态快照(由播放层在每次位置 / 暂停等状态变化后推入)。
struct PlaybackReportState: Sendable, Equatable {
    var positionSeconds: Double
    var isPaused: Bool
    var isMuted: Bool
    /// 0–100
    var volume: Double
    /// 选中音轨的 Emby 流索引(由 `StreamIndexMapper` 换算);对不齐或未知为 nil
    var audioStreamIndex: Int?
    /// 选中字幕轨的 Emby 流索引;字幕关闭时为 nil
    var subtitleStreamIndex: Int?
    /// 倍速(mpv `speed` 读回值,1 = 正常速度)
    var playbackRate: Double = 1

    var positionTicks: Int64? {
        TickConverter.ticks(fromSeconds: positionSeconds)
    }

    var volumeLevel: Int? {
        Int(volume.rounded())
    }
}

/// 播放进度上报(API_CONTRACT.md 5.4:全部上报经一个 actor 串行 + generation)。
///
/// ## 串行与代次(5.4 的两条硬要求)
///
/// actor 的方法在 `await send` 挂起期间可重入,若直接在方法体里发请求,
/// 「切媒体」时新旧两组请求会同时在飞,乱序到达服务端 —— 上一部片的
/// 进度就可能覆盖这一部。因此本类不直接发请求,而是:
///
/// 1. 所有入口只把**已构造完成的端点**连同当时的 generation 入队;
/// 2. 单个 runner 任务按入队顺序逐条发送,任意时刻最多一个请求在飞;
/// 3. runner 取出条目时比对 generation:切了会话(generation 已 +1)的
///    旧条目**直接丢弃**,不再发送 —— 这就是「丢弃所有旧 generation
///    的未完成请求结果」。
///
/// ## 失败策略(5.4)
///
/// 上报失败**不抛给调用方**、不阻塞播放、不弹窗:记录最后一次失败的
/// 描述,下一个定时周期照常尝试(服务端自己按秒推进,单次丢失无感)。
///
/// ## 定时(5.3)
///
/// 固定 `reportInterval` = 10 秒,⛔ 不得为了「更精确」调小 —— 官方原文
/// "it is not necessary to automatically report more often than at 10 second
/// intervals"。测试通过注入 `sleeper` 断言请求的睡眠时长恒为该值。
actor PlaybackProgressReporter {

    /// 定时上报间隔(秒)。5.3 官方规定,固定值。
    static let reportInterval: TimeInterval = 10

    private struct Entry: Sendable {
        let generation: Int
        let endpoint: EmbyEndpoint
    }

    /// 实际发请求的出口(生产:`ServerConnection.reportPlayback`)。
    private let send: @Sendable (EmbyEndpoint) async throws -> Void
    /// 定时器的睡眠函数(测试注入用)
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    /// 会话代次:每次 `begin` +1。旧代次的未发送条目由 runner 丢弃。
    private var generation = 0
    private var queue: [Entry] = []
    private var runnerTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    /// 当前会话;nil = 没在播(定时器停、`reportNow` 是空操作)
    private var context: PlaybackReportContext?
    private var state: PlaybackReportState?
    /// 最后一次上报失败的描述(诊断用,不上 UI —— 5.4 不弹窗)
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

    /// 开始一个会话:`POST /Sessions/Playing`(6.6:播放器就绪并开始播放时)
    /// 并启动 10 秒定时器。generation +1,上一会话残留的未发送条目作废。
    func begin(context: PlaybackReportContext, state: PlaybackReportState) {
        generation += 1
        self.context = context
        self.state = state
        enqueue(.sessionsPlaying(body(eventName: nil, context: context, state: state)))
        startTimer()
    }

    /// 刷新状态快照(定时 TimeUpdate 用的是**发送时刻**的最新快照)。
    func update(_ state: PlaybackReportState) {
        self.state = state
    }

    /// 用户交互触发的立即 Progress 上报(5.2 的 EventName 映射,
    /// 5.3:交互不等待定时器)。
    func reportNow(eventName: PlaybackEventName) {
        guard let context, let state else { return }
        enqueue(.sessionsPlayingProgress(
            body(eventName: eventName, context: context, state: state)
        ))
    }

    /// 结束当前会话(6.6):
    /// - `sendFinalProgress == true`(关窗/切媒体):先补一次最终 Progress,
    ///   再发 Stopped;
    /// - `false`(自然播完):直接 Stopped,位置用最终位置。
    ///
    /// 只入队、不等待发送完成 —— 调用方(播放器拆卸路径)不必为网络等。
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

    /// 等到**已入队**的条目全部处理完(发出、失败或被代次门丢弃都算完)。
    ///
    /// 用途:关窗后详情页要以服务端为准刷新续播位置(docs/PITFALLS.md Q22),
    /// 必须等 Stopped 真的到达服务端再读,否则读回的仍是起播前的旧进度。
    /// 应在 `finish` 之后调用 —— 那时定时器已停,队列不会再被续上。
    func drain() async {
        // runner 结束时自己置 nil;等待期间若又有入队,会起新的 runner,再等一轮
        while let runnerTask {
            await runnerTask.value
        }
    }

    /// 待发送条目数(测试观测用;generation 丢弃发生在 runner 取出时,
    /// 这个数不含「已取出正在发」的那条)。
    var pendingCount: Int { queue.count }

    // MARK: - 私有

    private func enqueue(_ endpoint: EmbyEndpoint) {
        queue.append(Entry(generation: generation, endpoint: endpoint))
        startRunnerIfNeeded()
    }

    /// 单个 runner 逐条发送。actor 方法在 `await send` 期间可重入,
    /// 但 `runnerTask != nil` 保证同时只有一个 runner 在跑;入队方在
    /// 挂起期间追加的条目由本循环的 `while !queue.isEmpty` 兜住。
    private func startRunnerIfNeeded() {
        guard runnerTask == nil else { return }
        runnerTask = Task {
            while !queue.isEmpty {
                let entry = queue.removeFirst()
                // 代次门:会话已切换的旧条目直接丢弃(5.4)
                guard entry.generation == generation else { continue }
                do {
                    try await send(entry.endpoint)
                    lastFailureDescription = nil
                } catch {
                    // 5.4:失败不阻塞播放、不弹窗,记录后等下一个周期补报
                    lastFailureDescription = "\(error)"
                }
            }
            runnerTask = nil
        }
    }

    /// 10 秒定时 TimeUpdate。Task 在 actor 内创建 → 继承 actor 隔离,
    /// 循环里可直接读 `context` / `state`,不会与入队方竞争。
    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                do {
                    try await sleeper(Self.reportInterval)
                } catch {
                    return // 只可能是 cancel
                }
                // 会话已结束(finish)就退出循环,而不是空转:`finish` 取消本
                // Task 之后,`await` 点未必正好命中,靠这里再兜一道。
                guard context != nil else { return }
                // `state` 由 reportNow 现读(发送时刻的最新快照)
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
