import Foundation

/// 非 Emby 来源的播放进度出口:只写本地续播库,⛔ 不做网络上报(百度没有对应接口)。
///
/// 与 `PlaybackProgressReporter` 一致:每 10 秒落盘一次(断电最多丢 10 秒);
/// 写盘失败不抛、不中断播放,原因留在 `lastFailureDescription`。
actor LocalResumeReporting: PlaybackReporting {

    /// 落盘间隔(秒)
    static let persistInterval: TimeInterval = 10

    private let store: WatchProgressStore
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    /// 只用 `itemID` 当 key(百度为 `fs_id`);其余 id 只对 Emby 有意义。
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

    /// 交互后立即落盘,随手关窗时 seek 后的位置也已在盘上。
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

    /// 没有队列,`finish` 已落盘,空操作。
    func drain() {}

    /// 测试观察用
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
            // 不抛、不弹窗,下个周期再试
            lastFailureDescription = "\(error)"
        }
    }
}
