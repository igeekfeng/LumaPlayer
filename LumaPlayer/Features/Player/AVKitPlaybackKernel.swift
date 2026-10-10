import AVFoundation
import Foundation

/// AVKit 播放内核(`exp/avkit-rust-core`)。
///
/// ## 职责边界
///
/// 只管**一个 URL 的一次播放**(立场同 `ARCHITECTURE.md` 6.4 与
/// `docs/MPV_INTEGRATION.md` 第 8 节:一个播放器只播一个 URL,换台 = 销毁重建):
/// 放流、报告状态、选轨、seek。**不含**播放决策、URL 构造、进度上报与 UI ——
/// 那些分别在 `PlaybackPlanBuilder` / `PlaybackProgressReporter` / 播放窗口里。
///
/// ## 位置语义(⚠️ 与 `main` 的 mpv 不同)
///
/// `positionSeconds` 是**内核时间原点上的**位置。DirectStream 下它与绝对媒体位置
/// 相同;转码 / HLS 流的原点在起流点(P3 实测,文档 R13),要补偏移才是绝对位置
/// —— 换算归播放层(`PlaybackTimeBase`),内核不认识 Emby。
///
/// ## 位置与 `main` 上的 `MPVPlayer` 对应:同样把「内核是什么」圈在一个类型里,
/// 上层依赖的是它的**语义**(`PlaybackPhase` / `PlaybackTrack`),不是 AVFoundation 的类型。
/// P3c 起这份语义由 `PlaybackEngine` 协议固定下来(`AVKitPlaybackKernel` 是它的唯一实现),
/// 播放页只认协议,接线测试注入替身。
///
/// ## 三条实测驱动的硬规则(见 `docs/DECISIONS/avkit-rust-rearchitecture.md` 2.1)
///
/// 1. **不自动起播。** `load(plan:sourceStreams:)` 只把流放好,之后就绪即 `.paused`;
///    要播必须显式 `play()`。这与 mpv 的 `loadfile` 默认起播不同,是刻意的:
///    起播时机由播放窗口决定(要不要先 seek 到续播点、要不要等画面就位)。
/// 2. **起播后必须核轨。** AVFoundation 对不认识的编码是**静默删轨** ——
///    轨从列表里消失、`playable` 仍是 `true`、`errorLog` 也是空的。
///    所以"放起来了"不等于"放对了",必须再核一遍预期存在的视频 / 音频轨真的在。
///    见 `validateTracksIfNeeded` 与 `TrackExpectation`。
/// 3. **`phase` 里没有「已结束」态。** 播完时 `phase` 停在 `.playing`,靠 `isEnded` 判
///    (`docs/PITFALLS.md` Q7)。`PlaybackRules.shouldPreventDisplaySleep` 依赖这一条。
///
/// ## 起播位置
///
/// 内核**不认识** Emby,也就不做「续播点」这件事:
/// - DirectStream:调用方在 `.playing` 之后自己 `seek(to:)`(整份文件,偏移只能客户端给);
/// - Transcode:调用方带 `StartTimeTicks` 重新取一份 `PlaybackInfo` 再 `load`(4.5)。
///   这条路径下内核会被拆掉重建 —— 与 mpv 时代一样。
@MainActor
final class AVKitPlaybackKernel: PlaybackEngine {

    /// 失败与事件类型定义在 `PlaybackEngine` 那一侧:播放页只认协议,
    /// 替身内核与真内核必须给出**同一套**语义(见 `PlaybackEngine.swift`)。
    typealias Failure = PlaybackEngineFailure
    typealias Event = PlaybackEngineEvent

    // MARK: - 交给播放表面的东西

    /// 交给 `AVPlayerView` / `AVPlayerLayer` 的播放器。
    /// ⛔ 这是本类型**唯一**把 AVFoundation 对象漏出去的地方,别的都走语义属性。
    let player = AVPlayer()

    // MARK: - 状态

    private(set) var phase: PlaybackPhase = .idle
    private(set) var plan: PlaybackPlan?
    private(set) var failure: Failure?

    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    /// 已缓冲到的位置(秒);读不到时为 nil(不填 0 假装已缓冲)
    private(set) var bufferedUntilSeconds: Double?
    /// 倍速(mpv `speed` 的对应物,1 = 正常速度)
    private(set) var rate: Double = 1
    /// 0–100(与 `Metrics.volumeRange` 同一取值域;mpv 的 `volume` 也是这个域)
    private(set) var volume: Double = 100
    private(set) var isMuted = false
    /// **期望**的暂停态(不是 `AVPlayer.timeControlStatus` 的读数)。
    /// AVPlayer 把「速度」与「在不在播」压在同一个 `rate` 上,读回值分不出
    /// 「用户按了暂停」与「缓冲中自己停了」,所以暂停由这里记。
    private(set) var isPaused = false
    private(set) var isEnded = false

    private(set) var audioTracks: [PlaybackTrack] = []
    private(set) var subtitleTracks: [PlaybackTrack] = []
    private(set) var selectedAudioTrackID: Int?
    /// nil = 字幕关闭
    private(set) var selectedSubtitleTrackID: Int?

    /// 起播后的轨核验结论;nil = 还没核过
    private(set) var trackValidation: TrackExpectation.Outcome?
    /// 本次核验的口径(`sourceStreams == nil` 时为 nil,等于无法核实)
    private(set) var trackRequirement: TrackExpectation.Requirement?

    /// 事件出口。播放窗口在这里接上。
    var onEvent: ((Event) -> Void)?

    // MARK: - 私有状态

    private var item: AVPlayerItem?
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var audioOptions: [AVMediaSelectionOption] = []
    private var legibleOptions: [AVMediaSelectionOption] = []
    private var timeObserver: Any?
    private var notifications: [NSObjectProtocol] = []
    /// 核轨的宽限截止点:远端 / HLS 流的 `AVPlayerItem.tracks` 要等播放真正
    /// 建起来才填,不能一 readyToPlay 就判(会把好流误判成缺轨)。
    private var validationDeadline: ContinuousClock.Instant?
    private var didValidateTracks = false
    /// 会话代次。`load` / `teardown` 都 +1,用来丢弃上一轮的迟到回调。
    private var generation = 0

    // MARK: - 生命周期

    /// 放一条流。
    ///
    /// - Parameters:
    ///   - plan: `PlaybackPlanBuilder` 的产物(URL 已剥 `api_key`,认证走请求头)
    ///   - sourceStreams: 选中那条 `MediaSource.MediaStreams`,用于起播后的轨核验。
    ///     `nil`(服务端没给)时核验结论为 `unverifiable` —— ⛔ 不等于「核实过没问题」。
    /// - Throws: `Failure.notReady` / `Failure.playback`
    func load(plan: PlaybackPlan, sourceStreams: [EmbyMediaStream]?) async throws {
        reset()
        generation &+= 1
        let generation = self.generation

        self.plan = plan
        trackRequirement = TrackExpectation.requirement(forStreams: sourceStreams)
        setPhase(.loading)

        let asset = Self.makeAsset(plan)
        let item = AVPlayerItem(asset: asset)
        // mpv 那边靠 scaletempo 变速不变调;AVFoundation 的对应物是
        // `audioTimePitchAlgorithm`(.timeDomain 就是时域变速,与 scaletempo 同类)。
        // ⚠️ 听感未核对,已记 `docs/KNOWN_ISSUES.md`。
        item.audioTimePitchAlgorithm = .timeDomain
        self.item = item
        player.replaceCurrentItem(with: item)
        player.defaultRate = Float(rate)
        player.volume = Float(volume / 100)
        player.isMuted = isMuted

        observe(item)

        do {
            try await waitUntilReady(item, generation: generation)
        } catch {
            let failure = (error as? Failure) ?? .notReady(detail: "\(error)")
            fail(failure)
            throw failure
        }
        // 等在途期间被 teardown / 重新 load 掉了:直接撤,别把状态写回去
        guard generation == self.generation else { throw CancellationError() }

        durationSeconds = Self.duration(of: item)
        await reloadSelectionGroups()
        guard generation == self.generation else { throw CancellationError() }
        refreshTrackLists()

        // 流已就位但**没有起播**:起播时机归调用方(见类型注释第 1 条)
        isPaused = true
        setPhase(.paused)
    }

    /// 拆掉当前这次播放(关窗、换内容、转码重新起流都走它)。
    /// 幂等;拆完 `phase` 是 `.destroyed`。
    func teardown() {
        reset()
        generation &+= 1
        setPhase(.destroyed)
    }

    /// `isolated deinit` 才能调隔离的 `removeObserving()`(同
    /// `DisplaySleepAssertion` 的理由:定时观察者与通知是进程级资源,漏了就是泄漏)。
    /// ⛔ 别把这条当免死金牌:持有者若有引用环,deinit 根本不会跑。
    isolated deinit {
        removeObserving()
    }

    // MARK: - 播放控制

    /// 开始 / 继续播放。⛔ 只有这里会把画面放起来。
    ///
    /// 已经在播时是空操作(与 `AVPlayer.play()` 一致):⛔ 不重复发 `.paused(false)`,
    /// 否则播放页会把一次无意义的调用当成「用户恢复播放」再上报一次 Unpause。
    func play() {
        guard failure == nil, item != nil, isPaused else { return }
        isPaused = false
        isEnded = false
        player.defaultRate = Float(rate)
        player.play()
        onEvent?(.paused(false))
    }

    func pause() {
        guard item != nil, !isPaused else { return }
        isPaused = true
        player.pause()
        onEvent?(.paused(true))
    }

    func togglePlayPause() {
        isPaused ? play() : pause()
    }

    /// 倍速。区间与抹尾数都走 `Metrics.clampedSpeed`(与设置页同一个取值域)。
    ///
    /// ⚠️ 暂停中只记值不写 `player.rate` —— AVPlayer 里 `rate` 同时是「速度」与
    /// 「在不在播」,暂停时写个非 0 会直接把画面放起来(mpv 的 `speed` 与 `pause`
    /// 是两件独立的事)。
    func setRate(_ value: Double) {
        let clamped = Metrics.clampedSpeed(value)
        guard clamped != rate else { return }
        rate = clamped
        guard item != nil else { return }
        player.defaultRate = Float(clamped)
        if !isPaused { player.rate = Float(clamped) }
        onEvent?(.rate(rate))
    }

    /// 音量 0–100(`Metrics.volumeRange`)
    func setVolume(_ value: Double) {
        let clamped = min(max(value, Metrics.volumeRange.lowerBound), Metrics.volumeRange.upperBound)
        guard clamped != volume else { return }
        volume = clamped
        player.volume = Float(clamped / 100)
        onEvent?(.volume(volume))
    }

    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        player.isMuted = muted
        onEvent?(.muted(muted))
    }

    /// 跳转。**DirectStream 的客户端 seek 语义与 mpv 一致**(整份文件,精确落点);
    /// 转码 / HLS 的 seek 由 AVPlayer 在服务端 playlist 的时间轴上做,精度与延迟
    /// 与 mpv 不同 —— 这条尚未实测(文档第 9 节 R1)。
    func seek(to seconds: Double) async {
        guard let item else { return }
        let target = Self.clampedTarget(seconds, duration: durationSeconds)
        positionSeconds = target
        onEvent?(.position(target))
        let time = CMTime(seconds: target, preferredTimescale: Self.timescale)
        await withCheckedContinuation { continuation in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
        durationSeconds = Self.duration(of: item)
    }

    // MARK: - 轨道

    /// 选音轨。`id` 是 `PlaybackTrack.id`(= 该组内的选项序号)。
    /// 音频没有"关闭"这一说,所以不接受 nil。
    func selectAudioTrack(_ id: Int) {
        guard let group = audioGroup, audioOptions.indices.contains(id) else { return }
        item?.select(audioOptions[id], in: group)
        refreshTrackLists()
        onEvent?(.tracksChanged)
    }

    /// 选字幕轨;nil = 关字幕(`AVPlayerItem.select(nil, in:)`)。
    ///
    /// ⚠️ 只对进了 `legible` 媒体选择组的轨有效。PGS / VOBSUB 等位图字幕**根本
    /// 不在组里**(实测,文档 2.1),服务端不烧录就无字幕可用 —— 这是换 AVKit
    /// 明确接受的损失(文档第 3 节)。
    func selectSubtitleTrack(_ id: Int?) {
        guard let group = legibleGroup else { return }
        let option = id.flatMap { legibleOptions.indices.contains($0) ? legibleOptions[$0] : nil }
        if id != nil, option == nil { return }
        item?.select(option, in: group)
        refreshTrackLists()
        onEvent?(.tracksChanged)
    }

    // MARK: - 等待(自检脚本与测试用)

    /// 等到进入 `target` 阶段。超时返回 false,不抛错。
    func waitForPhase(_ target: PlaybackPhase, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if phase == target { return true }
            if phase == .failed { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return phase == target
    }

    // MARK: - 内部:观察

    private func observe(_ item: AVPlayerItem) {
        // 周期读数。0.25 秒是「进度条跟得上」与「不空转」的折中;
        // mpv 那边是逐帧的 time-pos,这里没必要那么密。
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: Self.tickSeconds, preferredTimescale: Self.timescale),
            queue: .main
        ) { [weak self] _ in
            // queue 指定了 .main → 这里确实在主线程,可以安全地断言隔离
            MainActor.assumeIsolated { self?.tick() }
        }

        let center = NotificationCenter.default
        notifications.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnded() }
        })
        notifications.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] notification in
            // ⚠️ 必须**在进隔离闭包之前**把错误取成字符串:`Notification` 不是 Sendable,
            // 捕获它跨隔离会被 Swift 6 的数据竞争检查拦下。
            let description = Self.describe(
                notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
            MainActor.assumeIsolated { self?.fail(.playback(description)) }
        })
        notifications.append(center.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTrackLists()
                self?.onEvent?(.tracksChanged)
            }
        })
    }

    private func removeObserving() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        for token in notifications {
            NotificationCenter.default.removeObserver(token)
        }
        notifications = []
    }

    // MARK: - 内部:每次读数

    private func tick() {
        guard let item else { return }
        if item.status == .failed {
            fail(.playback(Self.describe(item.error)))
            return
        }
        refreshPosition(item)
        syncPhase()
        validateTracksIfNeeded(item: item)
    }

    private func refreshPosition(_ item: AVPlayerItem) {
        let seconds = item.currentTime().seconds
        if seconds.isFinite, abs(seconds - positionSeconds) > Self.positionEpsilon {
            positionSeconds = seconds
            onEvent?(.position(seconds))
        }
        let duration = Self.duration(of: item)
        if duration != durationSeconds {
            durationSeconds = duration
            onEvent?(.duration(duration))
        }
        let buffered = Self.bufferedUntil(item)
        if buffered != bufferedUntilSeconds {
            bufferedUntilSeconds = buffered
            onEvent?(.buffered(buffered))
        }
    }

    /// 把 `AVPlayer` 的读数折成 `PlaybackPhase`。
    ///
    /// 顺序有意如此:`failed` 最先;`isEnded` 时**冻住**不改(规则 3:播完停在
    /// `.playing`);`timeControlStatus == .playing` 才叫在播;否则看期望的暂停态 ——
    /// 既没在播、又不是用户暂停,那就是在缓冲 / 起流中,报 `.loading`。
    private func syncPhase() {
        guard failure == nil, !isEnded else { return }
        guard item != nil else { return }
        let next: PlaybackPhase
        if player.timeControlStatus == .playing {
            next = .playing
        } else if isPaused {
            next = .paused
        } else {
            next = .loading
        }
        setPhase(next)
    }

    private func handleEnded() {
        // 规则 3:⛔ 不改 phase —— §8 状态机里没有「已结束」态,
        // `PlaybackRules.shouldPreventDisplaySleep` 靠 isEnded 而不是 phase 判。
        isEnded = true
        onEvent?(.ended)
    }

    // MARK: - 内部:轨核验(规则 2)

    private func validateTracksIfNeeded(item: AVPlayerItem) {
        guard !didValidateTracks else { return }
        guard let requirement = trackRequirement else {
            didValidateTracks = true
            trackValidation = .unverifiable
            onEvent?(.tracksValidated(.unverifiable))
            return
        }
        // 起播后才核:AVPlayerItemTrack 列表(尤其 HLS / 远端流)要等播放建起来才填
        guard player.timeControlStatus == .playing else { return }

        let presented = Self.presentedTracks(item)
        if presented == .none {
            // 一条都没看到:可能是系统还没填(给它一点时间),也可能是真的全被删了。
            // 宽限用完按实测结果判 —— ⛔ 不能无限期"再等等",那就是把守卫架空。
            if validationDeadline == nil {
                validationDeadline = ContinuousClock.now + .seconds(Self.validationGraceSeconds)
                return
            }
            if ContinuousClock.now < validationDeadline! { return }
        }

        didValidateTracks = true
        let outcome = TrackExpectation.evaluate(requirement: requirement, presented: presented)
        trackValidation = outcome
        onEvent?(.tracksValidated(outcome))
        if case .missing(let dimensions) = outcome {
            // 就是「有声音没画面」/「有画面没声音」那一类:⛔ 不能静默放过,
            // 它骗得过所有计数指标。
            fail(.missingTracks(dimensions))
        }
    }

    // MARK: - 内部:轨道列表

    private func reloadSelectionGroups() async {
        guard let item else { return }
        let asset = item.asset
        let characteristics = (try? await asset.load(
            .availableMediaCharacteristicsWithMediaSelectionOptions)) ?? []

        // 只有一条音轨时系统常常不给 audible 组 —— 那时 `audioTracks` 是空的,
        // 音轨菜单自然也是空的(不是"音轨丢了")。核轨不依赖这里(见 presentedTracks)。
        audioGroup = characteristics.contains(.audible)
            ? try? await asset.loadMediaSelectionGroup(for: .audible) : nil
        legibleGroup = characteristics.contains(.legible)
            ? try? await asset.loadMediaSelectionGroup(for: .legible) : nil
        audioOptions = audioGroup?.options ?? []
        legibleOptions = legibleGroup?.options ?? []
    }

    private func refreshTrackLists() {
        let selection = item?.currentMediaSelection
        audioTracks = Self.tracks(
            from: audioOptions,
            selected: audioGroup.flatMap { selection?.selectedMediaOption(in: $0) },
            type: .audio
        )
        subtitleTracks = Self.tracks(
            from: legibleOptions,
            selected: legibleGroup.flatMap { selection?.selectedMediaOption(in: $0) },
            type: .sub
        )
        // 读回,不假设「设了就生效」(MPV_INTEGRATION.md 第 7 节的同一条要求)
        selectedAudioTrackID = audioTracks.first { $0.selected }?.id
        selectedSubtitleTrackID = subtitleTracks.first { $0.selected }?.id
    }

    /// `AVMediaSelectionGroup` 的选项 → `PlaybackTrack`。
    ///
    /// `id` 取**组内序号**:`StreamIndexMapper` 的对应规则建立在「同一类型的轨道按
    /// 出现顺序一一对应」这个最弱假设上,而 `options` 的顺序就是容器顺序。
    ///
    /// ⚠️ 两个字段在 AVKit 下拿不到,一律如实留空而不是猜:
    /// - `codec`:AVFoundation 不暴露"这条媒体选择项是什么编码"。菜单副标题因此
    ///   只显示「外挂」这一项;要显示编码得由上层拿 Emby 的 `MediaStreams` 按序号补
    ///   (与 `StreamIndexMapper` 同一个假设),那是播放窗口(P3b)的事。
    /// - `isExternal`:媒体选择组里没有外挂轨的概念,恒为 false。
    private static func tracks(
        from options: [AVMediaSelectionOption],
        selected: AVMediaSelectionOption?,
        type: PlaybackTrackType
    ) -> [PlaybackTrack] {
        options.enumerated().map { index, option in
            let name = option.displayName
            return PlaybackTrack(
                id: index,
                type: type,
                selected: option == selected,
                title: name.isEmpty ? nil : name,
                lang: option.locale?.identifier ?? option.extendedLanguageTag,
                codec: nil,
                isExternal: false,
                isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
            )
        }
    }

    // MARK: - 内部:读数与构造(纯函数,自检脚本也要用)

    /// 起播后**实际**看得到的轨。`internal` 而非 private:自检脚本要直接验它。
    ///
    /// 两条独立证据取并集:
    /// - `AVPlayerItem.tracks`(表现层列表,`assetTrack` 才是真轨);
    /// - `presentationSize` —— HLS 下轨列表可能晚于画面出现,而系统知道画面尺寸
    ///   就说明视频轨在。⚠️ 反过来"有声音没画面"时它是 `.zero`,所以不会把这个
    ///   失败盖住(实测 TS + HEVC 就是这一形态)。
    static func presentedTracks(_ item: AVPlayerItem) -> TrackExpectation.Presented {
        var presented = TrackExpectation.Presented.none
        for track in item.tracks {
            switch track.assetTrack?.mediaType {
            case .video: presented.video = true
            case .audio: presented.audio = true
            default: break
            }
        }
        if !presented.video, item.presentationSize.width > 0, item.presentationSize.height > 0 {
            presented.video = true
        }
        return presented
    }

    /// 带认证头的 `AVURLAsset`(API_CONTRACT.md 第 6 节:认证走请求头,
    /// 所以 URL 侧的 `api_key` 由 `PlaybackURLBuilder.directStreamURL(serverProvided:)` 剥掉)。
    ///
    /// ⚠️ `AVURLAssetHTTPHeaderFieldsKey` 是**未公开**键(Apple 没有文档化,SDK 头文件里
    /// 也搜不到)。公开通路只有 `AVAssetResourceLoaderDelegate` —— 得自造 scheme、把每个
    /// 请求转成自己的 `URLSession` 任务再把数据喂回去,成本高一个量级。
    /// 本项目自用、不上架,先用它;风险与备选方案已记 `docs/KNOWN_ISSUES.md`。
    static func makeAsset(_ plan: PlaybackPlan) -> AVURLAsset {
        var options: [String: Any] = [
            // 精确时长:进度条的时长与 seek 落点都靠它(mpv 给的也是精确值)
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ]
        if !plan.headers.isEmpty {
            options[headerFieldsKey] = plan.headers
        }
        return AVURLAsset(url: plan.url, options: options)
    }

    static let headerFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

    /// 就绪等待的上限。本地文件通常 <1 秒;远端转码要等服务端起流 + 转码器预热。
    static let readyTimeoutSeconds: Double = 30
    /// 核轨的宽限时长(见 `validationDeadline`)
    static let validationGraceSeconds: Double = 5
    /// 周期读数间隔
    static let tickSeconds: Double = 0.25
    /// 位置变化到多少才发事件(滤掉浮点抖动)
    static let positionEpsilon: Double = 0.05
    static let timescale: CMTimeScale = 600

    // MARK: - 内部:小工具

    private func waitUntilReady(_ item: AVPlayerItem, generation: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(Self.readyTimeoutSeconds)
        while ContinuousClock.now < deadline {
            if Task.isCancelled || generation != self.generation { throw CancellationError() }
            switch item.status {
            case .readyToPlay: return
            case .failed: throw Failure.playback(Self.describe(item.error))
            default: break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.notReady(
            detail: "\(Self.readyTimeoutSeconds) 秒内没有就绪(\(Self.describe(item.error)))")
    }

    private func fail(_ failure: Failure) {
        // 第一次失败即终态:周期读数会一直看到 `status == .failed`,
        // 反复覆盖只会把首个(真正说明问题的)原因冲掉。
        guard self.failure == nil else { return }
        self.failure = failure
        isPaused = true
        player.pause()
        setPhase(.failed)
        onEvent?(.failed(failure))
    }

    private func setPhase(_ next: PlaybackPhase) {
        guard phase != next else { return }
        phase = next
        onEvent?(.phase(next))
    }

    /// 回到"没有流"的初始态。
    ///
    /// ⛔ 必须**先摘观察者**:`load` 可以反复调(转码 seek 的重新起流就是拆掉重建),
    /// 不摘的话每轮都会多留一个周期观察者与三条通知,旧实例的读数会打到新会话上。
    private func reset() {
        removeObserving()
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        plan = nil
        audioGroup = nil
        legibleGroup = nil
        audioOptions = []
        legibleOptions = []
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
        trackValidation = nil
        trackRequirement = nil
        didValidateTracks = false
        validationDeadline = nil
        failure = nil
        isEnded = false
        isPaused = false
        positionSeconds = 0
        durationSeconds = 0
        bufferedUntilSeconds = nil
        phase = .idle
    }

    private static func duration(of item: AVPlayerItem) -> Double {
        let seconds = item.duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private static func bufferedUntil(_ item: AVPlayerItem) -> Double? {
        var end: Double?
        for value in item.loadedTimeRanges {
            let seconds = value.timeRangeValue.end.seconds
            guard seconds.isFinite else { continue }
            end = max(end ?? 0, seconds)
        }
        return end
    }

    private static func clampedTarget(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let upper = duration > 0 ? duration : seconds
        return max(0, min(seconds, upper))
    }

    /// 失败描述。⛔ **不写 `String(describing: error)`**:`NSError` 的 userInfo 里带
    /// `NSURLErrorFailingURLStringErrorKey`,而串流 URL 上可能有 `api_key` ——
    /// 整串进日志/UI 等于把 token 写出去(`ARCHITECTURE.md` 8.1)。
    /// 这里取域 + 码 + 一句描述,再过一遍脱敏。
    ///
    /// `nonisolated`:错误通知的观察闭包在进 main actor 之前就要把通知体折成字符串
    /// (见 `observe(_:)` 里那条注释),所以这一步不能要求隔离。
    nonisolated static func describe(_ error: Error?) -> String {
        guard let error else { return "没有更多信息" }
        let nsError = error as NSError
        return SecretRedactor.redacted(
            "\(nsError.domain) \(nsError.code):\(nsError.localizedDescription)")
    }
}
