import AVFoundation
import Foundation
import Observation
import os

// MARK: - 失败文案(内核 / 决策 / 本地,全在这里折成一句人话)

extension LoadFailure {
    /// 本地失败(拼 URL、FFI 取值漂移、找不到被选中的源)
    init(_ error: PlaybackError) {
        self.init(message: error.userMessage, needsLogin: false)
    }

    /// **Rust 决策**的失败。文案由 Rust 侧 `PlaybackError::user_message` 生成,
    /// ⛔ Swift 不重新拼一份 —— 两份文案漂移的结果是「日志说是 A,界面显示说 B」。
    init(_ failure: PlaybackFailureFfi) {
        self.init(message: failure.userMessage, needsLogin: false)
    }

    /// 播放内核自己的失败(放不起来 / 静默删轨)
    init(_ failure: PlaybackEngineFailure) {
        self.init(message: failure.userMessage, needsLogin: false)
    }
}

extension PlaybackFailureFfi {
    /// 五种失败各自带一句可读文案,取出来直接用。
    var userMessage: String {
        switch self {
        case .ServerRejected(_, let message),
             .NoMediaSource(let message),
             .MissingRequiredField(_, let message),
             .NoPlayablePath(let message):
            return message
        case .UnplayableDirectStream(_, _, let message):
            return message
        }
    }
}

/// 播放页的状态机(会话、进度同步、轨道、seek 分派、上报)。
///
/// ## 流程(`exp/avkit-rust-core`)
///
/// `PlaybackSessionCoordinator` 取会话(PlaybackInfo → **Rust 决策** → 地址 + 认证头)
/// → 内核 `load` 放流 → 续播定位(DirectStream 客户端 seek;转码靠 `StartTimeTicks`
/// 重新起流)→ `play()` → 进入 `.playing` 时开始上报。
///
/// ## 与 `main` 的三处实质差异
///
/// 1. **位置要换算**(`PlaybackTimeBase` / R13):HLS 转码流的时间原点在起流点,
///    内核报的是相对值。`positionSeconds` / `durationSeconds` 对外一律是**绝对媒体位置**,
///    换算只在这一个类型里做。
/// 2. **内核是协议**(`PlaybackEngine`):上层只认语义,单测注入替身 ——
///    本机起不了 App(`KNOWN_ISSUES.md` Q34),接线规则只能这样测。
/// 3. **少了三样 mpv 专有能力**:字幕延迟、字幕外观、gpu-next 渲染开关
///    (AVKit 没有对应 API,文档第 3 节已记)。⛔ 别在 UI 上留一个点了没反应的入口。
@MainActor
@Observable
final class PlayerViewModel {
    private let container: AppContainer
    private let server: ServerProfile
    private let item: EmbyItem
    /// 播放内核。经 init 注入(单测给替身),视图只拿 `playablePlayer` ——
    /// 上层不接触内核类型,也不会误用它别的成员。
    private let engine: PlaybackEngine
    /// 上报出口(API_CONTRACT.md 5.4:所有上报经这一个 actor 串行)。
    private let reporter: PlaybackProgressReporter
    /// 播放期的显示器休眠断言。⛔ AVFoundation 同样不代 App 申请断言,
    /// 完全由宿主负责(判据见 `PlaybackRules.shouldPreventDisplaySleep`)。
    private let displaySleep: any DisplaySleepInhibiting
    /// 会话准备(取 PlaybackInfo → Rust 决策 → 地址 + 认证头)
    private let sessionPreparer: any PlaybackSessionPreparing

    private(set) var session: PlaybackSession?
    private(set) var failure: LoadFailure?
    /// 正在取 PlaybackInfo / 等内核就绪 / 重新起流
    private(set) var isPreparing = true
    private(set) var phase: PlaybackPhase = .idle
    private(set) var isPaused = false
    /// 转码 seek 正在重新起流(4.5):与首次取播放信息区分开,便于 UI 给准话
    private(set) var isRestarting = false

    // MARK: - 进度与轨道(位置一律是**绝对媒体位置**)

    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    /// 已缓冲到的位置(秒,绝对)
    private(set) var bufferedUntilSeconds: Double?
    /// 0–100(与 `Metrics.volumeRange` 同一取值域)
    private(set) var volume: Double = 100
    private(set) var isMuted = false
    private(set) var audioTracks: [PlaybackTrack] = []
    private(set) var subtitleTracks: [PlaybackTrack] = []
    private(set) var selectedAudioTrackID: Int?
    /// nil = 字幕关闭
    private(set) var selectedSubtitleTrackID: Int?
    /// 起播后的轨核验结论(R12 静默删轨的守卫有没有真的跑过)
    private(set) var trackValidation: TrackExpectation.Outcome?

    /// 用户在本次播放里手动选过字幕:默认偏好不再介入
    private var hasUserChosenSubtitle = false
    /// 默认偏好已应用过(轨道列表会被推多次,只挑一次)
    private var hasAppliedPreferredSubtitle = false

    // MARK: - 体验打磨(倍速 / 播完 / 下一集 / 屏显提示)

    /// 播放速率(读回值,不是设置值)。
    /// 「同一部剧沿用同一个倍速」的意图记在 `container.playbackSpeeds` 里。
    private(set) var speed: Double = 1

    /// 本次起播要用的倍速:这部剧记过就用它(优先级最高),没记过用设置页的
    /// 「默认倍速」,再没有才是 1×。
    var startupSpeed: Double {
        container.playbackSpeeds.speed(for: item, on: server)
            ?? container.preferences.defaultSpeed
    }

    /// 已自然播完。重播 / 重试时复位。
    private(set) var isEnded = false
    /// 剧集的下一集;不是剧集、已是最后一集或查询失败时为 nil。
    private(set) var nextEpisode: EmbyItem?
    /// 剧集的上一集(菜单栏「Previous Episode」)
    private(set) var previousEpisode: EmbyItem?
    /// 当前源的片头片尾标记(API_CONTRACT.md 4.3.1);服务端没给就是 `.none`。
    private(set) var markers = PlaybackMarkers.none
    /// 「下一集」倒计时剩余秒数;nil = 没在倒计时
    private(set) var upNextCountdown: Int?
    /// 本次播放里用户点过「取消」:不再提示、不再自动播下一集
    private(set) var isUpNextDismissed = false
    /// 画面上的短暂提示。每次都是新 id,视图据此重新计时消失。
    private(set) var osd: PlayerOSD?

    // MARK: - 统计 / 触控板拖动

    /// 统计信息 overlay 是否打开(按 I 切换;只在本次播放内有效,不持久化)
    private(set) var showsStatistics = false
    private(set) var statistics: PlayerStatistics?
    /// 触控板横滑拖进度时的预览目标(秒);nil = 没在拖。松手才真正 seek ——
    /// 转码模式下一次 seek 就是一次重新起流,不能边滑边 seek。
    private(set) var scrubPreviewSeconds: Double?

    // MARK: - 播放偏好(设置页「播放」页,UserDefaults 持久化)

    /// 状态存在 `container.preferences` 里,这里是转发:
    /// 设置窗口与播放窗口必须看到同一份,否则菜单里的勾和设置页对不上。
    var autoSkipIntro: Bool {
        get { container.preferences.autoSkipIntro }
        set { container.preferences.autoSkipIntro = newValue }
    }
    var autoPlayNext: Bool {
        get { container.preferences.autoPlayNext }
        set { container.preferences.autoPlayNext = newValue }
    }
    var floatsOnTop: Bool {
        get { container.preferences.floatsOnTop }
        set { container.preferences.floatsOnTop = newValue }
    }
    var seekStep: Double { container.preferences.seekStep }

    /// 自动跳过片头每次播放只触发一次:用户跳过后又拖回片头,说明就是想看,不能再把人弹走。
    private var didAutoSkipIntro = false
    /// 首个「可信」的位置是否已到达(DirectStream 续播时内核报的是文件开头,
    /// 拿它判片头会把续播位置覆盖掉 = `PlaybackRules.isSettledPosition`)。
    private var isPositionSettled = false

    /// 正在播的项(标题栏 / 窗口标题用)
    var playingItem: EmbyItem { item }
    var playingServer: ServerProfile { server }

    // MARK: - 私有状态

    /// 起播位置(秒,绝对)。来源有两个:打开时的续播位置,以及转码 seek 的目标。
    private var startSeconds: Double
    /// 本次会话的时间基(内核位置 ↔ 绝对位置)。会话就绪前是 DirectStream 语义(偏移 0)。
    private var timeBase = PlaybackTimeBase(offsetSeconds: 0)
    /// 服务端给的时长(秒)。**权威值**:转码起流后内核时长只剩剩余部分。
    private var serverDuration: Double?
    /// 是否已把起播偏移落到内核上
    private var didApplyStartOffset = false
    private var didBeginReporting = false

    private var startTask: Task<Void, Never>?
    private var nextEpisodeTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var upNextTask: Task<Void, Never>?
    /// 正在进行的 seek(内核异步 seek / 转码重新起流)。见 `waitForSeekToFinish()`。
    private var seekTask: Task<Void, Never>?
    /// 最近一次 `finishReporting` 的任务(finish + drain),供关窗后等待
    private var reportingFinishTask: Task<Void, Never>?
    /// 合并后的倍速上报任务(拖滑块时只留最后一次)
    private var rateReportTask: Task<Void, Never>?
    /// 转码 seek 合并后的重新起流任务(连点时只留最后一次)
    private var seekRestartTask: Task<Void, Never>?
    /// 每次「重新起流 / 收尾」自增。合并任务用它判断自己是否已被作废。
    private var restartEpoch = 0

    /// 会话代次。每次 `stop()` +1,用来丢弃上一轮内核的迟到事件。
    private var generation = 0

    /// 起播耗时(见 `PlaybackTimeline`);`start()` 时复位,出第一帧后写一行 TIMING
    private var timeline = PlaybackTimeline()
    private var timelineStart = ContinuousClock.now

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "playback")

    // MARK: - 生命周期

    init(
        container: AppContainer,
        server: ServerProfile,
        item: EmbyItem,
        startFromBeginning: Bool = false,
        engine: PlaybackEngine? = nil,
        sessionPreparer: (any PlaybackSessionPreparing)? = nil,
        reporter: PlaybackProgressReporter? = nil,
        displaySleep: (any DisplaySleepInhibiting)? = nil
    ) {
        self.container = container
        self.server = server
        self.item = item
        // 上报走缓存的连接实例(与浏览同一个 `EmbyAPIClient`,token 不重取)。
        // ⛔ 闭包是 `@Sendable`,**不能**在它里面调 `container.connection(for:)`
        // —— `AppContainer` 是 MainActor 类型,捕获它会过不了 Swift 6 并发检查。
        // 连接实例本身是 actor(Sendable),在 init(MainActor)里取出来再捕获。
        let connection = container.connection(for: server)
        self.reporter = reporter ?? PlaybackProgressReporter { endpoint in
            try await connection.reportPlayback(endpoint)
        }
        self.sessionPreparer = sessionPreparer
            ?? PlaybackSessionCoordinator(connection: connection, itemID: item.id)
        // 显示器休眠断言:App 里用真的 IOKit 断言,单测注入替身
        self.displaySleep = displaySleep ?? DisplaySleepAssertion()
        // 内核:App 里是真的 AVKit 内核,单测注入替身
        self.engine = engine ?? AVKitPlaybackKernel()
        // 恢复播放位置:`UserData.PlaybackPositionTicks` 是服务端记录的进度。
        // 为 nil / 为 0 即从 0 开始 —— 不猜「看过了多少」(8.1 禁止填假默认值)。
        // 「从头播放」显式忽略它。
        let resume = startFromBeginning
            ? 0
            : item.userData?.playbackPositionTicks.flatMap { TickConverter.seconds(fromTicks: $0) } ?? 0
        self.startSeconds = PlaybackRules.resumePosition(from: resume)
        // 服务端时长是权威值(`EmbyItem.RunTimeTicks`),拿不到才退回内核时长(见 `PlaybackTimeBase`)
        self.serverDuration = item.runTimeTicks.flatMap { TickConverter.seconds(fromTicks: $0) }
    }

    /// 起播位置(秒);仅供测试与日志观察,不参与播放决策。
    var resumeStartSeconds: Double { startSeconds }

    /// 当前会话代次。诊断与测试观察用 —— 代次门是「旧内核的迟到事件必须被丢弃」
    /// 那条规则的实现,测试要能拿到「当前那一档」去对照。
    var currentGeneration: Int { generation }

    /// 是否正持有「阻止显示器休眠」的断言(仅供测试与日志观察;
    /// `pmset -g assertions` 是另一个更权威的观察点)。
    var isPreventingDisplaySleep: Bool { displaySleep.isHeld }

    /// 正在缓冲(不是用户暂停、也没有在准备):`phase == .loading` 的那一段。
    var isBuffering: Bool { !isPreparing && phase == .loading }

    /// 交给播放表面的播放器。nil = 现在没有流可显示(还没放流 / 已经拆掉)。
    var playablePlayer: AVPlayer? { engine.plan == nil ? nil : engine.player }

    /// 能力表版本号(Rust 侧)。诊断用:这份结论是哪一版表得出的。
    var capabilityRevision: String? { session?.decision.capabilityRevision }

    func start() {
        guard startTask == nil else { return }
        timeline = PlaybackTimeline()
        timelineStart = ContinuousClock.now
        startTask = Task { await prepareAndLoad() }
        // 上一集 / 下一集与播放本身无关,单独查、只查一次(转码 seek 重新起流也走 start())
        if nextEpisodeTask == nil, item.kind == .episode {
            nextEpisodeTask = Task { [weak self] in await self?.loadAdjacentEpisodes() }
        }
    }

    /// 重试:内核实例不可复用(一个内核一次播放),所以必须整体重建,
    /// 不能只是再 `load` 一次。
    func retry() {
        stop()
        failure = nil
        session = nil
        isPreparing = true
        phase = .idle
        isPaused = false
        isRestarting = false
        isEnded = false
        // 新播放 = 新上报会话:不复位的话,播放中途出错再重试,
        // 新会话既不会补 seek 到起播位置,也永远不会发 Playing。
        didApplyStartOffset = false
        didBeginReporting = false
        isPositionSettled = false
        start()
    }

    /// 播完后从头再播。内核播完即卸载文件,所以不是 seek 到 0,而是整体重建。
    func replay() {
        startSeconds = 0
        positionSeconds = 0
        // 重看一遍 = 全新的一次观看:片头可以再自动跳、下一集可以再提示
        didAutoSkipIntro = false
        isUpNextDismissed = false
        retry()
    }

    /// 收尾:先按 ARCHITECTURE.md 6.6 结束上报会话(最终 Progress + Stopped),
    /// 再拆内核。关窗、切媒体、转码 seek 都走这里。
    func stop() {
        finishReporting(sendFinalProgress: true)
        // 收尾这一刻就把显示器休眠还回去:关窗 / 切媒体 / 转码重新起流都走这里。
        // 这里必须是**无条件释放**而不是按 phase 重算 —— stop() 返回后调用方
        // (retry / restartStream)才把 phase 置回 .idle,重算会把断言又拿一份。
        displaySleep.setActive(false)
        // 先递增:此后旧内核再投递的事件代次都对不上,一律丢弃。
        generation &+= 1
        startTask?.cancel()
        startTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        // 待发的倍速上报属于已经结束的会话:Stopped 之前的最终 Progress 会带上倍速
        rateReportTask?.cancel()
        rateReportTask = nil
        // 待起流的合并 seek 同样作废:关窗 / 切媒体后不能再自己起流。
        // 代次 +1 是给「已经过了 sleep、cancel 对它无效」的那个任务兜底。
        seekRestartTask?.cancel()
        seekRestartTask = nil
        restartEpoch &+= 1
        isRestarting = false
        stopUpNextCountdown()
        scrubPreviewSeconds = nil
        // 摘掉事件出口再拆内核:拆的过程中内核还会发 `.phase(.destroyed)`,
        // 那一下不该再写进已结束的会话。
        engine.onEvent = nil
        engine.teardown()
    }

    /// 等本次 seek 落地(内核的 seek 是异步的)。视图不需要它,
    /// 但「拖动 → 立刻关窗」与单测都需要一个可等待的点。
    func waitForSeekToFinish() async {
        await seekTask?.value
    }

    // MARK: - 控制

    func togglePlayPause() {
        isPaused ? engine.play() : engine.pause()
    }

    /// 倍速:连续值,夹在 `Metrics.speedRange` 内,不要求落在某个档位上。
    /// 转码流同样由客户端变速,服务端不需要知道。
    func setSpeed(_ value: Double) {
        let target = Metrics.clampedSpeed(value)
        guard target != speed else { return }
        engine.setRate(target)
        // 记住用户的选择:同一部剧的下一集、转码重新起流都从它起播。
        // 内核还没放流时照样记 —— 那个值会在新内核上生效(`applyStartupPreferences`)。
        container.playbackSpeeds.remember(target, for: item, on: server)
        flash(Metrics.speedText(target), systemImage: "gauge.with.dots.needle.67percent")
    }

    /// 按步长加 / 减(菜单栏 `[` `]` 与倍速浮层的 ±);已经贴着区间端点就不动。
    func stepSpeed(up: Bool, step: Double = Metrics.speedKeyStep) {
        let next = Metrics.steppedSpeed(from: speed, up: up, step: step)
        guard next != Metrics.clampedSpeed(speed) else { return }
        setSpeed(next)
    }

    /// 拖动到指定秒数(绝对媒体位置)。
    ///
    /// ⛔ 两种播放方式的 seek **不是同一件事**(API_CONTRACT.md 4.5):
    /// DirectStream 是静态文件,交给内核 seek;转码流不能客户端 seek,
    /// 必须停流 + `StartTimeTicks` 重新起一路流。
    ///
    /// 转码这条路径**带合并**:一次重新起流是 ~4 个请求,而连点前进 / 后退
    /// 会把同一个动作按次触发 `seekRepeatMaxMultiple` 次。合并后连点只在
    /// 停下来时起一次流(`seekRestartMergeDelay`)。`positionSeconds` 仍
    /// 立即更新 —— 进度条与 tooltip 要马上响应,不能等起流。
    func seek(to seconds: Double) {
        guard let session else { return }
        let target = max(0, min(seconds, durationSeconds > 0 ? durationSeconds : seconds))
        positionSeconds = target
        if session.plan.method == .directStream {
            let kernelTarget = timeBase.kernel(fromAbsolute: target)
            let previous = seekTask
            seekTask = Task { [weak self] in
                // 串在上一次 seek 之后:连点前进时不能让两个 seek 并行落地
                await previous?.value
                await self?.engine.seek(to: kernelTarget)
            }
            // 5.2:拖动结束立即上报,不等 10 秒定时器
            pushState()
            reportNow(.timeUpdate)
        } else {
            scheduleRestartStream(at: target)
        }
    }

    /// 方向键:相对当前位置快进 / 快退(UI_DESIGN.md 5.3)。
    func skip(by delta: Double) {
        seek(to: positionSeconds + delta)
        let seconds = Int(abs(delta))
        flash(delta < 0 ? "后退 \(seconds) 秒" : "前进 \(seconds) 秒",
              systemImage: delta < 0 ? "gobackward" : "goforward")
    }

    func setVolume(_ value: Double) {
        engine.setVolume(value)
    }

    /// 键盘调音量(↑ ↓,步长 `Metrics.volumeStep`)。调音量顺带解除静音 ——
    /// 静音时按 ↑ 却听不到声音,用户只会以为按键没生效。
    func adjustVolume(by delta: Double) {
        let target = max(0, min(Metrics.volumeRange.upperBound, volume + delta))
        if isMuted { engine.setMuted(false) }
        engine.setVolume(target)
        flash("音量 \(Int(target.rounded()))", systemImage: Metrics.volumeSymbol(target, muted: false))
    }

    func toggleMute() {
        engine.setMuted(!isMuted)
        flash(isMuted ? "取消静音" : "静音",
              systemImage: isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
    }

    /// 选音轨。核验读回值由内核的 `.tracksChanged` 触发 `refreshTracks()`。
    func selectAudioTrack(_ id: Int) {
        engine.selectAudioTrack(id)
        selectedAudioTrackID = id
        pushState()
        reportNow(.audioTrackChange)
        if let track = audioTracks.first(where: { $0.id == id }) {
            flash("音轨:\(track.displayName)", systemImage: "waveform")
        }
    }

    /// 选字幕轨;nil = 关字幕。
    ///
    /// 用户在这里做过一次选择之后,起播的默认偏好就让位,否则轨道列表的重推
    /// 会把用户刚选的顶掉。
    func selectSubtitleTrack(_ id: Int?) {
        hasUserChosenSubtitle = true
        engine.selectSubtitleTrack(id)
        selectedSubtitleTrackID = id
        pushState()
        reportNow(.subtitleTrackChange)
        let name = id.flatMap { id in subtitleTracks.first { $0.id == id }?.displayName }
        flash("字幕:\(name ?? "关闭")", systemImage: "captions.bubble")
    }

    /// 换到下一集:写一个新的播放请求,播放窗口据此重建播放页,
    /// 本页随之拆除并走完收尾上报(与关窗同一条路径)。
    func playNextEpisode() {
        guard let nextEpisode else { return }
        stopUpNextCountdown()
        container.play(nextEpisode, on: server)
    }

    func playPreviousEpisode() {
        guard let previousEpisode else { return }
        container.play(previousEpisode, on: server)
    }

    // MARK: - 跳过片头 / 下一集提示

    /// 「跳过片头」按钮是否该出现
    var isSkipIntroAvailable: Bool {
        session != nil && !isEnded && failure == nil
            && markers.isInIntro(positionSeconds, tailTolerance: Metrics.skipIntroTailTolerance)
    }

    /// 跳到片头终点。转码模式下这同样是一次重新起流(走 `seek` 的分派)。
    func skipIntro() {
        guard let intro = markers.intro else { return }
        seek(to: intro.upperBound)
        flash("已跳过片头", systemImage: "forward.fill")
    }

    /// 播放中的「下一集」提示是否该出现(播完之后由播完卡片接手,这里返回 false)。
    var isUpNextPromptVisible: Bool {
        guard nextEpisode != nil, !isUpNextDismissed, !isEnded, failure == nil,
              let trigger = markers.upNextTrigger(
                duration: durationSeconds, fallbackLead: Metrics.upNextFallbackLead)
        else { return false }
        return positionSeconds >= trigger
    }

    /// 取消下一集提示与倒计时(本次播放内不再出现)
    func dismissUpNext() {
        isUpNextDismissed = true
        stopUpNextCountdown()
    }

    // MARK: - 触控板横滑拖进度

    /// 横滑过程中累加预览位置(不 seek)。时长未知时不响应。
    func previewScrub(by delta: Double) {
        guard durationSeconds > 0 else { return }
        let base = scrubPreviewSeconds ?? positionSeconds
        scrubPreviewSeconds = min(max(0, base + delta), durationSeconds)
    }

    /// 手指离开:按预览位置 seek 一次。
    func commitScrub() {
        guard let target = scrubPreviewSeconds else { return }
        scrubPreviewSeconds = nil
        seek(to: target)
    }

    // MARK: - 统计信息

    func toggleStatistics() {
        showsStatistics.toggle()
        if showsStatistics {
            Task { await refreshStatistics() }
        } else {
            statistics = nil
        }
    }

    /// 低频刷新(`Metrics.playerMonitorInterval`)。统计信息只在 overlay 打开时读 ——
    /// accessLog 会短暂阻塞调用线程,没必要常驻轮询。
    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(Metrics.playerMonitorInterval)) } catch { return }
                guard let self, self.showsStatistics else { continue }
                await self.refreshStatistics()
            }
        }
    }

    private func refreshStatistics() async {
        guard let item = engine.player.currentItem else {
            statistics = nil
            return
        }
        // ⚠️ macOS 27 起 `accessLog()` / `errorLog()` 弃用(同步版还会阻塞调用线程)。
        // 新 API 是 completion-handler 形式的,包一层 continuation(文档 2.1
        // 「顺带记下的 API 变化」)。
        let accessLog = await Self.latestAccessLogEvent(item)
        let errorLog = await Self.latestErrorLogEvent(item)
        let size = item.presentationSize
        statistics = PlayerStatistics(readings: .init(
            methodDisplayName: session?.decision.methodDisplayName,
            container: session?.mediaSource.container,
            videoWidth: size.width > 0 ? Int(size.width) : nil,
            videoHeight: size.height > 0 ? Int(size.height) : nil,
            videoTrackCount: item.tracks.filter { $0.assetTrack?.mediaType == .video }.count,
            audioTrackCount: engine.audioTracks.count,
            subtitleTrackCount: engine.subtitleTracks.count,
            droppedFrameCount: accessLog?.numberOfDroppedVideoFrames,
            observedBitrate: accessLog.flatMap { $0.observedBitrate > 0 ? $0.observedBitrate : nil },
            stallCount: accessLog?.numberOfStalls,
            bufferedSeconds: bufferedUntilSeconds,
            rate: speed,
            itemStatusText: PlayerStatistics.statusText(item.status.rawValue),
            lastErrorText: errorLog.map { event in
                [String(event.errorStatusCode), event.errorComment]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
        ))
    }

    private static func latestAccessLogEvent(_ item: AVPlayerItem) async -> AVPlayerItemAccessLogEvent? {
        await withCheckedContinuation { continuation in
            item.fetchAccessLog { log in continuation.resume(returning: log?.events.last) }
        }
    }

    private static func latestErrorLogEvent(_ item: AVPlayerItem) async -> AVPlayerItemErrorLogEvent? {
        await withCheckedContinuation { continuation in
            item.fetchErrorLog { log in continuation.resume(returning: log?.events.last) }
        }
    }

    // MARK: - 内部:准备与放流

    private func prepareAndLoad() async {
        do {
            var prepared = try await sessionPreparer.makeSession(startTimeTicks: nil)
            try Task.checkCancellation()
            // 转码 + 非零起播:4.5 规定服务端从 StartTimeTicks 处起流。
            // 之所以「先取一次再带参数重取」,是因为 StartTimeTicks 同时是
            // 服务端的决策输入 —— 一上来就带值可能把本来能 DirectStream 的
            // 文件推去转码;确认为转码之后重取就没有这个顾虑。
            if prepared.plan.method == .transcode, startSeconds > 0 {
                prepared = try await sessionPreparer.makeSession(
                    startTimeTicks: TickConverter.ticks(fromSeconds: startSeconds))
                try Task.checkCancellation()
            }
            session = prepared
            timeBase = PlaybackTimeBase(
                method: prepared.plan.method,
                // 只有转码的起流点才是时间原点;DirectStream 的续播靠客户端 seek
                startSeconds: prepared.plan.method == .transcode ? startSeconds : 0
            )
            durationSeconds = timeBase.absoluteDuration(
                kernelDuration: 0, serverDuration: serverDuration)
            markers = PlaybackMarkers(chapters: prepared.mediaSource.chapters)
            markTimeline(.playbackInfo)

            // ⛔ 事件出口要在 load 之前挂上:load 期间内核就会发 `.phase(.loading)`
            let generation = self.generation
            engine.onEvent = { [weak self] event in
                self?.handle(event, generation: generation)
            }
            applyStartupPreferences()
            startMonitoring()

            try await engine.load(plan: prepared.plan, sourceStreams: prepared.sourceStreams)
            guard generation == self.generation else { return }
            markTimeline(.ready)
            isPreparing = false
            isRestarting = false
            positionSeconds = startSeconds
            await applyStartOffsetIfNeeded()
            guard generation == self.generation else { return }
            engine.play()
        } catch is CancellationError {
            return
        } catch let error as EmbyAPIError {
            if error == .cancelled { return }
            isPreparing = false
            failure = LoadFailure(error)
        } catch let error as PlaybackFailureFfi {
            isPreparing = false
            failure = LoadFailure(error)
        } catch let error as PlaybackError {
            isPreparing = false
            failure = LoadFailure(error)
        } catch {
            isPreparing = false
            failure = LoadFailure(message: "播放器启动失败:\(error)")
        }
    }

    /// 新内核一律是 1× / 音量 100 / 未静音,把起播偏好设回去。
    ///
    /// ⛔ 必须在 `load` **之前**调用:一开始放流内核就会推一次当前值,
    /// 先设好,读回来的就是目标值,屏显与上报都不会先闪一下 1×。
    private func applyStartupPreferences() {
        let startup = startupSpeed
        if startup != PlaybackPreferences.defaultSpeed {
            engine.setRate(startup)
            speed = startup
        }
        let targetVolume = container.preferences.defaultVolume
        if targetVolume != Metrics.defaultVolume {
            engine.setVolume(targetVolume)
            volume = targetVolume
        }
    }

    /// 续播定位。
    ///
    /// - DirectStream:服务端吐的是整份文件,偏移只能客户端给 —— 这里 seek。
    /// - Transcode:起流时已经带了 `StartTimeTicks`,**不再**客户端 seek
    ///   (那会变成在一条已偏移的流上再偏移一次);`positionSeconds` 直接认成起播点,
    ///   时间基的偏移会把内核的 0 映射回它。
    private func applyStartOffsetIfNeeded() async {
        guard !didApplyStartOffset else { return }
        didApplyStartOffset = true
        guard startSeconds > 0 else {
            isPositionSettled = true
            return
        }
        guard session?.plan.method == .directStream else { return }
        await engine.seek(to: timeBase.kernel(fromAbsolute: startSeconds))
    }

    /// 转码 seek 的重新起流:结束旧上报会话 → 拆掉内核(连接断开即停流)
    /// → 以新的 StartTimeTicks 重新走一遍准备流程(4.5)。
    private func restartStream(at seconds: Double) {
        // stop() 内部会发最终 Progress + Stopped(6.6:切换流即结束旧会话)
        stop()
        // ⛔ 必须在 stop() **之后**置位:stop() 会把待起流任务取消并复位
        // isRestarting,写在前面会被它冲掉。
        isRestarting = true
        startSeconds = seconds
        didApplyStartOffset = false
        didBeginReporting = false
        isPositionSettled = false
        positionSeconds = seconds
        isPaused = false
        phase = .idle
        isPreparing = true
        failure = nil
        start()
    }

    /// 转码 seek 的合并起流:等 `seekRestartMergeDelay` 内没有新的 seek 再起流。
    private func scheduleRestartStream(at seconds: Double) {
        seekRestartTask?.cancel()
        isRestarting = true
        restartEpoch &+= 1
        let epoch = restartEpoch
        seekRestartTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(Int(Metrics.seekRestartMergeDelay * 1000)))
            } catch {
                return
            }
            // 三重判据:任务没被取消、self 还在、代次没被 stop() / 新 seek 推进。
            // 最后一条是关键 —— stop() 会 cancel 本任务并清空引用,但已经
            // 通过 sleep 的任务不会因此被取消,不加代次就会在关窗后自己起流。
            guard let self, !Task.isCancelled, self.restartEpoch == epoch else { return }
            self.restartStream(at: seconds)
        }
    }

    // MARK: - 内部:事件

    /// 内核事件入口。`generation` 是**发出这条事件的内核实例**建立时的代次,
    /// 与当前代次不符即来自已被 `stop()` 拆掉的上一轮,直接丢弃。
    /// (`internal` 而非 `private`:接线测试要直接验这条门。)
    func handle(_ event: PlaybackEngineEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .phase(let newPhase):
            phase = newPhase
            // 暂停态以内核为准:AVPlayer 把「速度」与「在不在播」压在同一个 `rate` 上,
            // 读回值分不出「用户按了暂停」与「缓冲中自己停了」,所以期望态由内核记,
            // 播放页只镜像。⛔ 不在这里自己推 —— 两个真值来源必然漂移。
            isPaused = engine.isPaused
            updateDisplaySleepAssertion()
            if newPhase == .playing {
                markTimeline(.playing)
                beginReportingIfNeeded()
            }

        case .position(let kernelSeconds):
            let absolute = timeBase.absolute(fromKernel: kernelSeconds)
            markTimeline(.firstFrame)
            positionSeconds = absolute
            pushState()
            if !isPositionSettled {
                isPositionSettled = PlaybackRules.isSettledPosition(
                    absolute, startSeconds: startSeconds, method: session?.plan.method)
            }
            evaluatePlaybackPrompts()

        case .duration(let kernelDuration):
            let total = timeBase.absoluteDuration(
                kernelDuration: kernelDuration, serverDuration: serverDuration)
            if total != durationSeconds { durationSeconds = total }

        case .buffered(let kernelBuffered):
            bufferedUntilSeconds = kernelBuffered.map(timeBase.absolute(fromKernel:))

        case .paused(let paused):
            isPaused = paused
            updateDisplaySleepAssertion()
            // 5.2:暂停 / 恢复立即上报
            pushState()
            reportNow(paused ? .pause : .unpause)

        case .rate(let value):
            // 内核起播时会先报一次初始值(1),没变就不上报
            guard value != speed else { return }
            speed = value
            pushState()
            // 5.2 要求改倍速立即上报,但滑块是连续的(0.05 一跳),一次拖动
            // 就是十几个请求 —— 真实服务器纪律要求低频,所以合并成一次:
            // 停手 `Metrics.speedReportDelay` 后再发,值取最后那次。
            scheduleRateChangeReport()

        case .volume(let value):
            volume = value
            pushState()
            reportNow(.volumeChange)

        case .muted(let value):
            isMuted = value
            pushState()
            reportNow(.volumeChange)

        case .tracksChanged:
            refreshTracks()
            applyPreferredSubtitle()
            pushState()

        case .tracksValidated(let outcome):
            trackValidation = outcome

        case .ended:
            // 6.6:自然播完 → 直接 Stopped,位置用最终位置
            isEnded = true
            // 播完即释放显示器休眠断言(phase 停在 .playing,只能靠 isEnded 判)
            updateDisplaySleepAssertion()
            finishReporting(sendFinalProgress: false)
            // 没有片尾标记、也没赶上结束前的提示(比如直接拖到了最后)时,
            // 播完卡片同样按设置倒计时播下一集
            if autoPlayNext, upNextCountdown == nil { startUpNextCountdown() }

        case .failed(let engineFailure):
            failure = LoadFailure(engineFailure)
            // 内核失败要看得出「服务端回了什么」与「本机解不了什么」:
            // 连同能力表版本号落一条诊断(URL 经 `SecretRedactor` 脱敏)。
            // ⚠️ 会话还没建起来时没有流地址,不拿站点根冒充 —— 那条日志会把人带偏。
            if let session {
                NetworkDiagnostics.recordPlaybackFailure(
                    message: engineFailure.userMessage,
                    url: session.plan.url,
                    method: session.plan.method.rawValue,
                    directStreamURLProvided: session.mediaSource.directStreamUrl != nil
                )
            }        }
    }

    /// 读回轨道列表(第 7 节:设了轨要读回,不能假设设置即生效)。
    private func refreshTracks() {
        audioTracks = engine.audioTracks
        subtitleTracks = engine.subtitleTracks
        selectedAudioTrackID = engine.selectedAudioTrackID
        selectedSubtitleTrackID = engine.selectedSubtitleTrackID
    }

    /// 起播后按设置页的字幕模式挑一次字幕轨(`SubtitlePreference.startupChoice`)。
    /// 默认是「中文优先」:简体 → 繁体 → 未标变体的中文 → 保持内核默认。
    ///
    /// 只在轨道列表首次到达时做,且用户手动选过之后不再介入。
    /// ⛔ 不起 OSD、也不发 `SubtitleTrackChange`:这是起播时的默认值,不是一次
    /// 用户操作;选中的索引会由随后的首次 Progress 上报带上去。
    private func applyPreferredSubtitle() {
        guard !hasUserChosenSubtitle, !hasAppliedPreferredSubtitle else { return }
        let choice = SubtitlePreference.startupChoice(
            in: subtitleTracks, mode: container.preferences.subtitleMode)
        switch choice {
        case .leaveAlone:
            return
        case .off:
            applyPreferredSubtitle(id: nil)
        case .track(let id):
            applyPreferredSubtitle(id: id)
        }
    }

    private func applyPreferredSubtitle(id: Int?) {
        // 内核选中的正好就是想要的:不用改,标记完成即可
        guard id != selectedSubtitleTrackID else {
            hasAppliedPreferredSubtitle = true
            return
        }
        engine.selectSubtitleTrack(id)
        hasAppliedPreferredSubtitle = true
        // 与手动切轨一致地乐观更新;内核会在轨道变化时重推列表,那时按 `selected` 读回覆盖
        selectedSubtitleTrackID = id
    }

    /// 每个可信的位置之后评估一次:自动跳片头、开始 / 撤销下一集倒计时。
    private func evaluatePlaybackPrompts() {
        guard isPositionSettled, scrubPreviewSeconds == nil else { return }
        if autoSkipIntro, !didAutoSkipIntro, !isPaused, isSkipIntroAvailable {
            didAutoSkipIntro = true
            skipIntro()
            return
        }
        if isUpNextPromptVisible {
            if autoPlayNext, upNextCountdown == nil { startUpNextCountdown() }
        } else if upNextCountdown != nil, !isEnded {
            // 拖回到提示点之前:撤掉倒计时,之后再到提示点会重新开始
            stopUpNextCountdown()
        }
    }

    /// 倒计时按秒走;暂停期间停表(播完之后没有「暂停」可言,照走)。
    private func startUpNextCountdown() {
        guard nextEpisode != nil, !isUpNextDismissed else { return }
        upNextTask?.cancel()
        upNextCountdown = Metrics.upNextCountdown
        upNextTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let remaining = self.upNextCountdown else { return }
                if self.isPaused, !self.isEnded { continue }
                if remaining <= 1 {
                    self.playNextEpisode()
                    return
                }
                self.upNextCountdown = remaining - 1
            }
        }
    }

    private func stopUpNextCountdown() {
        upNextTask?.cancel()
        upNextTask = nil
        upNextCountdown = nil
    }

    private func flash(_ text: String, systemImage: String) {
        osd = PlayerOSD(text: text, systemImage: systemImage)
    }

    /// 查上一集 / 下一集:先在本季里找紧挨着的一集;已是本季首 / 末集就取
    /// 上一季的最后一集 / 下一季的第一集。
    /// 只用 ✅ 端点 `Shows/{Id}/Episodes` 与 `Shows/{Id}/Seasons`(API_CONTRACT.md 3.2)。
    private func loadAdjacentEpisodes() async {
        guard let seriesID = item.seriesID, let seasonID = item.seasonID else { return }
        let connection = container.connection(for: server)
        do {
            let episodes = try await connection.episodes(seriesID: seriesID, seasonID: seasonID)
            nextEpisode = NextEpisodeResolver.item(after: item.id, in: episodes)
            previousEpisode = NextEpisodeResolver.item(before: item.id, in: episodes)
            guard nextEpisode == nil || previousEpisode == nil else { return }

            let seasons = try await connection.seasons(seriesID: seriesID)
            if nextEpisode == nil, let nextSeason = NextEpisodeResolver.item(after: seasonID, in: seasons) {
                nextEpisode = try await connection
                    .episodes(seriesID: seriesID, seasonID: nextSeason.id)
                    .first
            }
            if previousEpisode == nil,
               let previousSeason = NextEpisodeResolver.item(before: seasonID, in: seasons) {
                previousEpisode = try await connection
                    .episodes(seriesID: seriesID, seasonID: previousSeason.id)
                    .last
            }
        } catch {
            // 上一集 / 下一集是附加功能:查不到只是不显示对应入口,不影响正在进行的播放,
            // 也不弹错误(播放页的错误位只留给播放本身)。已查到的那一个保留。
            return
        }
    }

    // MARK: - 内部:起播耗时

    private func markTimeline(_ stage: PlaybackTimeline.Stage) {
        let finished = timeline.mark(stage, elapsed: ContinuousClock.now - timelineStart)
        guard finished, let session else { return }
        NetworkDiagnostics.recordTiming(timeline.line(
            method: session.plan.method.rawValue,
            host: session.plan.url.host(),
            directStreamURLProvided: session.mediaSource.directStreamUrl != nil))
        // ⚠️ `main` 上这里还会附带一段 mpv 日志明细。本分支没有等价物
        // (文档第 3 节已把「失去 mpv 分级日志」列为接受的损失,排障用统计 overlay
        // 的 accessLog / errorLog 行代替)。
    }

    // MARK: - 内部:显示器休眠断言

    /// 按当前状态刷新断言(幂等,状态每次变化都可以调)。
    private func updateDisplaySleepAssertion() {
        displaySleep.setActive(PlaybackRules.shouldPreventDisplaySleep(
            phase: phase, isPaused: isPaused, isEnded: isEnded))
    }

    // MARK: - 内部:上报

    /// 5.1 的快照:位置 / 暂停 / 静音 / 音量 / 轨道索引 / 倍速。
    ///
    /// 位置是**绝对媒体位置**(已过 `PlaybackTimeBase`);轨道索引换算成 Emby 的
    /// `MediaStream.Index`(`StreamIndexMapper`);对不齐时为 nil,上报整键省略。
    /// 字幕关闭时同为 nil —— 不发 0,0 是一条真实轨道的索引。
    private var reportState: PlaybackReportState {
        PlaybackReportState(
            positionSeconds: positionSeconds,
            isPaused: isPaused,
            isMuted: isMuted,
            volume: volume,
            audioStreamIndex: selectedAudioTrackID.flatMap { embyStreamIndex(for: $0, in: audioTracks) },
            subtitleStreamIndex: selectedSubtitleTrackID.flatMap { embyStreamIndex(for: $0, in: subtitleTracks) },
            playbackRate: speed
        )
    }

    private func embyStreamIndex(for trackID: Int, in tracks: [PlaybackTrack]) -> Int? {
        guard let session else { return nil }
        return StreamIndexMapper.embyIndex(
            for: trackID,
            tracks: tracks,
            streams: session.mediaSource.mediaStreams,
            method: session.plan.method
        )
    }

    private func pushState() {
        let snapshot = reportState
        Task { await reporter.update(snapshot) }
    }

    private func reportNow(_ event: PlaybackEventName) {
        Task { await reporter.reportNow(eventName: event) }
    }

    /// 合并连续倍速变化的上报(拖滑块):停手 `Metrics.speedReportDelay` 后再发。
    private func scheduleRateChangeReport() {
        rateReportTask?.cancel()
        rateReportTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Metrics.speedReportDelay)) } catch { return }
            self?.rateReportTask = nil
            self?.reportNow(.playbackRateChange)
        }
    }

    private func beginReportingIfNeeded() {
        guard let session, !didBeginReporting else { return }
        didBeginReporting = true
        let context = PlaybackReportContext(
            itemID: item.id,
            mediaSourceID: session.plan.mediaSourceID,
            playSessionID: session.plan.playSessionID,
            method: session.plan.method
        )
        let snapshot = reportState
        Task { await reporter.begin(context: context, state: snapshot) }
    }

    private func finishReporting(sendFinalProgress: Bool) {
        let snapshot = reportState
        let previous = reportingFinishTask
        // 串在上一次收尾之后(自然播完后再关窗会先后调两次),
        // 保证 `waitUntilReportingFinished` 等的是最后一次 finish 之后的 drain。
        reportingFinishTask = Task { [reporter] in
            await previous?.value
            await reporter.finish(finalState: snapshot, sendFinalProgress: sendFinalProgress)
            await reporter.drain()
        }
    }

    /// 等本轮收尾上报(最终 Progress + Stopped)真正发完。
    /// 播放页关闭后,详情页据此再向服务端读续播位置(docs/PITFALLS.md Q22)。
    /// 从未开始收尾时立即返回。
    func waitUntilReportingFinished() async {
        await reportingFinishTask?.value
    }
}
