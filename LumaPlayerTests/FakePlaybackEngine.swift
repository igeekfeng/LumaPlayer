import AVFoundation
import Foundation
@testable import LumaPlayer

/// 播放内核的替身(P3c 接线测试用)。
///
/// ## 为什么必须有它
///
/// 本机 `xcodebuild test` 起不了 App(`docs/KNOWN_ISSUES.md` Q34),而真实 `AVPlayer`
/// 也不该被拖进单测(要真流、真时间)。`PlayerViewModel` 只认 `PlaybackEngine` 协议,
/// 所以注入这个替身就能把**接线规则**测干净:什么时候 seek、转到哪个时间基、
/// 什么事件触发什么上报、偏好什么时候套上去。
///
/// ⛔ 它**不**替代 `Scripts/verify-avkit-playback.sh`:那个回答的是
/// 「真内核在这台机器上能不能播」,这里回答的是「接得对不对」。两件事都要。
///
/// 事件顺序刻意与真内核一致(`play()` 先 `.paused(false)`、阶段变化随后由读数推),
/// 这样播放页的事件处理路径在两边是同一段代码。
@MainActor
final class FakePlaybackEngine: PlaybackEngine {
    let player = AVPlayer()

    private(set) var phase: PlaybackPhase = .idle
    private(set) var plan: PlaybackPlan?
    private(set) var failure: PlaybackEngineFailure?
    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    private(set) var bufferedUntilSeconds: Double?
    private(set) var rate: Double = 1
    private(set) var volume: Double = 100
    private(set) var isMuted = false
    private(set) var isPaused = false
    private(set) var isEnded = false
    var audioTracks: [PlaybackTrack] = []
    var subtitleTracks: [PlaybackTrack] = []
    var selectedAudioTrackID: Int?
    var selectedSubtitleTrackID: Int?
    var trackValidation: TrackExpectation.Outcome?
    var onEvent: ((PlaybackEngineEvent) -> Void)?

    // MARK: - 记录

    private(set) var loadCount = 0
    private(set) var teardownCount = 0
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var loadedPlans: [PlaybackPlan] = []
    private(set) var loadedStreams: [[EmbyMediaStream]?] = []
    private(set) var seekTargets: [Double] = []
    private(set) var setRates: [Double] = []
    private(set) var setVolumes: [Double] = []
    private(set) var audioSelections: [Int] = []
    private(set) var subtitleSelections: [Int?] = []

    /// 非 nil 时 `load` 抛出它(验失败态接线)
    var loadFailure: PlaybackEngineFailure?

    // MARK: - PlaybackEngine

    func load(plan: PlaybackPlan, sourceStreams: [EmbyMediaStream]?) async throws {
        if let loadFailure { throw loadFailure }
        loadCount += 1
        loadedPlans.append(plan)
        loadedStreams.append(sourceStreams)
        self.plan = plan
        phase = .paused
        isPaused = true
    }

    func teardown() {
        teardownCount += 1
        plan = nil
        phase = .destroyed
        onEvent = nil
    }

    func play() {
        guard plan != nil, isPaused else { return }
        playCount += 1
        isPaused = false
        isEnded = false
        onEvent?(.paused(false))
    }

    func pause() {
        guard plan != nil, !isPaused else { return }
        pauseCount += 1
        isPaused = true
        onEvent?(.paused(true))
    }

    func setRate(_ value: Double) {
        // ⛔ 不夹取:夹取是内核的事,替身原样记下来,断言才看得出播放层交了什么
        setRates.append(value)
        rate = value
    }

    func setVolume(_ value: Double) {
        setVolumes.append(value)
        volume = value
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        onEvent?(.muted(muted))
    }

    func seek(to seconds: Double) async {
        seekTargets.append(seconds)
        positionSeconds = seconds
    }

    func selectAudioTrack(_ id: Int) {
        audioSelections.append(id)
        selectedAudioTrackID = id
    }

    func selectSubtitleTrack(_ id: Int?) {
        subtitleSelections.append(id)
        selectedSubtitleTrackID = id
    }

    // MARK: - 测试驱动(模拟内核读到的东西)

    /// 报告一个位置读数(内核时间原点上的)
    func reportPosition(_ seconds: Double) {
        positionSeconds = seconds
        onEvent?(.position(seconds))
    }

    func reportDuration(_ seconds: Double) {
        durationSeconds = seconds
        onEvent?(.duration(seconds))
    }

    func reportBuffered(_ seconds: Double?) {
        bufferedUntilSeconds = seconds
        onEvent?(.buffered(seconds))
    }

    func reportPhase(_ next: PlaybackPhase) {
        phase = next
        onEvent?(.phase(next))
    }

    func reportRate(_ value: Double) {
        rate = value
        onEvent?(.rate(value))
    }

    func reportVolume(_ value: Double) {
        volume = value
        onEvent?(.volume(value))
    }

    func reportTracks(_ audio: [PlaybackTrack], _ subtitles: [PlaybackTrack]) {
        audioTracks = audio
        subtitleTracks = subtitles
        selectedAudioTrackID = audio.first { $0.selected }?.id
        selectedSubtitleTrackID = subtitles.first { $0.selected }?.id
        onEvent?(.tracksChanged)
    }

    func reportEnded() {
        isEnded = true
        onEvent?(.ended)
    }

    func reportFailure(_ failure: PlaybackEngineFailure) {
        self.failure = failure
        isPaused = true
        phase = .failed
        onEvent?(.failed(failure))
    }
}

/// 会话准备的替身:按顺序吐出预先造好的会话,并记下每次要的起流位置。
actor FakeSessionPreparer: PlaybackSessionPreparing {
    private var sessions: [PlaybackSession]
    private var requestedStartTicks: [Int64?] = []
    private var thrownError: Error?

    init(sessions: [PlaybackSession]) {
        self.sessions = sessions
    }

    init(error: Error) {
        self.sessions = []
        self.thrownError = error
    }

    func makeSession(startTimeTicks: Int64?) async throws -> PlaybackSession {
        requestedStartTicks.append(startTimeTicks)
        if let thrownError { throw thrownError }
        guard !sessions.isEmpty else { throw PlaybackError.urlConstructionFailed }
        // 只有一条时反复给同一条(转码重新起流会再取一次)
        return sessions.count == 1 ? sessions[0] : sessions.removeFirst()
    }

    var startTicksRequests: [Int64?] { requestedStartTicks }
}

/// 显示器休眠断言的替身(与 `DisplaySleepAssertionTests` 同一个理由:
/// 被测逻辑不该依赖系统资源的可用性)。
@MainActor
final class FakeDisplaySleep: DisplaySleepInhibiting {
    private(set) var isHeld = false
    private(set) var transitions: [Bool] = []

    func setActive(_ active: Bool) {
        guard active != isHeld else { return }
        isHeld = active
        transitions.append(active)
    }
}

/// 上报出口的替身:记下所有入队的上报端点,不发任何请求。
///
/// 用真的 `PlaybackProgressReporter`(串行 + generation 那套逻辑本身有测试),
/// 只把 `send` 与 `sleeper` 换掉 —— 定时器用一个「久到不会醒」的睡眠,
/// 免得空转刷队列。
actor RecordingReporter {
    private(set) var endpoints: [EmbyEndpoint] = []

    func makeReporter() -> PlaybackProgressReporter {
        PlaybackProgressReporter(
            send: { [weak self] endpoint in
                await self?.record(endpoint)
            },
            sleeper: { _ in
                // 定时器:睡到测试结束(没有哪个用例会去等它)
                try await Task.sleep(for: .seconds(3600))
            }
        )
    }

    private func record(_ endpoint: EmbyEndpoint) {
        endpoints.append(endpoint)
    }

    /// 取出「已发出的」上报体(按入队顺序)
    var progressBodies: [PlaybackReportBody] {
        endpoints.compactMap { endpoint in
            if case .sessionsPlayingProgress(let body) = endpoint { return body }
            return nil
        }
    }

    var playingBody: PlaybackReportBody? {
        endpoints.compactMap { endpoint in
            if case .sessionsPlaying(let body) = endpoint { return body }
            return nil
        }.last
    }

    var stoppedBody: PlaybackReportBody? {
        endpoints.compactMap { endpoint in
            if case .sessionsPlayingStopped(let body) = endpoint { return body }
            return nil
        }.last
    }
}
