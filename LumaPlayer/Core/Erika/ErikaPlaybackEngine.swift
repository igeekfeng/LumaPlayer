import AppKit
import Erika
import os

/// Erika 内核的 `PlaybackEngine` 适配器。
///
/// ## 职责
/// 把 Erika 的 API / 事件 / 统计翻译成归一化类型。**这是全项目唯一 import Erika
/// 的播放文件**:内核升级或换内核时,改动收敛在这里与同目录的映射文件。
///
/// ## 线程
/// `ErikaPlayer` 是 `@MainActor`,所以本类全程主线程,**不需要任何并发逃逸**
/// (`@unchecked Sendable` / `nonisolated(unsafe)` / `@preconcurrency`)。
///
/// ## ⚠️ 待真机核实的内核语义(核实后只改本文件 / `EofDetector.swift`)
/// 1. **EOF 信号**:Erika 无独立 EOF 事件/状态,靠「位置到末尾 + 停止态」推断,
///    见 `EofDetector`;
/// 2. **表面挂接**:`ErikaVideoView` 自己 attach/resize Metal 层;`open` 是否要求
///    先 attach 未确认 —— 目前 `PlayerViewModel` 先让视图上屏再 open;
/// 3. **音量 0**:无独立静音开关,静音由上层用音量 0 实现;`setVolume(0)` 是否完全
///    静音未确认;音量无读回;
/// 4. **倍速 / 音量的可设时机**:当前在 `open` 之后、`play` 之前设置;
/// 5. **字幕**:`setSubtitleScale` 与 `setSubtitleStyle` 的叠加关系、Erika 字幕
///    默认值未确认(默认样式按「不覆盖 ASS」映射,见 `ErikaSubtitleStyle.init`);
/// 6. **轨道**:`tracks()` 是否填 `selected`、其 id 是否与 `trackSelection()` 一致;
/// 7. **统计字段语义**:`videoFrameBackpressureDrops` 当作「丢帧」、`rendererTrackedBytes`
///    当作「显存占用」、色彩 primaries/transfer 的枚举码到人读名的映射都是近似。
///
/// 以上均登记在 docs/KNOWN_ISSUES.md。
@MainActor
final class ErikaPlaybackEngine: PlaybackEngine {

    private let player: ErikaPlayer
    private var phaseValue: PlayerPhase = .idle
    private var detector = EofDetector()

    /// 待投递的归一化事件队列(一个内核事件可能翻译成多条,如 `stateChanged(stopped)`
    /// 会同时产生 `.phaseChanged` 与 `.ended`)
    private var pending: [PlayerEvent] = []
    /// `ErikaVideoView.onError` 从渲染回调报上来的错误,由 `pollEvent()` 排空
    private var surfaceErrors: [PlayerError] = []

    /// 统计来源的缓存(这些事件变化频繁且只有统计面板需要,不逐条推给上层)
    private var latestVideo: ErikaVideoParameters?
    private var latestDecoder: ErikaVideoDecoderInfo?

    private lazy var surface = makeSurface()

    init(upscaler: PlayerUpscaler) throws {
        var configuration = ErikaPlayer.Configuration(outputMode: .automatic)
        configuration.upscaler = upscaler.erikaValue
        player = try ErikaPlayer(configuration: configuration)
    }

    var phase: PlayerPhase { phaseValue }

    // MARK: - 生命周期与播放控制

    /// HTTP 预读窗口。Erika 传 0 时默认只有 2 MiB(20 Mbps 下不到 1 秒),实测是
    /// 「按码率现下现播」、暂停也不攒缓冲,网络一抖就卡;取旧内核 `demuxer-max-bytes`
    /// 的 128 MiB(ERIKA_INTEGRATION.md §6.1)。
    static let httpReadAheadBytes: UInt64 = 128 * 1024 * 1024
    /// 已播数据的回看缓存。Erika 默认 16 MiB;回看窗口从「下载头」往回算,不是从播放位置,
    /// 所以和预读一起放大(§6.1)。
    static let httpBackBufferBytes: UInt64 = 64 * 1024 * 1024

    func open(url: URL, headers: [String: String]) throws {
        do {
            try player.open(
                url,
                httpHeaders: headers,
                httpReadAheadBytes: Self.httpReadAheadBytes,
                httpBackBufferBytes: Self.httpBackBufferBytes
            )
        } catch {
            throw Self.playerError(error)
        }
        setPhase(.loading)
    }

    func play() throws {
        try call { try player.play() }
    }

    func pause() throws {
        try call { try player.pause() }
    }

    func stop() throws {
        detector.markLocalStop()
        try call { try player.stop() }
    }

    func close() {
        detector.markLocalStop()
        do {
            try player.close()
        } catch {
            // 关闭失败只留痕:调用方已经在拆卸,再抛错也没有补救动作
            Self.logger.error("Erika close 失败: \(String(describing: error), privacy: .public)")
        }
        phaseValue = .closed
    }

    func seek(to seconds: Double) throws {
        try call { try player.seek(to: seconds) }
    }

    func setRate(_ rate: Double) throws {
        try call { try player.setPlaybackRate(rate) }
    }

    func setVolume(_ volume: Double) throws {
        try call { try player.setVolume(volume) }
    }

    func setUpscaler(_ upscaler: PlayerUpscaler) throws {
        try call { try player.setUpscaler(upscaler.erikaValue) }
    }

    // MARK: - 轨道与字幕

    func tracks() throws -> [PlayerTrack] {
        do {
            return try player.tracks().map(Self.track(from:))
        } catch {
            throw Self.playerError(error)
        }
    }

    func selectAudioTrack(id: Int64?) throws {
        try call { try player.selectAudioTrack(id: id) }
    }

    func selectSubtitleTrack(id: Int64?) throws {
        try call { try player.selectSubtitleTrack(id: id) }
    }

    func setSubtitleStyle(_ style: PlayerSubtitleStyle) throws {
        try call { try player.setSubtitleScale(style.scale) }
        try call { try player.setSubtitleStyle(ErikaSubtitleStyle(style)) }
    }

    // MARK: - 表面 / 事件 / 统计

    func makeVideoSurface() -> NSView { surface }

    func pollEvent() throws -> PlayerEvent? {
        if !pending.isEmpty { return pending.removeFirst() }
        if !surfaceErrors.isEmpty { return .error(surfaceErrors.removeFirst()) }

        let raw: ErikaPlaybackEvent?
        do {
            raw = try player.pollEvent()
        } catch {
            throw Self.playerError(error)
        }
        guard let raw else { return nil }
        translate(raw)
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    func stats() throws -> PlayerStats {
        var stats = PlayerStats()

        // 轨道元数据:分辨率 / 编码 / 码率 / 音频参数
        let tracks = (try? player.tracks()) ?? []
        if let video = tracks.first(where: { $0.kind == .video }) {
            stats.width = video.width > 0 ? Int(video.width) : nil
            stats.height = video.height > 0 ? Int(video.height) : nil
            stats.videoCodec = video.codec
            stats.pixelFormat = video.pixelFormat
            stats.frameRate = video.framesPerSecond
            stats.videoBitRate = video.bitRate > 0 ? Int(video.bitRate) : nil
        }
        if let audio = tracks.first(where: { $0.kind == .audio }) {
            stats.audioCodec = audio.codec
            stats.audioSampleRate = audio.sampleRate > 0 ? Int(audio.sampleRate) : nil
            stats.audioChannels = audio.channels > 0 ? Int(audio.channels) : nil
            stats.audioBitRate = audio.bitRate > 0 ? Int(audio.bitRate) : nil
        }

        // 视频参数事件:补分辨率与色彩
        if let video = latestVideo {
            if stats.width == nil, video.width > 0 { stats.width = Int(video.width) }
            if stats.height == nil, video.height > 0 { stats.height = Int(video.height) }
            stats.colorPrimaries = Self.primariesName(video.primaries)
            stats.colorTransfer = Self.transferName(video.transfer)
        }

        // 解码器
        if let decoder = latestDecoder, !decoder.activeBackend.isEmpty {
            stats.decoderName = decoder.activeBackend
        }

        // 渲染帧数与软 / 硬解(用帧数判断比后端名更直接)
        if let presenter = try? player.presenterStats() {
            stats.renderedFrames = Int(presenter.renderedVideoFrames)
            stats.droppedFrames = Int(presenter.videoFrameBackpressureDrops)
            if presenter.hardwareVideoFrames > 0 {
                stats.isHardwareDecoded = true
            } else if presenter.softwareVideoFrames > 0 {
                stats.isHardwareDecoded = false
            }
            if stats.decoderName == nil, presenter.hardwareVideoFrames > 0 {
                stats.decoderName = "硬件解码"
            }
        }

        // 输出(HDR / EDR)
        if let output = try? player.outputStatus() {
            stats.outputMode = Self.outputModeName(output)
            if output.activeHeadroomKnown { stats.edrHeadroom = output.activeHeadroom }
        }

        // 资源
        if let resource = try? player.resourceStatus() {
            stats.memoryBytes = Int(resource.rendererTrackedBytes)
        }

        return stats
    }

    // MARK: - 事件翻译

    private func translate(_ raw: ErikaPlaybackEvent) {
        switch raw.kind {
        case .stateChanged:
            let newPhase = Self.phase(from: raw.state)
            // Erika 没有独立的暂停事件,暂停/恢复只体现在 stateChanged 的相位里。
            // 上层(`PlayerViewModel.isPaused` / 控制栏图标 / NowPlaying)靠 `.paused`
            // 判定,所以这里必须把它翻译出来 —— 只在真正跨越暂停边界时发,避免
            // 起播(loading→playing)也带一条多余的「恢复」。
            let previous = phaseValue
            setPhase(newPhase)
            if newPhase == .paused, previous != .paused {
                pending.append(.paused(true))
            } else if previous == .paused, newPhase == .playing {
                pending.append(.paused(false))
            }
            if let reason = detector.observe(.phaseChanged(newPhase)) {
                pending.append(.ended(reason))
            }

        case .positionChanged:
            let seconds = Double(raw.positionMicros) / 1_000_000
            pending.append(.position(seconds))
            if let reason = detector.observe(.position(seconds)) {
                pending.append(.ended(reason))
            }

        case .durationChanged:
            let seconds = Double(raw.durationMicros) / 1_000_000
            pending.append(.duration(seconds))
            _ = detector.observe(.duration(seconds))

        case .bufferingChanged:
            pending.append(.buffering(raw.buffering))

        case .tracksChanged:
            if let tracks = try? player.tracks() {
                pending.append(.tracksChanged(tracks.map(Self.track(from:))))
            }

        case .trackSelectionChanged:
            if let selection = try? player.trackSelection() {
                pending.append(.trackSelectionChanged(
                    audio: selection.audio, subtitle: selection.subtitle))
            }

        case .surfaceAttached:
            pending.append(.surfaceAttached)

        case .surfaceDetached:
            break

        case .error:
            let message = raw.error ?? raw.message ?? "播放失败"
            setPhase(.failed)
            let reason = PlayerEndReason.error(message)
            _ = detector.observe(.ended(reason))
            pending.append(.error(PlayerError(message)))
            pending.append(.ended(reason))

        case .videoParamsChanged:
            latestVideo = raw.video

        case .videoDecoderChanged:
            latestDecoder = raw.decoder

        case .audioOutputChanged:
            // 音频输出恢复状态目前统计面板不显示,忽略(需要时再从 raw.audio 取)
            break

        case .none:
            break
        }
    }

    private func setPhase(_ newPhase: PlayerPhase) {
        guard phaseValue != newPhase else { return }
        phaseValue = newPhase
        pending.append(.phaseChanged(newPhase))
    }

    // MARK: - 工具

    /// 调一个 Erika 方法并统一转错误
    private func call(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            throw Self.playerError(error)
        }
    }

    private func makeSurface() -> NSView {
        let view = ErikaVideoView()
        view.player = player
        // onError 的类型没有标 @MainActor,但视图会在主线程回调;为稳妥起见
        // 先取出可发送的字符串再 hop 回 MainActor 落账。
        view.onError = { [weak self] error in
            let message = String(describing: error)
            Task { @MainActor in
                self?.surfaceErrors.append(PlayerError("视频表面错误:\(message)"))
            }
        }
        return view
    }

    private static func playerError(_ error: Error) -> PlayerError {
        if let erika = error as? ErikaError {
            return PlayerError(erika.message)
        }
        return PlayerError(String(describing: error))
    }

    private static func phase(from state: ErikaPlaybackState) -> PlayerPhase {
        switch state {
        case .idle: .idle
        // open() 是同步探测,返回后即 Ready;Ready 与 Opening 都归到「准备中」
        case .opening, .ready: .loading
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        case .closed: .closed
        case .error: .failed
        }
    }

    private static func track(from erika: ErikaTrack) -> PlayerTrack {
        PlayerTrack(
            id: erika.id,
            kind: kind(from: erika.kind),
            source: erika.source == .external ? .external : .embedded,
            selected: erika.selected,
            title: erika.title,
            language: erika.language,
            codec: erika.codec
        )
    }

    private static func kind(from kind: ErikaTrackKind) -> PlayerTrackKind {
        switch kind {
        case .video: .video
        case .audio: .audio
        case .subtitle: .subtitle
        }
    }

    /// 输出模式人读名。用可确证的布尔量组合,不猜 `activeEncoding` 的编码码值。
    private static func outputModeName(_ output: ErikaOutputStatus) -> String {
        if output.extendedLinearActive { return "扩展线性 (scRGB)" }
        return "SDR / EDR(自动)"
    }

    /// FFmpeg `AVColorPrimaries` 的常见取值 → 人读名;未知码原样显示数字(不猜)。
    private static func primariesName(_ code: UInt32) -> String? {
        switch code {
        case 0: nil
        case 1: "BT.709"
        case 4: "BT.470M"
        case 5: "BT.470BG"
        case 6: "SMPTE 170M"
        case 7: "SMPTE 240M"
        case 8: "FILM"
        case 9: "BT.2020"
        case 10: "SMPTE 428"
        case 11: "SMPTE 431"
        case 12: "SMPTE 432"
        default: "primaries=\(code)"
        }
    }

    /// FFmpeg `AVColorTransferCharacteristic` 的常见取值 → 人读名;未知码原样显示数字。
    private static func transferName(_ code: UInt32) -> String? {
        switch code {
        case 0: nil
        case 1: "BT.709"
        case 4: "Gamma 2.2"
        case 5: "Gamma 2.8"
        case 6: "BT.601"
        case 7: "SMPTE 240M"
        case 8: "线性"
        case 9: "Log"
        case 10: "Log (sqrt)"
        case 11: "IEC 61966-2-4"
        case 12: "BT.1361"
        case 13: "sRGB"
        case 14: "BT.2020 (10bit)"
        case 15: "BT.2020 (12bit)"
        case 16: "PQ (HDR10)"
        case 17: "SMPTE 428 (DCI)"
        case 18: "HLG"
        default: "transfer=\(code)"
        }
    }

    private static let logger = Logger(
        subsystem: NetworkDiagnostics.subsystem, category: "playback")
}
