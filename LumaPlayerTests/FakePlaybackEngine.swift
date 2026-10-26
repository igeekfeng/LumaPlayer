import AppKit
@testable import LumaPlayer

/// `PlaybackEngine` 的测试替身:记录调用、可注入事件与统计。
///
/// 用途:验 `PlayerViewModel` 与 `PlaybackEventPump` 的接线,**不碰真实内核**。
/// ⛔ 它不是「假装能播」——真实解码/渲染那一段仍要真机验证,见 docs/KNOWN_ISSUES.md。
@MainActor
final class FakePlaybackEngine: PlaybackEngine {

    // MARK: - 状态

    private(set) var phase: PlayerPhase = .idle
    var statsValue = PlayerStats()
    var tracksValue: [PlayerTrack] = []
    /// 非 nil 时 `open` 抛这个错
    var openError: PlayerError?
    /// 非 nil 时 `pollEvent` 抛这个错
    var pollError: PlayerError?
    var logsValue: [PlayerLogEntry] = []
    /// 非 nil 时 `diagnosticLogs` 抛这个错
    var logsError: PlayerError?

    // MARK: - 调用记录

    private(set) var openedURLs: [URL] = []
    private(set) var openHeaders: [[String: String]] = []
    private(set) var didPlay = false
    private(set) var didPause = false
    private(set) var didStop = false
    private(set) var didClose = false
    private(set) var seeks: [Double] = []
    private(set) var rates: [Double] = []
    private(set) var volumes: [Double] = []
    private(set) var upscalers: [PlayerUpscaler] = []
    private(set) var audioSelections: [Int64?] = []
    private(set) var subtitleSelections: [Int64?] = []
    private(set) var subtitleStyles: [PlayerSubtitleStyle] = []

    private var queue: [PlayerEvent] = []
    private let surface = NSView()

    // MARK: - 测试控制

    func enqueue(_ event: PlayerEvent) { queue.append(event) }
    func setPhase(_ phase: PlayerPhase) { self.phase = phase }

    // MARK: - PlaybackEngine

    func open(url: URL, headers: [String: String]) throws {
        if let openError { throw openError }
        openedURLs.append(url)
        openHeaders.append(headers)
        phase = .loading
    }

    func play() throws { didPlay = true; phase = .playing }
    func pause() throws { didPause = true; phase = .paused }
    func stop() throws { didStop = true; phase = .stopped }
    func close() { didClose = true; phase = .closed }

    func seek(to seconds: Double) throws { seeks.append(seconds) }
    func setRate(_ rate: Double) throws { rates.append(rate) }
    func setVolume(_ volume: Double) throws { volumes.append(volume) }
    func setUpscaler(_ upscaler: PlayerUpscaler) throws { upscalers.append(upscaler) }

    func tracks() throws -> [PlayerTrack] { tracksValue }
    func selectAudioTrack(id: Int64?) throws { audioSelections.append(id) }
    func selectSubtitleTrack(id: Int64?) throws { subtitleSelections.append(id) }
    func setSubtitleStyle(_ style: PlayerSubtitleStyle) throws { subtitleStyles.append(style) }

    func makeVideoSurface() -> NSView { surface }

    func pollEvent() throws -> PlayerEvent? {
        if let pollError { throw pollError }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    func stats() throws -> PlayerStats { statsValue }

    func diagnosticLogs() throws -> [PlayerLogEntry] {
        if let logsError { throw logsError }
        return logsValue
    }
}
