import Foundation

/// 百度源的播放进度出口:写本地续播库,⛔ 不做任何网络上报
/// (百度没有对应的接口,文档 §5.2)。
///
/// ## 与 `PlaybackProgressReporter` 刻意保持一致的两点
///
/// 1. **固定 10 秒落一次盘**。不是照抄服务端的 10 秒规定,而是同一条理由:
///    进程被杀、机器断电时最多丢 10 秒进度。间隔作为常量暴露,
///    测试注入 `sleeper` 断言它 —— 与 `PlaybackProgressReporter.reportInterval`
///    同一套测法。
/// 2. **失败不抛给调用方**。写盘失败不该让播放中断或弹窗(那正是上报失败在
///    Emby 侧的处置)。最后一次失败的原因留在 `lastFailureDescription` 里
///    供诊断,⛔ 不假装写成功了。
actor LocalResumeReporting: PlaybackReporting {

    /// 落盘间隔(秒)
    static let persistInterval: TimeInterval = 10

    private let store: WatchProgressStore
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    private var context: PlaybackReportContext?
    private var state: PlaybackReportState?
    private var timerTask: Task<Void, Never>?
    /// 最后一次落盘失败的原因(诊断用,不上 UI)
    private(set) var lastFailureDescription: String?

    init(
        store: WatchProgressStore,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.store = store
        self.sleeper = sleeper
    }

    // MARK: - PlaybackReporting

    func begin(context: PlaybackReportContext, state: PlaybackReportState) {
        self.context = context
        self.state = state
        startTimer()
    }

    func update(_ state: PlaybackReportState) {
        self.state = state
    }

    /// 交互事件(暂停 / 切轨 / seek 之后)立即落一次盘。
    /// 与 Emby 侧「交互不等待定时器」同一条纪律 —— 用户随手关窗时,
    /// 那一次 seek 的位置必须已经在盘上。
    func reportNow(eventName: PlaybackEventName) async {
        await persistCurrentState()
    }

    func finish(finalState: PlaybackReportState, sendFinalProgress: Bool) async {
        timerTask?.cancel()
        timerTask = nil
        state = finalState
        await persistCurrentState()
        context = nil
        state = nil
    }

    /// 本地实现没有队列,落盘在 `finish` 里已经做完 —— 空操作。
    func drain() {}

    /// 定时器在不在跑(测试观察用)
    var isTimerRunning: Bool { timerTask != nil }

    // MARK: - 内部

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [sleeper] in
            while !Task.isCancelled {
                do {
                    try await sleeper(Self.persistInterval)
                } catch {
                    return // 只可能是 cancel
                }
                guard self.context != nil else { return }
                await self.persistCurrentState()
            }
        }
    }

    private func persistCurrentState() async {
        guard let context, let state else { return }
        do {
            try await store.record(
                fileID: context.itemID,
                positionSeconds: state.positionSeconds,
                durationSeconds: state.durationSeconds
            )
            lastFailureDescription = nil
        } catch {
            // 与上报失败同一处置:不抛、不弹窗,记下来等下一个周期再试
            lastFailureDescription = "\(error)"
        }
    }
}
