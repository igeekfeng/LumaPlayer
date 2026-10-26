import Foundation
import os

/// `LoadFailure` 也能表示「服务端给了响应但没有可播路径」
/// (这类失败要可解释,不能只显示“播放失败”)。
extension LoadFailure {
    init(_ error: PlaybackError) {
        self.init(message: error.userMessage, needsLogin: false)
    }
}

/// 播放页的状态机(会话、进度同步、轨道、seek 分派)。
///
/// 流程:`PlaybackSessionCoordinator` 取会话 → 经 `engineFactory` 建 `PlaybackEngine`
/// → 起事件泵 → `open` → `play` → 首帧后开始上报。
///
/// ⚠️ 与旧内核(libmpv)的两处结构性差别:
/// - **不再等「渲染上下文挂好」**:当前内核(Erika)的视频表面由 SDK 视图自驱,
///   `makeVideoSurface()` 返回现成视图交给 `PlayerSurfaceView` 上屏即可;
/// - **倍速 / 音量 / 静音没有读回事件**:内核不推这些值,`PlayerViewModel` 改为
///   乐观更新自己的状态(设了就是那个值),不再依赖读回校正。
@MainActor
@Observable
final class PlayerViewModel {
    private let container: AppContainer
    private let server: ServerProfile
    private let item: EmbyItem
    /// 上报出口(API_CONTRACT.md 5.4:所有上报经这一个 actor 串行)。
    private let reporter: PlaybackProgressReporter
    /// 播放期的显示器休眠断言。⛔ 不能指望播放器自己管:必须宿主自己持
    /// (手段见 `DisplaySleepAssertion`,判据见 `shouldPreventDisplaySleep`;GitHub issue #1)。
    private let displaySleep: any DisplaySleepInhibiting
    /// 建播放引擎的工厂。默认取组合根的 `makePlaybackEngine(upscaler:)`;测试注入假引擎。
    /// 超分档位由本类按设置页偏好决定后传入(与倍速 / 音量 / 字幕外观同一个来源)。
    /// `@MainActor`:`PlaybackEngine` 全程主线程,工厂也要在主线程上跑。
    private let engineFactory: @MainActor (PlayerUpscaler) throws -> any PlaybackEngine

    /// 视频层绑定用;为 nil 表示还没到建引擎的阶段(仍在取播放信息)
    private(set) var engine: (any PlaybackEngine)?
    private(set) var session: PlaybackSession?
    private(set) var failure: LoadFailure?
    /// 正在取 PlaybackInfo / 重新起流
    private(set) var isPreparing = true
    private(set) var phase: PlayerPhase = .idle
    private(set) var isPaused = false

    // MARK: - 进度与轨道

    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    /// 0–100(交给引擎时 /100 转成 0–1)
    private(set) var volume: Double = 100
    private(set) var isMuted = false
    private(set) var audioTracks: [PlayerTrack] = []
    private(set) var subtitleTracks: [PlayerTrack] = []
    private(set) var selectedAudioTrackID: Int64?
    /// nil = 字幕关闭
    private(set) var selectedSubtitleTrackID: Int64?
    /// 用户在本次播放里手动选过字幕:默认偏好不再介入
    private var hasUserChosenSubtitle = false
    /// 默认偏好已应用过(track-list 会被推多次,只挑一次)
    private var hasAppliedPreferredSubtitle = false
    /// 转码 seek 正在重新起流(4.5):与首次取播放信息区分开,便于 UI 给准话
    private(set) var isRestarting = false

    // MARK: - 体验打磨(倍速 / 缓冲 / 播完 / 下一集 / 屏显提示)

    /// 播放速率(乐观更新:内核不推倍速读回,设了就是那个值)。
    /// 「同一部剧沿用同一个倍速」的意图记在 `container.playbackSpeeds` 里,
    /// 新建引擎时由 `applyRememberedSpeed` 设回去。
    private(set) var speed: Double = 1

    /// 本次起播要用的倍速:这部剧记过就用它(优先级最高),没记过用设置页的
    /// 「默认倍速」,再没有才是 1×。
    ///
    /// 记的那个值跨集沿用、⛔ 不落 `UserDefaults`(见 `PlaybackSpeedStore`);
    /// 「默认倍速」是用户显式设的长期偏好,所以要留得住。
    /// 仅供测试与日志观察,播放决策在 `applyRememberedSpeed` 里。
    var startupSpeed: Double {
        container.playbackSpeeds.speed(for: item, on: server)
            ?? container.preferences.defaultSpeed
    }
    /// 播放中因缓存不足暂停(内核 `bufferingChanged`)
    private(set) var isBuffering = false
    /// 已自然播完(内核报 `.ended(.eof)`)。重播 / 重试时复位。
    private(set) var isEnded = false
    /// 剧集的下一集;不是剧集、已是最后一集或查询失败时为 nil。
    private(set) var nextEpisode: EmbyItem?
    /// 画面上的短暂提示(「1.25×」「字幕:中文」…,DesignTokens.swift「界面规则」)。
    /// 每次都是新 id,视图据此重新计时消失。
    private(set) var osd: PlayerOSD?

    /// 系统「正在播放」(控制中心)的倍速档位:那条命令只能给离散选项。
    /// 播放器内是连续调节(滑块 + 步进,`Metrics.speedRange`),不落在这几个值上。
    static let speedPresets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    // MARK: - 片头 / 下一集 / 统计 / 触控板拖动

    /// 剧集的上一集(系统「正在播放」的上一曲、⌘←);查找规则与下一集对称。
    private(set) var previousEpisode: EmbyItem?
    /// 当前源的片头片尾标记(API_CONTRACT.md 4.3.1);服务端没给就是 `.none`。
    private(set) var markers = PlaybackMarkers.none
    /// 「下一集」倒计时剩余秒数;nil = 没在倒计时
    private(set) var upNextCountdown: Int?
    /// 本次播放里用户点过「取消」:不再提示、不再自动播下一集
    private(set) var isUpNextDismissed = false
    /// 统计信息 overlay 是否打开(按 I 切换;只在本次播放内有效,不持久化)
    private(set) var showsStatistics = false
    private(set) var statistics: PlayerStatistics?
    /// 触控板横滑拖进度时的预览目标(秒);nil = 没在拖。松手才真正 seek ——
    /// 转码模式下一次 seek 就是一次重新起流,不能边滑边 seek。
    private(set) var scrubPreviewSeconds: Double?

    // MARK: - 播放偏好(设置页「播放」页,UserDefaults 持久化)

    /// 状态存在 `container.preferences` 里,这里是转发:
    /// 设置窗口与播放窗口必须看到同一份,否则菜单里的勾和设置页对不上。
    /// 进入片头区间时自动跳过。默认关:和 Plex / Infuse 一样先给按钮,
    /// 标记不准时自动跳会直接吃掉正片开头。
    var autoSkipIntro: Bool {
        get { container.preferences.autoSkipIntro }
        set { container.preferences.autoSkipIntro = newValue }
    }
    /// 片尾提示出现后倒计时自动播下一集。默认开(Plex / Netflix 的默认值),可在提示上取消。
    var autoPlayNext: Bool {
        get { container.preferences.autoPlayNext }
        set { container.preferences.autoPlayNext = newValue }
    }
    /// 播放窗口置顶(`NSWindow.level = .floating`)
    var floatsOnTop: Bool {
        get { container.preferences.floatsOnTop }
        set { container.preferences.floatsOnTop = newValue }
    }
    /// 前后跳转步长(秒),设置页可调
    var seekStep: Double { container.preferences.seekStep }
    /// 自动跳过片头每次播放只触发一次:用户跳过后又拖回片头,说明就是想看,不能再把人弹走
    /// (Infuse 的已知问题:自动跳转后反复触发,画面在片头终点来回闪)。
    private var didAutoSkipIntro = false
    /// 首个「可信」的位置是否已到达。DirectStream 续播时,内核在我们 seek 到
    /// 续播点之前会先报一次 0 附近的位置;若片头从 0 开始,拿这个值判片头会触发
    /// 自动跳过,把续播位置覆盖掉。到达续播点附近之前不评估片头 / 下一集。
    private var isPositionSettled = false
    private var upNextTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?

    /// 起播位置(秒)。来源有两个:打开时的恢复位置,以及转码 seek 的目标。
    private var startSeconds: Double
    /// DirectStream 的恢复位置只在首次进入 playing 时 seek 一次
    private var didApplyStartOffset = false
    private var didBeginReporting = false

    private var startTask: Task<Void, Never>?
    /// 最近一次 `finishReporting` 的任务(finish + drain),供关窗后等待
    private var reportingFinishTask: Task<Void, Never>?
    /// 合并后的倍速上报任务(拖滑块时只留最后一次)
    private var rateReportTask: Task<Void, Never>?
    /// 转码 seek 合并后的重新起流任务(连点时只留最后一次)
    private var seekRestartTask: Task<Void, Never>?
    /// 每次「重新起流 / 收尾」自增。合并任务用它判断自己是否已被作废。
    private var restartEpoch = 0

    /// 事件泵:把引擎的 pull 事件按节奏排空并投递给 `handle(_:generation:)`。
    private let pump = PlaybackEventPump()

    /// 播放会话代次。每次 `stop()` +1,用来丢弃上一轮引擎的迟到事件。
    ///
    /// 事件泵在 `Task` 里轮询引擎,旧实例在 `stop()` 前后提交的事件**必然**
    /// 晚于同步执行的 `retry()` 到达,不带代次号就会把上一轮的错误写到刚起来的
    /// 新会话上 —— 新的播放尝试还没发出任何请求就直接显示错误页。
    /// 与 CLAUDE.md 对播放上报的要求同源:异步乱序到达必须靠代次号丢弃。
    private var generation = 0

    init(
        container: AppContainer,
        server: ServerProfile,
        item: EmbyItem,
        startFromBeginning: Bool = false,
        reporter: PlaybackProgressReporter? = nil,
        displaySleep: (any DisplaySleepInhibiting)? = nil,
        engineFactory: (@MainActor (PlayerUpscaler) throws -> any PlaybackEngine)? = nil
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
        // 显示器休眠断言:App 里用真的 IOKit 断言,单测注入替身
        // (与 reporter 同一个理由:被测逻辑不该依赖系统资源的可用性)。
        self.displaySleep = displaySleep ?? DisplaySleepAssertion()
        // 引擎工厂:默认按设置页的超分偏好建真引擎;测试注入假引擎。
        // 闭包捕获 `container`,在**调用时**读偏好 —— 起播前改了设置能生效。
        self.engineFactory = engineFactory ?? { upscaler in
            try container.makePlaybackEngine(upscaler: upscaler)
        }
        // 恢复播放位置:`UserData.PlaybackPositionTicks` 是服务端记录的进度。
        // 为 nil / 为 0 即从 0 开始 —— 不猜「看过了多少」(8.1 禁止填假默认值)。
        // 「从头播放」显式忽略它。
        let resume = startFromBeginning ? 0 : item.userData?.playbackPositionTicks
            .flatMap { TickConverter.seconds(fromTicks: $0) } ?? 0
        self.startSeconds = Self.resumePosition(from: resume)
    }

    /// 续播起点:往回退 `Metrics.resumeRewind` 秒接上前情,不退到 0 以下。
    /// 没有续播位置(0)时原样返回 0。
    static func resumePosition(from saved: Double) -> Double {
        guard saved > 0 else { return 0 }
        return max(0, saved - Metrics.resumeRewind)
    }

    /// 起播位置(秒);仅供测试与日志观察,不参与播放决策。
    var resumeStartSeconds: Double { startSeconds }

    /// 是否正持有「阻止显示器休眠」的断言(仅供测试与日志观察;`pmset -g assertions`
    /// 是另一个更权威的观察点,见 GitHub issue #1 的验收标准)。
    var isPreventingDisplaySleep: Bool { displaySleep.isHeld }

    /// 正在播的项(标题栏 / 系统「正在播放」用)
    var playingItem: EmbyItem { item }
    var playingServer: ServerProfile { server }

    private var nextEpisodeTask: Task<Void, Never>?

    // MARK: - 生命周期

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

    /// 重试:引擎实例不可复用(一实例一 URL),所以必须整体重建,不能只是再 open 一次。
    func retry() {
        stop()
        failure = nil
        session = nil
        isPreparing = true
        phase = .idle
        isPaused = false
        isRestarting = false
        isEnded = false
        // 新引擎 = 新上报会话:不复位的话,播放中途出错再重试,
        // 新会话既不会补 seek 到起播位置,也永远不会发 Playing。
        didApplyStartOffset = false
        didBeginReporting = false
        isPositionSettled = false
        start()
    }

    /// 播完后从头再播。内核播完即卸载文件,所以不是 seek 到 0,
    /// 而是按新会话整体重建(一实例一 URL)。
    func replay() {
        startSeconds = 0
        positionSeconds = 0
        // 重看一遍 = 全新的一次观看:片头可以再自动跳、下一集可以再提示
        didAutoSkipIntro = false
        isUpNextDismissed = false
        retry()
    }

    /// 收尾:先按 API_CONTRACT.md 5.4 结束上报会话(最终 Progress +
    /// Stopped),再拆引擎。关窗、切媒体、转码 seek 都走这里。
    func stop() {
        finishReporting(sendFinalProgress: true)
        // 收尾这一刻就把显示器休眠还回去:关窗 / 切媒体 / 转码重新起流都走这里。
        // 这里必须是**无条件释放**而不是按 phase 重算 —— stop() 返回后调用方
        // (retry / restartStream)才把 phase 置回 .idle,重算会把断言又拿一份。
        displaySleep.setActive(false)
        // 先递增:此后旧引擎再投递的事件代次都对不上,一律丢弃。
        generation &+= 1
        startTask?.cancel()
        startTask = nil
        statisticsTask?.cancel()
        statisticsTask = nil
        // 待发的倍速上报属于已经结束的会话:Stopped 之前的最终 Progress 会带上倍速
        rateReportTask?.cancel()
        rateReportTask = nil
        // 待起流的合并 seek 同样作废:关窗 / 切媒体后不能再自己起流。
        // 代次 +1 是给「已经过了 sleep、cancel 对它无效」的那个任务兜底。
        // `restartStream` 内部也会 stop(),那属于新一轮,不能在这里取消自己。
        seekRestartTask?.cancel()
        seekRestartTask = nil
        restartEpoch &+= 1
        isRestarting = false
        stopUpNextCountdown()
        scrubPreviewSeconds = nil
        pump.stop()
        engine?.close()
        engine = nil
    }

    // MARK: - 控制

    func togglePlayPause() {
        guard let engine else { return }
        do {
            if isPaused {
                try engine.play()
            } else {
                try engine.pause()
            }
        } catch {
            failure = LoadFailure(message: "播放控制失败:\(error)")
        }
    }

    /// 倍速:连续值,夹在 `Metrics.speedRange` 内,不要求落在某个档位上。
    /// 转码流同样由内核在客户端变速,服务端不需要知道。
    ///
    /// ⚠️ 内核不推倍速读回,所以这里是**乐观更新**:设了就认为生效。
    func setSpeed(_ value: Double) {
        let target = Self.clampedSpeed(value)
        guard target != speed else { return }
        do { try engine?.setRate(target) } catch { return }
        speed = target
        // 记住用户的选择:同一部剧的下一集、转码 seek 重新起流都从它起播。
        // 引擎还没建起来(仍在取播放信息)时照样记 —— 那个值会在新引擎上生效。
        container.playbackSpeeds.remember(target, for: item, on: server)
        pushState()
        // 5.2 要求改倍速立即上报,但滑块是连续的(0.05 一跳),一次拖动
        // 就是十几个请求 —— 真实服务器纪律要求低频,所以合并成一次:
        // 停手 `Metrics.speedReportDelay` 后再发,值取最后那次。
        // `pushState()` 每次都走,10 秒一次的 Progress 里倍速不会缺。
        // (会话未开始前 `reportNow` 是空操作,见 `PlaybackProgressReporter`。)
        scheduleRateChangeReport()
        flash(Self.speedText(target), systemImage: "gauge.with.dots.needle.67percent")
    }

    /// 新建的引擎一律是 1×,把起播倍速设回去(KNOWN_ISSUES 旧条目
    /// 「倍速在新建播放器后回到 1×」)。换集、重新起流、重试都走这里。
    /// 值来自 `startupSpeed`:这部剧记过的优先,否则是设置页的默认倍速。
    private func applyRememberedSpeed(to engine: any PlaybackEngine) {
        let startup = startupSpeed
        speed = startup
        guard startup != 1 else { return }
        do {
            try engine.setRate(startup)
        } catch {
            // 设不回去只是本集退回 1×,不影响能不能播,所以不挂到 failure 上;
            // 但也不能一声不响 —— 记下来,免得以后排障时以为「倍速本来就该保留」。
            speed = 1
            let reason = String(describing: error)
            Self.logger.error(
                "倍速 \(startup, privacy: .public)× 设回新建引擎失败,本集按 1× 起播:\(reason, privacy: .public)")
        }
    }

    /// 新建的引擎音量是满的,把设置页的「默认音量」设上去。
    private func applyDefaultVolume(to engine: any PlaybackEngine) {
        let target = container.preferences.defaultVolume
        volume = target
        guard target != Metrics.defaultVolume else { return }
        do {
            try engine.setVolume(target / 100)
        } catch {
            volume = Metrics.defaultVolume
            let reason = String(describing: error)
            Self.logger.error(
                "默认音量 \(target, privacy: .public) 设到新建引擎失败:\(reason, privacy: .public)")
        }
    }

    // MARK: 字幕外观

    /// 把当前的字幕外观偏好套到引擎上。设置窗口里改了外观之后由播放窗口调用
    /// (`PlayerWindowView` 的 onChange),新建引擎时也走这里。
    func applySubtitleStyle() {
        guard let engine else { return }
        applySubtitleStyle(container.subtitleStyles.style, to: engine)
    }

    private func applySubtitleStyle(_ style: SubtitleStyle, to engine: any PlaybackEngine) {
        do {
            try engine.setSubtitleStyle(style.engineStyle)
        } catch {
            // 外观设不上不影响能不能播,不挂到 failure 上;但要留痕,
            // 否则「设置改了没反应」无从查起。
            Self.logger.error("字幕外观设置失败: \(String(describing: error), privacy: .public)")
        }
    }

    /// 按步长加 / 减(`[` `]` 与倍速浮层的 ±);已经贴着区间端点就不动。
    func stepSpeed(up: Bool, step: Double = Metrics.speedKeyStep) {
        let next = Self.steppedSpeed(from: speed, up: up, step: step)
        guard next != Self.clampedSpeed(speed) else { return }
        setSpeed(next)
    }

    /// 走一步之后的倍速:加减 `step` 再夹到区间(端点处返回原值)。
    static func steppedSpeed(from speed: Double, up: Bool, step: Double) -> Double {
        clampedSpeed(speed + (up ? step : -step))
    }

    /// 夹到倍速区间(定义见 `Metrics.clampedSpeed`)。
    static func clampedSpeed(_ value: Double) -> Double { Metrics.clampedSpeed(value) }

    static func speedText(_ value: Double) -> String {
        value == value.rounded()
            ? "\(Int(value))×"
            : "\(value.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    /// 拖动到指定秒数。
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
            do {
                try engine?.seek(to: target)
            } catch {
                failure = LoadFailure(message: "拖动失败:\(error)")
                return
            }
            // 5.2:拖动结束立即上报,不等 10 秒定时器
            pushState()
            reportNow(.timeUpdate)
        } else {
            scheduleRestartStream(at: target)
        }
    }

    /// 转码 seek 的合并起流:等 `seekRestartMergeDelay` 内没有新的 seek 再起流。
    ///
    /// ⛔ 拖动进度条**也要走合并**:拖动松手只触发一次 seek,合并不影响它;
    /// 但转码下拖动的 `onChanged` 期间 `displayed` 已经变了,若同时有残留的
    /// 待执行任务,两者会以不同的目标位置起流,这里统一收敛到最后一次。
    private func scheduleRestartStream(at seconds: Double) {
        seekRestartTask?.cancel()
        isRestarting = true
        restartEpoch &+= 1
        let epoch = restartEpoch
        seekRestartTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(
                    Int(Metrics.seekRestartMergeDelay * 1000)))
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

    /// 方向键:相对当前位置快进 / 快退(PlayerCommands.swift 的快捷键表)。
    func skip(by delta: Double) {
        seek(to: positionSeconds + delta)
        let seconds = Int(abs(delta))
        flash(delta < 0 ? "后退 \(seconds) 秒" : "前进 \(seconds) 秒",
              systemImage: delta < 0 ? "gobackward" : "goforward")
    }

    /// 设音量(0–100)。静音是独立开关(`isMuted`),调音量本身不解静音。
    func setVolume(_ value: Double) {
        let target = max(0, min(100, value.isFinite ? value : volume))
        volume = target
        applyVolumeToEngine()
        pushState()
        reportNow(.volumeChange)
    }

    /// 键盘调音量(↑ ↓,步长 `Metrics.volumeStep`)。调音量顺带解除静音 ——
    /// 静音时按 ↑ 却听不到声音,用户只会以为按键没生效。
    func adjustVolume(by delta: Double) {
        let target = max(0, min(100, volume + delta))
        isMuted = false
        volume = target
        applyVolumeToEngine()
        pushState()
        reportNow(.volumeChange)
        flash("音量 \(Int(target.rounded()))", systemImage: Self.volumeSymbol(target, muted: false))
    }

    /// 静音 / 取消静音。内核没有静音开关,用「音量置 0 / 还原」实现 ——
    /// `volume` 本身保持不变,所以取消静音能回到原音量。
    func toggleMute() {
        isMuted.toggle()
        applyVolumeToEngine()
        pushState()
        reportNow(.volumeChange)
        flash(isMuted ? "静音" : "取消静音",
              systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }

    /// 把当前音量(考虑静音)写到引擎上。音量失败不打断播放。
    private func applyVolumeToEngine() {
        guard let engine else { return }
        do { try engine.setVolume(isMuted ? 0 : volume / 100) } catch { /* 音量失败不打断播放 */ }
    }

    static func volumeSymbol(_ volume: Double, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 34 { return "speaker.wave.1.fill" }
        if volume < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// 选音轨(设引擎的当前音轨)。
    func selectAudioTrack(_ id: Int64) {
        selectedAudioTrackID = id
        do { try engine?.selectAudioTrack(id: id) } catch { return }
        pushState()
        reportNow(.audioTrackChange)
        if let track = audioTracks.first(where: { $0.id == id }) {
            flash("音轨:\(track.displayName)", systemImage: "waveform")
        }
    }

    /// 选字幕轨;nil = 关字幕。
    ///
    /// 用户在这里做过一次选择之后,起播的默认偏好就让位
    /// (`applyPreferredSubtitle()` 不再覆盖),否则切轨后引擎回推的
    /// 轨道列表会把用户刚选的顶掉。
    func selectSubtitleTrack(_ id: Int64?) {
        hasUserChosenSubtitle = true
        selectedSubtitleTrackID = id
        do { try engine?.selectSubtitleTrack(id: id) } catch { return }
        pushState()
        reportNow(.subtitleTrackChange)
        let name = id.flatMap { id in subtitleTracks.first { $0.id == id }?.displayName }
        flash("字幕:\(name ?? "关闭")", systemImage: "captions.bubble")
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

    /// 把起播的字幕选择写到引擎上;nil = 关字幕。
    private func applyPreferredSubtitle(id: Int64?) {
        // 引擎选中的正好就是想要的:不用写,标记完成即可
        guard id != selectedSubtitleTrackID else {
            hasAppliedPreferredSubtitle = true
            return
        }
        do {
            try engine?.selectSubtitleTrack(id: id)
            hasAppliedPreferredSubtitle = true
            // 与手动切轨一致地乐观更新;引擎会在轨道变化时重推轨道列表,
            // 那时按 `selected` 读回覆盖 —— 设不上也不会一直显示错的值。
            selectedSubtitleTrackID = id
        } catch {
            // 设不上就保持原状:引擎下次重推轨道列表时会再判一次
        }
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
            startStatisticsRefresh()
            refreshStatistics()
        } else {
            statisticsTask?.cancel()
            statisticsTask = nil
            statistics = nil
        }
    }

    /// 打开统计 overlay 后低频轮询引擎(`Metrics.statisticsRefreshInterval`)。
    /// 关掉 overlay 就停表 —— 统计是排障用,不该常驻打扰。
    private func startStatisticsRefresh() {
        statisticsTask?.cancel()
        statisticsTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(Metrics.statisticsRefreshInterval)) } catch { return }
                guard let self, self.showsStatistics else { return }
                self.refreshStatistics()
            }
        }
    }

    private func refreshStatistics() {
        guard let engine, showsStatistics else { return }
        do {
            statistics = PlayerStatistics(stats: try engine.stats(), session: session)
        } catch {
            // 读统计失败只影响 overlay,不打断播放;留痕便于排障。
            Self.logger.error("读取播放统计失败: \(String(describing: error), privacy: .public)")
        }
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

    // MARK: - 内部

    /// 起播耗时(见 `PlaybackTimeline`);`start()` 时复位,出第一帧后写一行 TIMING
    private var timeline = PlaybackTimeline()
    private var timelineStart = ContinuousClock.now

    private func markTimeline(_ stage: PlaybackTimeline.Stage) {
        let finished = timeline.mark(stage, elapsed: ContinuousClock.now - timelineStart)
        guard finished, let session else { return }
        NetworkDiagnostics.recordTiming(timeline.line(
            method: session.plan.method.rawValue,
            host: session.plan.url.host(),
            directStreamURLProvided: session.mediaSource.directStreamUrl != nil))
    }

    private func prepareAndLoad() async {
        do {
            let coordinator = PlaybackSessionCoordinator(
                connection: container.connection(for: server),
                itemID: item.id
            )
            var prepared = try await coordinator.makeSession()
            try Task.checkCancellation()
            // 转码 + 非零起播:4.5 规定服务端从 StartTimeTicks 处起流。
            // 之所以「先取一次再带参数重取」,是因为 StartTimeTicks 同时是
            // 服务端的决策输入 —— 一上来就带值可能把本来能 DirectStream 的
            // 文件推去转码;确认为转码之后重取就没有这个顾虑。
            if prepared.plan.method == .transcode, startSeconds > 0 {
                prepared = try await coordinator.makeSession(
                    startTimeTicks: TickConverter.ticks(fromSeconds: startSeconds))
                try Task.checkCancellation()
            }
            session = prepared
            markTimeline(.playbackInfo)
            markers = PlaybackMarkers(chapters: prepared.mediaSource.chapters)

            // 建引擎(按设置页的超分偏好)。初始化失败会抛错,由下面的 catch 兜住
            // 转成「播放器启动失败」文案 —— 不在这里静默放过。
            let engine = try engineFactory(container.preferences.upscaler)

            // 先让视图把引擎的视频表面上屏,再起事件泵、open、play。
            // 事件泵闭包捕获当前代次,旧引擎的迟到事件会被 handle 丢弃。
            let generation = self.generation
            pump.start(
                engine: engine,
                onEvent: { [weak self] event in
                    self?.handle(event, generation: generation)
                },
                onFailure: { [weak self] error in
                    self?.handlePumpFailure(error, generation: generation)
                }
            )
            self.engine = engine

            try engine.open(url: prepared.plan.url, headers: prepared.plan.headers)
            // open 之后、play 之前设置起播偏好(倍速 / 默认音量 / 字幕外观 / 超分)
            applyRememberedSpeed(to: engine)
            applyDefaultVolume(to: engine)
            applySubtitleStyle(container.subtitleStyles.style, to: engine)
            try engine.play()

            isPreparing = false
            isRestarting = false
        } catch is CancellationError {
            return
        } catch let error as EmbyAPIError {
            if error == .cancelled { return }
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

    /// 引擎事件泵读取失败(`pollEvent()` 抛错)。相位不变时的兜底错误通道。
    private func handlePumpFailure(_ error: PlayerError, generation: Int) {
        guard generation == self.generation, failure == nil else { return }
        failure = LoadFailure(message: "播放器内部错误:\(error.message)")
    }

    /// 倍速设不回新建引擎时的排障出口(与 `DisplaySleepAssertion` 同一个子系统)。
    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "playback")

    /// 转码 seek 的重新起流:结束旧上报会话 → 拆掉引擎(连接断开即停流)
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

    // MARK: - 显示器休眠断言(播放期不息屏)

    /// 播放期是否该阻止显示器休眠。
    ///
    /// 语义是「正在播放才抑制,暂停 / 播完 / 加载 / 失败 / 拆引擎都还给系统」。
    ///
    /// 三个判据各有各的必要性:
    /// - `phase == .playing`:暂停会变成 `.paused`,加载是 `.loading`,失败是 `.failed`;
    /// - `!isPaused`:起播前就按了暂停时,phase 仍会随「就绪」变成 `.playing`
    ///   (内核先报文件就绪、再报 pause),只看 phase 会为「暂停中的画面」占着断言;
    /// - `!isEnded`:播完时 phase 可能停在 `.playing`,不看这个就会让播完卡片一直占着断言。
    static func shouldPreventDisplaySleep(
        phase: PlayerPhase, isPaused: Bool, isEnded: Bool
    ) -> Bool {
        phase == .playing && !isPaused && !isEnded
    }

    /// 按当前状态刷新断言(幂等,状态每次变化都可以调)。
    private func updateDisplaySleepAssertion() {
        displaySleep.setActive(Self.shouldPreventDisplaySleep(
            phase: phase, isPaused: isPaused, isEnded: isEnded))
    }

    // MARK: - 上报

    /// 5.1 的快照:位置 / 暂停 / 静音 / 音量 / 轨道索引 / 倍速。
    ///
    /// 轨道索引换算成 Emby 的 `MediaStream.Index`(`StreamIndexMapper`,
    /// docs/PITFALLS.md Q21);对不齐时为 nil,上报整键省略。
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

    private func embyStreamIndex(for trackID: Int64, in tracks: [PlayerTrack]) -> Int? {
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

    /// 合并连续倍速变化的上报(拖滑块),见 `.speed` 事件处的说明。
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

    // MARK: - 事件

    /// 引擎事件入口。`generation` 是**发出这条事件的引擎实例**建立时的代次,
    /// 与当前代次不符即来自已被 `stop()` 拆掉的上一轮,直接丢弃。
    /// (`internal` 而非 `private`:测试要直接验这条门。)
    func handle(_ event: PlayerEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .phaseChanged(let newPhase):
            phase = newPhase
            updateDisplaySleepAssertion()
            if newPhase == .playing {
                markTimeline(.playing)
                // DirectStream 的恢复位置:服务端吐的是整份文件,
                // 偏移只能由客户端 seek(转码在起流时就带了 StartTimeTicks)
                if !didApplyStartOffset {
                    didApplyStartOffset = true
                    if startSeconds > 0, session?.plan.method == .directStream {
                        do {
                            try engine?.seek(to: startSeconds)
                            positionSeconds = startSeconds
                        } catch {
                            // 恢复位置失败不打断播放:流本身是好的,只是从头开始播。
                            // 等不到续播点了,直接认定位置可信,否则片头 / 下一集永远不评估。
                            isPositionSettled = true
                        }
                    }
                }
                beginReportingIfNeeded()
            }

        case .position(let value):
            markTimeline(.firstFrame)
            positionSeconds = value
            pushState()
            if !isPositionSettled {
                isPositionSettled = Self.isSettledPosition(
                    value, startSeconds: startSeconds, method: session?.plan.method)
            }
            evaluatePlaybackPrompts()

        case .duration(let value):
            durationSeconds = value

        case .paused(let paused):
            isPaused = paused
            updateDisplaySleepAssertion()
            // 5.2:暂停 / 恢复立即上报
            pushState()
            reportNow(paused ? .pause : .unpause)

        case .buffering(let value):
            isBuffering = value

        case .ended(let reason):
            handleEnd(reason)

        case .tracksChanged(let tracks):
            audioTracks = tracks.filter { $0.kind == .audio }
            subtitleTracks = tracks.filter { $0.kind == .subtitle }
            // 读回验证:轨道列表的 `selected` 就是读回结果,菜单勾选状态据此刷新。
            selectedAudioTrackID = audioTracks.first { $0.selected }?.id
            selectedSubtitleTrackID = subtitleTracks.first { $0.selected }?.id
            applyPreferredSubtitle()
            pushState()

        case .trackSelectionChanged(let audio, let subtitle):
            selectedAudioTrackID = audio
            selectedSubtitleTrackID = subtitle
            pushState()

        case .surfaceAttached:
            // 视频表面挂上了:起播时间线记一笔(替代旧内核的 GL 就绪)
            markTimeline(.surfaceReady)

        case .error(let error):
            // 提示性错误(相位不变);真正的失败由 `.ended(.error)` 处理。
            Self.logger.error("引擎错误: \(error.message, privacy: .public)")
        }
    }

    /// 播放结束的处理:自然播完 / 我们主动停止 / 失败。
    private func handleEnd(_ reason: PlayerEndReason) {
        switch reason {
        case .eof:
            // 6.6:自然播完 → 直接 Stopped,位置用最终位置
            isEnded = true
            // 播完即释放显示器休眠断言(phase 可能停在 .playing,只能靠 isEnded 判)
            updateDisplaySleepAssertion()
            finishReporting(sendFinalProgress: false)
            // 没有片尾标记、也没赶上结束前的提示(比如直接拖到了最后)时,
            // 播完卡片同样按设置倒计时播下一集
            if autoPlayNext, upNextCountdown == nil { startUpNextCountdown() }

        case .stopped:
            // 我们自己发起的停止(关窗 / 切媒体 / 转码重新起流):收尾由 stop() 负责,
            // 这里什么都不做,免得把已在收尾的会话又收一次。
            break

        case .error(let message):
            // 引擎侧的失败(拉流 401 / 解码失败 / 容器不支持)都走这里;
            // 文案要能区分「服务端没给可播路径」(PlaybackError)与
            // 「给了但播不起来」(本分支)。
            failure = LoadFailure(message: "播放失败:\(message)")
            recordPlaybackFailure(message)
        }
    }

    /// 把播放失败连同上下文落诊断日志,并补一次只读探测。
    ///
    /// 引擎看不到 HTTP 状态与响应体(收到的是媒体 / HTML / JSON 错误页),所以失败时
    /// 对同一个播放 URL 补一次 `Range` 探测,把状态码 / Content-Type / 响应体开头
    /// 脱敏后记下来(见 `PlaybackFailureProbe`,每次失败至多一次)。
    private func recordPlaybackFailure(_ message: String) {
        guard let session else { return }
        NetworkDiagnostics.recordPlaybackFailure(
            message: message,
            url: session.plan.url,
            method: session.plan.method.rawValue,
            directStreamURLProvided: session.mediaSource.directStreamUrl != nil
        )
        recordEngineLogs()
        let url = session.plan.url
        let headers = session.plan.headers
        Task { await PlaybackFailureProbe.run(url: url, headers: headers) }
    }

    /// 附上内核自己的日志(本次 open 以来 warn 及以上,内核已脱敏)。
    /// 引擎没建起来就没有可读的日志,`PLAYBACK` 那一行已足够。
    private func recordEngineLogs() {
        guard let engine else { return }
        do {
            NetworkDiagnostics.recordEngineLogs(try engine.diagnosticLogs())
        } catch {
            NetworkDiagnostics.recordEngineLogsUnavailable(String(describing: error))
        }
    }

    /// 位置是否已可信(见 `isPositionSettled`)。
    /// 只有 DirectStream + 非零续播点才需要等:客户端 seek 之前内核报的是文件开头。
    /// 转码流从 `StartTimeTicks` 处起流,没有这一步客户端 seek。
    static func isSettledPosition(_ value: Double, startSeconds: Double, method: PlaybackMethod?) -> Bool {
        guard startSeconds > 0, method == .directStream else { return true }
        return abs(value - startSeconds) < settledPositionTolerance
    }

    /// 判定「已到续播点附近」的容差(秒)。seek 落点误差很小,
    /// 3 秒足够覆盖首个位置的延迟,又不会把文件开头误判为已就位。
    private static let settledPositionTolerance: Double = 3
}
