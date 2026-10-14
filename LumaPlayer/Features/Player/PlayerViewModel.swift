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
/// 流程:`PlaybackSessionCoordinator` 取会话 → 建 `MPVPlayer` →
/// **等 GL 渲染上下文挂接** → `load(url:headers:)` → 首帧后开始上报。
///
/// 最后一步的等待不是可选的:render.h:32-34 / 113-115 要求渲染上下文
/// 先于播放建立,否则 `vo=libmpv` 的视频初始化会失败或退化成自建窗口的 VO。
/// 开发期的渲染 spike 就吃过这个亏(抢在 VO 初始化之前 loadfile)。
@MainActor
@Observable
final class PlayerViewModel {
    private let container: AppContainer
    /// 本次要播的内容(含来源身份 —— Emby / 百度网盘)
    private let request: PlaybackRequest
    /// Emby 来源才有;百度来源下为 nil
    private var server: ServerProfile? { request.embyServer }
    private var item: EmbyItem? { request.embyItem }
    /// 会话准备(按来源装好:Emby 过决策器、百度过播放映射)。
    /// ⛔ 播放页只认这个协议 —— 新增来源时改的是组合根,不是这里。
    private let preparer: any PlaybackSessionPreparing
    /// 进度出口(Emby → 服务端上报;百度 → 本地续播库,API_CONTRACT.md 5.4)。
    private let reporter: any PlaybackReporting
    /// 播放期的显示器休眠断言。⛔ 不能指望 mpv 的 `stop-screensaver`:
    /// `vo=libmpv` 下它不生效,必须宿主自己持(手段见 `DisplaySleepAssertion`,
    /// 判据见 `shouldPreventDisplaySleep`;GitHub issue #1)。
    private let displaySleep: any DisplaySleepInhibiting

    /// 视频层绑定用;为 nil 表示还没到建播放器的阶段(仍在取播放信息)
    private(set) var player: MPVPlayer?
    private(set) var session: PlaybackSession?
    private(set) var failure: LoadFailure?
    /// 正在取 PlaybackInfo / 等 GL 挂接 / 重新起流
    private(set) var isPreparing = true
    private(set) var phase: MPVPlayerPhase = .idle
    private(set) var isPaused = false

    // MARK: - 进度与轨道

    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    /// 0–100(mpv 的 `volume`)
    private(set) var volume: Double = 100
    private(set) var isMuted = false
    private(set) var audioTracks: [MPVTrack] = []
    private(set) var subtitleTracks: [MPVTrack] = []
    private(set) var selectedAudioTrackID: Int?
    /// nil = 字幕关闭(mpv 的 `sid = no`)
    private(set) var selectedSubtitleTrackID: Int?
    /// 用户在本次播放里手动选过字幕:默认偏好不再介入
    private var hasUserChosenSubtitle = false
    /// 默认偏好已应用过(track-list 会被推多次,只挑一次)
    private var hasAppliedPreferredSubtitle = false
    /// 转码 seek 正在重新起流(4.5):与首次取播放信息区分开,便于 UI 给准话
    private(set) var isRestarting = false

    // MARK: - 字幕延迟(MPV_INTEGRATION.md 7.1)

    /// 字幕延迟(秒,mpv `sub-delay` 读回值):正 = 字幕延后出现,负 = 提前。
    private(set) var subtitleDelay: Double = 0
    /// 用户要的字幕延迟。与 `subtitleDelay` 分开存,原因有二:
    /// - 新建的 mpv 一律是 0,转码 seek 重新起流 / 重试都要把它设回去;
    /// - 连按 Z / X 时读回值还没回来,按读回值步进会丢步。
    ///
    /// 只活在这一集里:延迟是「这个文件的字幕和画面差多少」,换一集(新 ViewModel)
    /// 就是另一个文件,⛔ 不跨集沿用、不持久化 —— 与倍速的「同一部剧沿用」不同。
    private var requestedSubtitleDelay: Double = 0

    // MARK: - 体验打磨(倍速 / 缓冲 / 播完 / 下一集 / 屏显提示)

    /// 播放速率(mpv `speed` 读回值,不是设置值)。
    /// 「同一部剧沿用同一个倍速」的意图记在 `container.playbackSpeeds` 里,
    /// 新建 mpv 时由 `applyRememberedSpeed` 设回去。
    private(set) var speed: Double = 1

    /// 本次播放「算哪一部剧」的倍速键 —— 来源无关,由来源各自给出口径
    /// (Emby 是 `SeriesId`;百度是剧目录,不是剧时退化成 `fs_id`)。
    ///
    /// 百度那一路要靠 `episodeQueue` 才知道「这是一部剧的一集」,所以它在**起播前**
    /// 就必须有值 —— 队列由浏览页装配后随请求带进来(见 `PlaybackRequest.episodeQueue`),
    /// ⛔ 不是等列完网盘才有。
    private var speedScope: PlaybackSpeedScope {
        switch request.source {
        case .emby(let server, let item):
            return .emby(serverID: server.id, item: item)
        case .baiduPan(let file):
            return .baiduPan(file: file, isEpisodeSeries: episodeQueue != nil)
        }
    }

    /// 本次起播要用的倍速:这部剧记过就用它(优先级最高),没记过用设置页的
    /// 「默认倍速」,再没有才是 1×。
    ///
    /// 记的那个值跨集沿用、⛔ 不落 `UserDefaults`(见 `PlaybackSpeedStore`);
    /// 「默认倍速」是用户显式设的长期偏好,所以要留得住。
    /// 仅供测试与日志观察,播放决策在 `applyRememberedSpeed` 里。
    var startupSpeed: Double {
        container.playbackSpeeds.speed(for: speedScope) ?? container.preferences.defaultSpeed
    }
    /// 播放中因缓存不足暂停(mpv `paused-for-cache`)
    private(set) var isBuffering = false
    /// 已自然播完(`end-file` reason = eof)。重播 / 重试时复位。
    private(set) var isEnded = false
    /// 本次播放可切换的剧集队列(上一集 / 下一集 / 选集面板的唯一数据源)。
    ///
    /// 来源有二,都在 `init` / `loadEpisodeQueue` 里定下:
    /// - 请求自带(百度由浏览页用**当前目录已列条目**装配;换集时原样带过来);
    /// - Emby 由本页查当前季的分集。
    /// nil = 不是剧集 / 没有兄弟集(电影、单条视频、百度「继续观看」卡片)。
    private(set) var episodeQueue: EpisodeQueue?
    /// 剧集的下一集;不是剧集、已是最后一集、或定位不到时为 nil。
    /// Emby 在队列边界处会再补一次跨季查询(下一季的第一集)。
    private(set) var nextEpisode: PlaybackEpisode?
    /// 画面上的短暂提示(「1.25×」「字幕:中文」…,DesignTokens.swift「界面规则」)。
    /// 每次都是新 id,视图据此重新计时消失。
    private(set) var osd: PlayerOSD?

    /// 系统「正在播放」(控制中心)的倍速档位:那条命令只能给离散选项。
    /// 播放器内是连续调节(滑块 + 步进,`Metrics.speedRange`),不落在这几个值上。
    static let speedPresets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    // MARK: - 片头 / 下一集 / 缓冲 / 统计 / 触控板拖动

    /// 剧集的上一集(系统「正在播放」的上一曲、⌘←);查找规则与下一集对称。
    /// Emby 在队列边界处会再补一次跨季查询(上一季的最后一集)。
    private(set) var previousEpisode: PlaybackEpisode?
    /// 选集面板的成员(有序)。当前集由 `currentEpisodeID` 标出;不足两集时面板不出现。
    var episodes: [PlaybackEpisode] { episodeQueue?.episodes ?? [] }
    /// 当前这一集的来源内 id(选集面板高亮用)。
    var currentEpisodeID: String? { episodeQueue?.current?.id }
    /// 当前源的片头片尾标记(API_CONTRACT.md 4.3.1);服务端没给、用户也没手动标就是 `.none`。
    ///
    /// ⚠️ 这是**最终**标记 = 服务端标记(`serverMarkers`)与用户手动标注(`manualMarkers`)
    /// 合并后的结果,手动优先 —— 由 `refreshMarkers()` 算,⛔ 不要直接写它。
    private(set) var markers = PlaybackMarkers.none
    /// 服务端 `Chapters` 解析出来的原始标记(合并前)
    private var serverMarkers = PlaybackMarkers.none
    /// 用户手动标注(同一部剧共用;起播时从本地库读回)。nil = 没标过。
    private var manualMarkers: ManualMarkers?
    /// 「下一集」倒计时剩余秒数;nil = 没在倒计时
    private(set) var upNextCountdown: Int?
    /// 本次播放里用户点过「取消」:不再提示、不再自动播下一集
    private(set) var isUpNextDismissed = false
    /// 已缓存到的位置(秒,mpv `demuxer-cache-time`),进度条上画浅色段用
    private(set) var bufferedUntilSeconds: Double?
    /// 缓冲进度 0–100(mpv `cache-buffering-state`),只在缓冲中轮询
    private(set) var bufferingPercent: Int?
    /// 下载速度(字节/秒,mpv `cache-speed`),只在缓冲中轮询
    private(set) var cacheSpeedBytesPerSecond: Double?
    /// 统计信息 overlay 是否打开(按 I 切换;只在本次播放内有效,不持久化)
    private(set) var showsStatistics = false
    private(set) var statistics: PlayerStatistics?
    /// 触控板横滑拖进度时的预览目标(秒);nil = 没在拖。松手才真正 seek ——
    /// 转码模式下一次 seek 就是一次重新起流,不能边滑边 seek。
    private(set) var scrubPreviewSeconds: Double?

    /// 这条会话能不能拖进度。由 `session.seekStrategy` 决定,
    /// ⛔ 不按 `plan.method` 推(见 `PlaybackSeekStrategy`)。
    /// 会话还没取到时按「能拖」——真正的判定在 `seek(to:)` 里,那时 `session` 已有值。
    var allowsSeeking: Bool { session?.seekStrategy.allowsSeeking ?? true }

    /// 拖不动时给用户看的理由(从会话取);能拖时为 nil。
    var seekUnavailableReason: String? { session?.seekStrategy.unavailableReason }

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
    /// 首个「可信」的 time-pos 是否已到达。DirectStream 续播时,mpv 在我们 seek 到
    /// 续播点之前会先报一次 0 附近的位置;若片头从 0 开始,拿这个值判片头会触发
    /// 自动跳过,把续播位置覆盖掉。到达续播点附近之前不评估片头 / 下一集。
    private var isPositionSettled = false
    private var upNextTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    /// 起播位置(秒)。来源有两个:打开时的恢复位置,以及转码 seek 的目标。
    private var startSeconds: Double
    /// 续播位置是否已算过(见 `start()`:只算一次,不被转码重新起流覆盖)
    private var didResolveStartPosition = false
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

    /// 播放会话代次。每次 `stop()` +1,用来丢弃上一轮播放器的迟到事件。
    ///
    /// `MPVEventBridge` 一律经 `Task { @MainActor }` 投递,所以旧实例在
    /// shutdown 前后提交的事件**必然**晚于同步执行的 `retry()` 到达:
    /// `shutdown()` 自己会发 `.phaseChanged(.tearingDown/.destroyed)`,
    /// 事件线程在 `mpv_wakeup` 后还会多处理一轮(`runEventLoop` 是先
    /// `process` 再查 `isStopping`),期间可能发出 `.endFile(.error)`。
    /// 不带代次号就会把上一轮的错误写到刚起来的新会话上 —— 新的播放尝试
    /// 还没发出任何请求就直接显示错误页,再点重试会重复这个循环。
    /// 与 CLAUDE.md 对播放上报的要求同源:异步乱序到达必须靠代次号丢弃。
    private var generation = 0

    init(
        container: AppContainer,
        request: PlaybackRequest,
        preparer: (any PlaybackSessionPreparing)? = nil,
        reporter: (any PlaybackReporting)? = nil,
        displaySleep: (any DisplaySleepInhibiting)? = nil
    ) {
        self.container = container
        self.request = request
        // 会话准备与进度出口都按来源装配(Emby → 决策器 + 服务端上报;
        // 百度 → 播放映射 + 本地续播库)。测试可注入替身 —— 接线规则不该依赖网络。
        self.preparer = preparer ?? container.makeSessionPreparer(for: request)
        self.reporter = reporter ?? container.makeReporter(for: request)
        // 显示器休眠断言:App 里用真的 IOKit 断言,单测注入替身
        // (与 reporter 同一个理由:被测逻辑不该依赖系统资源的可用性)。
        self.displaySleep = displaySleep ?? DisplaySleepAssertion()
        // 起播位置。
        // - Emby:进度就在响应里(`UserData.PlaybackPositionTicks`),同步可算 ——
        //   保持既有行为(UI 与测试都依赖 init 后 `resumeStartSeconds` 就是对的)。
        // - 百度:进度在本地续播库(actor),只能等 `start()` 里异步算
        //   (见 `resolveStartPosition()`)。
        if case .emby(_, let item) = request.source {
            let resume = request.startFromBeginning ? 0
                : item.userData?.playbackPositionTicks
                    .flatMap { TickConverter.seconds(fromTicks: $0) } ?? 0
            self.startSeconds = Self.resumePosition(from: resume)
            self.didResolveStartPosition = true
        } else {
            self.startSeconds = 0
        }
        // 请求自带剧集队列(百度来源,或换集时带过来的):上一集 / 下一集当场就定,
        // ⛔ 不用等网络 —— 百度也**不能再查**(配额见 §7)。
        if let queue = request.episodeQueue {
            self.episodeQueue = queue
            self.nextEpisode = queue.next
            self.previousEpisode = queue.previous
        }
    }

    /// 既有 Emby 调用点 / 测试的形状(见 `PlayerWindowView` 与接线测试)。
    convenience init(
        container: AppContainer,
        server: ServerProfile,
        item: EmbyItem,
        startFromBeginning: Bool = false,
        preparer: (any PlaybackSessionPreparing)? = nil,
        reporter: PlaybackProgressReporter? = nil,
        displaySleep: (any DisplaySleepInhibiting)? = nil
    ) {
        self.init(
            container: container,
            request: PlaybackRequest(
                server: server, item: item, startFromBeginning: startFromBeginning),
            preparer: preparer,
            reporter: reporter.map { $0 as any PlaybackReporting },
            displaySleep: displaySleep
        )
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

    /// 正在播的 Emby 项(Emby 来源才有;标题栏 / 系统「正在播放」用)
    var playingItem: EmbyItem? { item }
    var playingServer: ServerProfile? { server }

    /// 来源无关的播放标题(窗口标题 / 系统「正在播放」兜底)。
    /// 百度来源没有 Emby 那套剧集结构,标题就是文件名。
    var playingTitle: String {
        switch request.source {
        case .emby(_, let item): return item.name
        case .baiduPan(let file): return file.name
        }
    }

    private var nextEpisodeTask: Task<Void, Never>?

    // MARK: - 生命周期

    func start() {
        guard startTask == nil else { return }
        timeline = PlaybackTimeline()
        timelineStart = ContinuousClock.now
        startTask = Task {
            // 续播位置只在**首次**起播时算一次:转码 seek 重新起流那一刻
            // `startSeconds` 已经是用户拖到的目标,⛔ 不能被续播位置覆盖回去。
            if !didResolveStartPosition {
                didResolveStartPosition = true
                await resolveStartPosition()
            }
            await prepareAndLoad()
        }
        // 上一集 / 下一集与播放本身无关,单独查、只查一次(转码 seek 重新起流也走 start())。
        // 请求已带队列(百度 / 换集带过来的)就不查 —— 队列本身就是答案。
        if nextEpisodeTask == nil, episodeQueue == nil, item?.kind == .episode {
            nextEpisodeTask = Task { [weak self] in await self?.loadEpisodeQueue() }
        }
    }

    /// 起播位置:Emby 读服务端 `UserData`,百度读本地续播库 —— 由组合根按来源给
    /// (`AppContainer.resumeSeconds(for:fromBeginning:)`)。
    /// 为 nil / 为 0 即从 0 开始,⛔ 不猜「看过了多少」(`API_CONTRACT.md` 8.1)。
    private func resolveStartPosition() async {
        let saved = await container.resumeSeconds(
            for: request, fromBeginning: request.startFromBeginning)
        startSeconds = Self.resumePosition(from: saved)
    }

    /// 重试:播放器实例不可复用(MPV_INTEGRATION.md §8 一实例一 URL),
    /// 所以必须整体重建,不能只是再 load 一次。
    func retry() {
        stop()
        failure = nil
        session = nil
        isPreparing = true
        phase = .idle
        isPaused = false
        isRestarting = false
        isEnded = false
        // 新播放器 = 新上报会话:不复位的话,播放中途出错再重试,
        // 新会话既不会补 seek 到起播位置,也永远不会发 Playing。
        didApplyStartOffset = false
        didBeginReporting = false
        isPositionSettled = false
        start()
    }

    /// 播完后从头再播。mpv 播完即卸载文件(没有开 keep-open),
    /// 所以不是 seek 到 0,而是按新会话整体重建(§8 一实例一 URL)。
    func replay() {
        startSeconds = 0
        positionSeconds = 0
        // 重看一遍 = 全新的一次观看:片头可以再自动跳、下一集可以再提示
        didAutoSkipIntro = false
        isUpNextDismissed = false
        retry()
    }

    /// 收尾:先按 API_CONTRACT.md 5.4 结束上报会话(最终 Progress +
    /// Stopped),再拆播放器。关窗、切媒体、转码 seek 都走这里。
    func stop() {
        finishReporting(sendFinalProgress: true)
        // 收尾这一刻就把显示器休眠还回去:关窗 / 切媒体 / 转码重新起流都走这里。
        // 这里必须是**无条件释放**而不是按 phase 重算 —— stop() 返回后调用方
        // (retry / restartStream)才把 phase 置回 .idle,重算会把断言又拿一份。
        displaySleep.setActive(false)
        // 先递增:此后旧播放器再投递的事件代次都对不上,一律丢弃。
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
        // `restartStream` 内部也会 stop(),那属于新一轮,不能在这里取消自己。
        seekRestartTask?.cancel()
        seekRestartTask = nil
        restartEpoch &+= 1
        isRestarting = false
        stopUpNextCountdown()
        scrubPreviewSeconds = nil
        player?.shutdown()
        player = nil
    }

    // MARK: - 控制

    func togglePlayPause() {
        guard let player else { return }
        do {
            if isPaused {
                try player.resume()
            } else {
                try player.pause()
            }
        } catch {
            failure = LoadFailure(message: "播放控制失败:\(error)")
        }
    }

    /// 倍速:连续值,夹在 `Metrics.speedRange` 内,不要求落在某个档位上。
    /// 转码流同样由 mpv 在客户端变速,服务端不需要知道。
    func setSpeed(_ value: Double) {
        let target = Self.clampedSpeed(value)
        do { try player?.setSpeed(target) } catch { return }
        // 记住用户的选择:同一部剧的下一集、转码 seek 重新起流都从它起播 ——
        // 换集是**新建播放器**(一律 1×),不记就等于「点下一集倍速被打回 1×」。
        // 播放器还没建起来(仍在取播放信息)时照样记 —— 那个值会在新 mpv 上生效。
        container.playbackSpeeds.remember(target, for: speedScope)
        flash(Self.speedText(target), systemImage: "gauge.with.dots.needle.67percent")
    }

    /// 新建的 mpv 一律是 1×,把起播倍速设回去(KNOWN_ISSUES 旧条目
    /// 「倍速在新建播放器后回到 1×」)。换集、重新起流、重试都走这里。
    /// 值来自 `startupSpeed`:这部剧记过的优先,否则是设置页的默认倍速。
    ///
    /// ⛔ 必须在挂事件桥**之前**调用:桥一挂上 mpv 就会推一次当前值,
    /// 先设好,读回来的就是目标倍速,屏显与上报都不会先闪一下 1×。
    private func applyRememberedSpeed(to player: MPVPlayer) {
        let startup = startupSpeed
        guard startup != 1 else { return }
        do {
            try player.setSpeed(startup)
        } catch {
            // 设不回去只是本集退回 1×,不影响能不能播,所以不挂到 failure 上;
            // 但也不能一声不响 —— 记下来,免得以后排障时以为「倍速本来就该保留」。
            let reason = String(describing: error)
            Self.logger.error(
                "倍速 \(startup, privacy: .public)× 设回新建播放器失败,本集按 1× 起播:\(reason, privacy: .public)")
        }
    }

    /// 新建的 mpv 音量是 100,把设置页的「默认音量」设上去。
    /// 理由与时机同 `applyRememberedSpeed`(挂桥之前)。
    private func applyDefaultVolume(to player: MPVPlayer) {
        let target = container.preferences.defaultVolume
        guard target != Metrics.defaultVolume else { return }
        do {
            try player.setVolume(target)
        } catch {
            let reason = String(describing: error)
            Self.logger.error(
                "默认音量 \(target, privacy: .public) 设到新建播放器失败:\(reason, privacy: .public)")
        }
    }

    // MARK: 字幕延迟

    /// 当前能不能调字幕延迟:要有会话,且选中了一条字幕轨 ——
    /// 字幕关着时调了也看不出效果,菜单与快捷键一律不响应,免得留下看不见的状态。
    var canAdjustSubtitleDelay: Bool {
        session != nil && selectedSubtitleTrackID != nil
    }

    /// 设字幕延迟(秒),夹在 `Metrics.subtitleDelayRange` 内。
    /// 播放器还没建起来时照样记下,新 mpv 建好后由 `applySubtitleSettings` 设上。
    func setSubtitleDelay(_ seconds: Double) {
        let target = Self.clampedSubtitleDelay(seconds)
        do { try player?.setSubtitleDelay(target) } catch { return }
        requestedSubtitleDelay = target
        flash(Self.subtitleDelayText(target), systemImage: "captions.bubble")
    }

    /// Z / X(`step` 默认 `Metrics.subtitleDelayStep`,⇧ 为 `subtitleDelayLargeStep`)。
    /// 从「要的值」步进而不是读回值,理由见 `requestedSubtitleDelay`。
    func stepSubtitleDelay(later: Bool, step: Double = Metrics.subtitleDelayStep) {
        guard canAdjustSubtitleDelay else { return }
        setSubtitleDelay(requestedSubtitleDelay + (later ? step : -step))
    }

    func resetSubtitleDelay() {
        guard canAdjustSubtitleDelay else { return }
        setSubtitleDelay(0)
    }

    /// 夹到区间并抹到两位小数(0.1 一步连加会累出 `0.30000000000000004`)。
    /// 非有限值不该出现;真出现时归零。
    static func clampedSubtitleDelay(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let clamped = min(max(value, Metrics.subtitleDelayRange.lowerBound),
                          Metrics.subtitleDelayRange.upperBound)
        let rounded = (clamped * 100).rounded() / 100
        // -0.0 显示成「提前 0 秒」,统一成 0
        return rounded == 0 ? 0 : rounded
    }

    /// 屏显用:「字幕延后 0.3 秒」「字幕提前 1.5 秒」「字幕无延迟」。
    /// 用「延后 / 提前」而不是正负号:`+0.3` 到底是字幕快了还是慢了,没人记得住。
    static func subtitleDelayText(_ seconds: Double) -> String {
        guard seconds != 0 else { return "字幕无延迟" }
        return "字幕\(seconds > 0 ? "延后" : "提前") \(subtitleDelaySeconds(abs(seconds))) 秒"
    }

    /// 菜单里的当前值:「+0.3 秒」「-1.5 秒」「0 秒」
    /// `unit`:App 内界面用「秒」;菜单栏是英文,传 `"s"`(见 `PlayerCommands`)
    static func subtitleDelayValueText(_ seconds: Double, unit: String = "秒") -> String {
        guard seconds != 0 else { return "0 \(unit)" }
        return "\(seconds > 0 ? "+" : "-")\(subtitleDelaySeconds(abs(seconds))) \(unit)"
    }

    private static func subtitleDelaySeconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
    }

    // MARK: 字幕外观

    /// 把当前的字幕外观偏好套到 mpv 上。设置窗口里改了外观之后由播放窗口调用
    /// (`PlayerWindowView` 的 onChange),新建 mpv 时也走这里。
    func applySubtitleStyle() {
        guard let player else { return }
        applySubtitleStyle(container.subtitleStyles.style, to: player)
    }

    private func applySubtitleStyle(_ style: SubtitleStyle, to player: MPVPlayer) {
        do {
            try player.setSubtitleProperties(style.mpvProperties)
        } catch {
            // 外观设不上不影响能不能播,不挂到 failure 上;但要留痕,
            // 否则「设置改了没反应」无从查起。
            Self.logger.error("字幕外观设置失败: \(String(describing: error), privacy: .public)")
        }
    }

    /// 新建的 mpv:字幕延迟是 0、外观是 mpv 默认,把本集的延迟与外观偏好设上。
    /// 与 `applyRememberedSpeed` 同理,⛔ 要在挂事件桥**之前**调用 ——
    /// 桥挂上后推的第一次 `sub-delay` 就是目标值,屏显不会先闪一下 0。
    private func applySubtitleSettings(to player: MPVPlayer) {
        applySubtitleStyle(container.subtitleStyles.style, to: player)
        guard requestedSubtitleDelay != 0 else { return }
        do {
            try player.setSubtitleDelay(requestedSubtitleDelay)
        } catch {
            let delay = requestedSubtitleDelay
            Self.logger.error(
                "字幕延迟 \(delay, privacy: .public) 秒设回新建播放器失败: \(String(describing: error), privacy: .public)")
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

    /// 夹到 mpv 可用的倍速区间(定义见 `Metrics.clampedSpeed`)。
    static func clampedSpeed(_ value: Double) -> Double { Metrics.clampedSpeed(value) }

    static func speedText(_ value: Double) -> String {
        value == value.rounded()
            ? "\(Int(value))×"
            : "\(value.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    /// 拖动到指定秒数。
    ///
    /// ⛔ 三条路**不是同一件事**(API_CONTRACT.md 4.5 + `PlaybackSeekStrategy`):
    /// 直连是静态文件,交给内核 seek;能重新起流的转码是「停流 + 带起流点重取一路」;
    /// 而**拖不动**的源(如百度转码流)既不 seek 也不起流 —— 如实说一句,⛔ 不装作拖成功了。
    ///
    /// 判据一律取 `session.seekStrategy`,⛔ 不按 `plan.method` 反推:
    /// 百度与 Emby 的转码流共用同一个 `.transcode`,但一个拖不动、一个能重起。
    ///
    /// 转码这条路径**带合并**:一次重新起流是 ~4 个请求,而连点前进 / 后退
    /// 会把同一个动作按次触发 `seekRepeatMaxMultiple` 次。合并后连点只在
    /// 停下来时起一次流(`seekRestartMergeDelay`)。`positionSeconds` 仍
    /// 立即更新 —— 进度条与 tooltip 要马上响应,不能等起流。
    func seek(to seconds: Double) {
        guard let session else { return }
        let target = max(0, min(seconds, durationSeconds > 0 ? durationSeconds : seconds))
        switch session.seekStrategy {
        case .clientSeek:
            positionSeconds = target
            do {
                try player?.seek(to: target)
            } catch {
                failure = LoadFailure(message: "拖动失败:\(error)")
                return
            }
            // 5.2:拖动结束立即上报,不等 10 秒定时器
            pushState()
            reportNow(.timeUpdate)

        case .restartStream:
            positionSeconds = target
            scheduleRestartStream(at: target)

        case .unsupported(let reason):
            // ⛔ 不动 `positionSeconds`、不上报:拖动没生效却把进度写成新位置,
            //    会让「继续观看」记到一个从没播到的点。
            flash(reason, systemImage: "nosign")
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

    func setVolume(_ value: Double) {
        do { try player?.setVolume(value) } catch { /* 音量失败不打断播放 */ }
    }

    /// 键盘调音量(↑ ↓,步长 `Metrics.volumeStep`)。调音量顺带解除静音 ——
    /// 静音时按 ↑ 却听不到声音,用户只会以为按键没生效。
    func adjustVolume(by delta: Double) {
        let target = max(0, min(100, volume + delta))
        do {
            if isMuted { try player?.setMuted(false) }
            try player?.setVolume(target)
        } catch { return }
        flash("音量 \(Int(target.rounded()))", systemImage: Self.volumeSymbol(target, muted: false))
    }

    func toggleMute() {
        do { try player?.setMuted(!isMuted) } catch { /* 同上 */ return }
        flash(isMuted ? "取消静音" : "静音",
              systemImage: isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
    }

    static func volumeSymbol(_ volume: Double, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 34 { return "speaker.wave.1.fill" }
        if volume < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// 选音轨(MPV_INTEGRATION.md 第 7 节:设 `aid` = track id)。
    func selectAudioTrack(_ id: Int) {
        selectedAudioTrackID = id
        do { try player?.selectAudioTrack(id: id) } catch { return }
        pushState()
        reportNow(.audioTrackChange)
        if let track = audioTracks.first(where: { $0.id == id }) {
            flash("音轨:\(track.displayName)", systemImage: "waveform")
        }
    }

    /// 选字幕轨;nil = 关字幕(`sid` = `no`)。
    ///
    /// 用户在这里做过一次选择之后,起播的默认偏好就让位
    /// (`applyPreferredSubtitle()` 不再覆盖),否则切轨后 mpv 回推的
    /// track-list 会把用户刚选的顶掉。
    func selectSubtitleTrack(_ id: Int?) {
        hasUserChosenSubtitle = true
        selectedSubtitleTrackID = id
        do { try player?.selectSubtitleTrack(id: id) } catch { return }
        pushState()
        reportNow(.subtitleTrackChange)
        let name = id.flatMap { id in subtitleTracks.first { $0.id == id }?.displayName }
        flash("字幕:\(name ?? "关闭")", systemImage: "captions.bubble")
    }

    /// 起播后按设置页的字幕模式挑一次字幕轨(`SubtitlePreference.startupChoice`)。
    /// 默认是「中文优先」:简体 → 繁体 → 未标变体的中文 → 保持 mpv 默认。
    ///
    /// 只在 track-list 首次到达时做,且用户手动选过之后不再介入。
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

    /// 把起播的字幕选择写到 mpv 上;nil = 关字幕。
    private func applyPreferredSubtitle(id: Int?) {
        // mpv 选中的正好就是想要的:不用写 sid,标记完成即可
        guard id != selectedSubtitleTrackID else {
            hasAppliedPreferredSubtitle = true
            return
        }
        do {
            try player?.selectSubtitleTrack(id: id)
            hasAppliedPreferredSubtitle = true
            // 与手动切轨一致地乐观更新;mpv 会在轨道变化时重推 track-list,
            // 那时按 `selected` 读回覆盖 —— 设不上也不会一直显示错的值。
            selectedSubtitleTrackID = id
        } catch {
            // 设不上就保持原状:mpv 下次重推 track-list 时会再判一次
        }
    }

    /// 换到下一集:写一个新的播放请求,播放窗口据此重建播放页,
    /// 本页随之拆除并走完收尾上报(与关窗同一条路径)。
    func playNextEpisode() {
        switchToEpisode(nextEpisode)
    }

    func playPreviousEpisode() {
        switchToEpisode(previousEpisode)
    }

    /// 选集面板点某一集 —— 可能不是相邻集,直接跳过去。
    func playEpisode(_ episode: PlaybackEpisode) {
        switchToEpisode(episode)
    }

    /// 换到某一集:装配新请求交给播放窗口(换集 = 换请求,见 `PlaybackRequest`)。
    ///
    /// 队列**只在百度来源**带过去:它的兄弟集只存在于这次请求里,丢了就得再列一遍
    /// 网盘(配额);Emby 的兄弟集在服务端,新播放页自己查更全(还能补齐跨季边界)。
    private func switchToEpisode(_ episode: PlaybackEpisode?) {
        guard let episode else { return }
        stopUpNextCountdown()
        // 百度:换集同样要补记「继续观看」的展示快照(复用起播那一刻的 `SourceItem`),
        // ⛔ 不能等渲染续播区时再列网盘(配额,见 `AppContainer.rememberResumeCard`)。
        if let item = episode.resumeItem, let file = episode.source.baiduFile {
            Task { await container.rememberResumeCard(item: item, file: file) }
        }
        let carried = episode.source.baiduFile != nil ? episodeQueue?.selecting(episode) : nil
        container.play(PlaybackRequest(source: episode.source, episodeQueue: carried))
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

    // MARK: - 手动片头 / 片尾

    /// 手动标注的当前值(编辑面板回显用);没标过时为 nil。
    var manualMarkerValues: ManualMarkers? { manualMarkers }

    /// 本剧有没有手动标注(「清除」菜单项的启用判据)。
    var hasManualMarkers: Bool { manualMarkers?.isEmpty == false }

    /// 手动标注的范围键:同一部剧的每一集共用一份(见 `ManualMarkersScope`)。
    private var manualMarkersScopeKey: String { ManualMarkersScope.key(for: request.source) }

    /// 重算最终标记:手动标注按标记组覆盖服务端,未设的那组沿用服务端。
    private func refreshMarkers() {
        markers = manualMarkers?.applying(to: serverMarkers) ?? serverMarkers
    }

    /// 把当前位置设为片头起点(同一部剧共用)。
    func setIntroStartAtCurrentPosition() {
        var updated = manualMarkers ?? ManualMarkers()
        updated.introStart = positionSeconds
        updated.updatedAt = Date()
        commitManualMarkers(updated, flashText: "片头起点 \(PlayerTime.text(positionSeconds))")
    }

    /// 把当前位置设为片头终点(同一部剧共用)。
    func setIntroEndAtCurrentPosition() {
        var updated = manualMarkers ?? ManualMarkers()
        updated.introEnd = positionSeconds
        updated.updatedAt = Date()
        commitManualMarkers(updated, flashText: "片头终点 \(PlayerTime.text(positionSeconds))")
    }

    /// 把当前位置设为片尾起点(同一部剧共用)。
    func setCreditsStartAtCurrentPosition() {
        var updated = manualMarkers ?? ManualMarkers()
        updated.creditsStart = positionSeconds
        updated.updatedAt = Date()
        commitManualMarkers(updated, flashText: "片尾起点 \(PlayerTime.text(positionSeconds))")
    }

    /// 手动输入面板的「保存」:整组替换本剧的标注(空 = 不标那一格)。
    func setManualMarkers(introStart: Double?, introEnd: Double?, creditsStart: Double?) {
        commitManualMarkers(
            ManualMarkers(introStart: introStart, introEnd: introEnd, creditsStart: creditsStart),
            flashText: "片头片尾已保存")
    }

    /// 清除本剧的手动标注。
    func clearManualMarkers() {
        guard hasManualMarkers else { return }
        commitManualMarkers(ManualMarkers(), flashText: "已清除本剧的片头片尾")
    }

    /// 落库 + 立即生效 + 屏显反馈。
    ///
    /// 内存先改、落盘异步:标注要**立刻**影响「跳过片头」按钮 / 自动跳过,
    /// 不能等磁盘。写盘失败不静默吞(硬规则 4)—— 屏显一句失败,内存里的改动保留。
    private func commitManualMarkers(_ updated: ManualMarkers, flashText: String) {
        manualMarkers = updated.isEmpty ? nil : updated
        refreshMarkers()
        flash(flashText, systemImage: "flag")
        let store = container.manualMarkers
        let key = manualMarkersScopeKey
        Task { [weak self] in
            do {
                try await store.set(updated, for: key)
            } catch {
                self?.flash("片头片尾保存失败", systemImage: "exclamationmark.triangle")
            }
        }
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

    /// 每个可信的 time-pos 之后评估一次:自动跳片头、开始 / 撤销下一集倒计时。
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

    // MARK: - 统计信息 / 缓冲轮询

    func toggleStatistics() {
        showsStatistics.toggle()
        if showsStatistics { refreshMonitoredProperties() } else { statistics = nil }
    }

    /// 低频轮询 mpv(`Metrics.playerMonitorInterval`):已缓存位置常驻读,
    /// 缓冲进度 / 网速只在缓冲中读,统计信息只在 overlay 打开时读。
    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(Metrics.playerMonitorInterval)) } catch { return }
                guard let self else { return }
                self.refreshMonitoredProperties()
            }
        }
    }

    private func refreshMonitoredProperties() {
        guard let player else { return }
        var names = ["demuxer-cache-time"]
        if isBuffering { names += ["cache-buffering-state", "cache-speed"] }
        if showsStatistics { names += PlayerStatistics.propertyNames }
        let values = player.stringProperties(names)
        bufferedUntilSeconds = values["demuxer-cache-time"].flatMap(Double.init)
        if isBuffering {
            bufferingPercent = values["cache-buffering-state"].flatMap(Int.init)
            cacheSpeedBytesPerSecond = values["cache-speed"].flatMap(Double.init)
        }
        if showsStatistics {
            statistics = PlayerStatistics(
                properties: values, session: session,
                renderBackend: player.statisticsSnapshot().renderBackend)
        }
    }

    private func flash(_ text: String, systemImage: String) {
        osd = PlayerOSD(text: text, systemImage: systemImage)
    }

    /// 查本季的分集并装配剧集队列,再定出上一集 / 下一集。
    ///
    /// 队列成员就是**本季**的分集(选集面板列的就是它);上一集 / 下一集在队列边界处
    /// 再补一次跨季查询(上一季的最后一集 / 下一季的第一集)—— 与既有行为一致,
    /// 这两个边界集**不进队列**(它们不属于本季)。
    ///
    /// 只用 ✅ 端点 `Shows/{Id}/Episodes` 与 `Shows/{Id}/Seasons`(API_CONTRACT.md 3.2)。
    private func loadEpisodeQueue() async {
        guard let item, let server,
              let seriesID = item.seriesID, let seasonID = item.seasonID else { return }
        let connection = container.connection(for: server)
        do {
            let episodes = try await connection.episodes(seriesID: seriesID, seasonID: seasonID)
            let queue = EpisodeQueue(
                episodes: episodes.map { Self.playableEpisode($0, on: server) },
                currentIndex: episodes.firstIndex { $0.id == item.id }
            )
            episodeQueue = queue
            nextEpisode = queue.next
            previousEpisode = queue.previous
            guard nextEpisode == nil || previousEpisode == nil else { return }

            let seasons = try await connection.seasons(seriesID: seriesID)
            if nextEpisode == nil, let nextSeason = NextEpisodeResolver.item(after: seasonID, in: seasons) {
                nextEpisode = try await connection
                    .episodes(seriesID: seriesID, seasonID: nextSeason.id)
                    .first
                    .map { Self.playableEpisode($0, on: server) }
            }
            if previousEpisode == nil,
               let previousSeason = NextEpisodeResolver.item(before: seasonID, in: seasons) {
                previousEpisode = try await connection
                    .episodes(seriesID: seriesID, seasonID: previousSeason.id)
                    .last
                    .map { Self.playableEpisode($0, on: server) }
            }
        } catch {
            // 上一集 / 下一集是附加功能:查不到只是不显示对应入口,不影响正在进行的播放,
            // 也不弹错误(播放页的错误位只留给播放本身)。已查到的那一个保留。
            return
        }
    }

    /// `EmbyItem` → `PlaybackEpisode`。Emby 的进度走服务端,所以 `resumeItem` 为 nil。
    ///
    /// 封面取分集自己的 `Primary`(剧照截图,`landscapeImage` 的第一条),
    /// 没有才退到 Thumb / Backdrop —— 与分集卡片(`EpisodeCard`)同一口径。
    static func playableEpisode(_ episode: EmbyItem, on server: ServerProfile) -> PlaybackEpisode {
        PlaybackEpisode(
            id: episode.id,
            label: episode.episodeLabel,
            title: episode.name,
            source: .emby(server: server, item: episode),
            poster: episode.landscapeImage.map { image in
                .emby(ImageSpec(
                    serverID: server.id,
                    itemID: image.itemID,
                    type: image.type,
                    tag: image.tag,
                    maxWidth: Int(Metrics.episodeThumbnailWidth * 2)
                ))
            }
        )
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
        // 起播慢时才附带 mpv 明细(带时间戳,能看出卡在首字节还是探测)。
        // 每次都写会很快把 256KB 的日志文件顶满、清掉失败记录。
        if timeline.isSlow {
            NetworkDiagnostics.recordTimingDetail(
                host: session.plan.url.host(), mpvLog: player?.recentLogLines() ?? [])
        }
    }

    private func prepareAndLoad() async {
        do {
            // 会话准备按来源装配(Emby 过决策器 / 百度过播放映射),
            // ⛔ 播放页不认具体是哪个来源 —— 见 `PlaybackSessionPreparing`。
            var prepared = try await preparer.makeSession(startTimeTicks: nil)
            try Task.checkCancellation()
            // 能重新起流的转码 + 非零起播:4.5 规定服务端从 StartTimeTicks 处起流。
            // 之所以「先取一次再带参数重取」,是因为 StartTimeTicks 同时是
            // 服务端的决策输入 —— 一上来就带值可能把本来能 DirectStream 的
            // 文件推去转码;确认为转码之后重取就没有这个顾虑。
            // ⛔ 判据是 `seekStrategy` 而不是 `plan.method`:拖不动的源
            // (带不了起流位置)重取一次也只会从头开始。
            if prepared.seekStrategy == .restartStream, startSeconds > 0 {
                prepared = try await preparer.makeSession(
                    startTimeTicks: TickConverter.ticks(fromSeconds: startSeconds))
                try Task.checkCancellation()
            }
            session = prepared
            // 来源自己知道的权威总时长(百度转码流未转完时内核看到的只是已转那段);
            // Emby 没有这个信息,返回 nil,沿用既有行为。
            if let authoritative = await preparer.authoritativeDurationSeconds, authoritative > 0 {
                durationSeconds = authoritative
            }
            markTimeline(.playbackInfo)
            serverMarkers = PlaybackMarkers(chapters: prepared.mediaSource.chapters)
            // 用户手动标注(同一部剧共用):读回来与服务端标记合并,手动优先。
            // 本地 JSON 读取,一次会话只读一遍(转码重新起流时会再读一次,顺带拾起中途的修改)。
            manualMarkers = await container.manualMarkers.record(for: manualMarkersScopeKey)
            refreshMarkers()

            // 渲染后端策略起播时读一次(默认按片源:DV 用 gpu-next,其余 legacy,
            // 见 MPVRenderBackendPolicy)。切换在 MPVPlayer 内部、VO 建立前完成,这里不用管。
            let player = MPVPlayer(
                backendPolicy: container.preferences.renderBackendPolicy)
            // 初始化失败只写进 `initializationFailure` 不抛错(MPVPlayer.init
            // 的三条失败路径都是直接 return),不在这里查就会一路走到下面的
            // glAttached 轮询 —— core 根本没建起来,GL 上下文永远挂不上,
            // 2s 后报成「渲染上下文创建超时」,把真正的原因(mpv_create 返回
            // NULL / 某个选项被拒 / mpv_initialize 失败)丢掉。
            // docs/PITFALLS.md Q1 要验的正是这类失败,不能盖住。
            if let reason = player.initializationFailure {
                player.shutdown()
                isPreparing = false
                failure = LoadFailure(message: "播放器初始化失败:\(reason)")
                return
            }

            // 新 mpv 是 mpv 自己的默认(1× / 音量 100 / 无字幕延迟),把起播偏好设回去,
            // 都要在挂事件桥之前(见各方法注释)。
            applyRememberedSpeed(to: player)
            applyDefaultVolume(to: player)
            applySubtitleSettings(to: player)

            let generation = self.generation
            let bridge = MPVEventBridge { [weak self] event in
                self?.handle(event, generation: generation)
            }
            player.attach(eventBridge: bridge)
            // 先挂出去让视图把 GL layer 建起来,再等上下文就绪
            self.player = player
            startMonitoring()

            let deadline = Date().addingTimeInterval(Self.glAttachTimeout)
            while !player.statisticsSnapshot().glAttached, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard player.statisticsSnapshot().glAttached else {
                // 与「服务端没给可播路径」是两回事:这里渲染上下文没建起来,
                // 重开一次通常就好,所以单独给一条文案而不是复用 PlaybackError。
                isPreparing = false
                failure = LoadFailure(message: "视频渲染上下文创建超时,请重试。")
                return
            }

            markTimeline(.glReady)
            try player.load(url: prepared.plan.url, headers: prepared.plan.headers)
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

    /// GL 渲染上下文的等待上限(2s,与开发期渲染 spike 的实测值一致)。
    private static let glAttachTimeout: TimeInterval = 2

    /// 倍速设不回新建播放器时的排障出口(与 `DisplaySleepAssertion` 同一个子系统)。
    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "playback")

    /// 转码 seek 的重新起流:结束旧上报会话 → 拆掉 mpv(连接断开即停流)
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
    /// 与 mpv 自带 `stop-screensaver=yes` 的语义对齐(⛔ 不是 `=2` 的「始终抑制」):
    /// 只有正在播放才抑制,暂停 / 播完 / 加载 / 失败 / 拆播放器都还给系统。
    ///
    /// 三个判据各有各的必要性:
    /// - `phase == .playing`:暂停会被 mpv 置成 `.paused`,加载是 `.loading`,失败是 `.failed`;
    /// - `!isPaused`:起播前就按了暂停时,phase 仍会随 FILE_LOADED 变成 `.playing`
    ///   (mpv 先报文件就绪、再报 pause),只看 phase 会为「暂停中的画面」占着断言;
    /// - `!isEnded`:**播完时 phase 停在 `.playing`**(§8 状态机没有「已结束」态,
    ///   `docs/PITFALLS.md` Q7),不看这个就会让播完卡片一直占着断言。
    static func shouldPreventDisplaySleep(
        phase: MPVPlayerPhase, isPaused: Bool, isEnded: Bool
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
            playbackRate: speed,
            // 本地续播库按它判「已看完」(Emby 上报不读这个字段)
            durationSeconds: durationSeconds > 0 ? durationSeconds : nil
        )
    }

    private func embyStreamIndex(for trackID: Int, in tracks: [MPVTrack]) -> Int? {
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
            itemID: request.source.contentID,
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

    /// mpv 事件入口。`generation` 是**发出这条事件的播放器实例**建立时的代次,
    /// 与当前代次不符即来自已被 `stop()` 拆掉的上一轮,直接丢弃。
    /// (`internal` 而非 `private`:`PlayerViewModelTests` 要直接验这条门。)
    func handle(_ event: MPVPlayerEvent, generation: Int) {
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
                            try player?.seek(to: startSeconds)
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

        case .speed(let value):
            // mpv 起播时会先报一次初始值(1),没变就不上报
            guard value != speed else { return }
            speed = value
            pushState()
            // 5.2 要求改倍速立即上报,但滑块是连续的(0.05 一跳),一次拖动
            // 就是十几个请求 —— 真实服务器纪律要求低频,所以合并成一次:
            // 停手 `Metrics.speedReportDelay` 后再发,值取最后那次。
            // `pushState()` 每次都走,10 秒一次的 Progress 里倍速不会缺。
            scheduleRateChangeReport()

        case .subtitleDelay(let value):
            // 不上报:5.1 的 `SubtitleOffset` 单位未核实(KNOWN_ISSUES.md Q39),
            // 发错单位比不发更糟 —— 服务端会把它当成真值转给远程控制端。
            subtitleDelay = value

        case .buffering(let value):
            isBuffering = value
            if !value {
                bufferingPercent = nil
                cacheSpeedBytesPerSecond = nil
            }

        case .paused(let paused):
            isPaused = paused
            updateDisplaySleepAssertion()
            // 5.2:暂停 / 恢复立即上报
            pushState()
            reportNow(paused ? .pause : .unpause)

        case .timePos(let value):
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

        case .volume(let value):
            volume = value
            pushState()
            reportNow(.volumeChange)

        case .muted(let value):
            isMuted = value
            pushState()
            reportNow(.volumeChange)

        case .trackList(let tracks):
            audioTracks = tracks.filter { $0.type == .audio }
            subtitleTracks = tracks.filter { $0.type == .sub }
            // 读回验证(第 7 节:设置 aid/sid 后要读回,不能假设设置即生效)。
            // track-list 的 selected 就是读回结果,菜单勾选状态据此刷新。
            selectedAudioTrackID = audioTracks.first { $0.selected }?.id
            selectedSubtitleTrackID = subtitleTracks.first { $0.selected }?.id
            applyPreferredSubtitle()
            pushState()

        case .endFile(.eof):
            // 6.6:自然播完 → 直接 Stopped,位置用最终位置
            isEnded = true
            // 播完即释放显示器休眠断言(phase 停在 .playing,只能靠 isEnded 判)
            updateDisplaySleepAssertion()
            finishReporting(sendFinalProgress: false)
            // 没有片尾标记、也没赶上结束前的提示(比如直接拖到了最后)时,
            // 播完卡片同样按设置倒计时播下一集
            if autoPlayNext, upNextCountdown == nil { startUpNextCountdown() }

        case .endFile(.error(let message)):
            // mpv 侧的失败(拉流 401 / 解码失败 / 容器不支持)都走这里;
            // 文案要能区分「服务端没给可播路径」(PlaybackError)与
            // 「给了但播不起来」(本分支)。
            failure = LoadFailure(message: "播放失败:\(message)")
            // 错误码看不出 libmpv 实际收到了什么(媒体 / HTML / JSON 错误页):
            // 连同它最近的日志一起脱敏后落诊断日志(NetworkDiagnostics,不含 token)
            if let session {
                let mpvLog = player?.recentLogLines() ?? []
                NetworkDiagnostics.recordPlaybackFailure(
                    message: message,
                    url: session.plan.url,
                    method: session.plan.method.rawValue,
                    directStreamURLProvided: session.mediaSource.directStreamUrl != nil,
                    mpvLog: mpvLog
                )
                // 收到 JSON / 文本或 HTTP 4xx/5xx:补一次只读探测看看状态与重定向(每次失败至多一次)
                if PlaybackFailureProbe.shouldProbe(mpvLog: mpvLog) {
                    let url = session.plan.url
                    let headers = session.plan.headers
                    Task { await PlaybackFailureProbe.run(url: url, headers: headers) }
                }
            }

        default:
            break
        }
    }

    /// time-pos 是否已可信(见 `isPositionSettled`)。
    /// 只有 DirectStream + 非零续播点才需要等:客户端 seek 之前 mpv 报的是文件开头。
    /// 转码流从 `StartTimeTicks` 处起流,没有这一步客户端 seek。
    static func isSettledPosition(_ value: Double, startSeconds: Double, method: PlaybackMethod?) -> Bool {
        guard startSeconds > 0, method == .directStream else { return true }
        return abs(value - startSeconds) < settledPositionTolerance
    }

    /// 判定「已到续播点附近」的容差(秒)。`seek absolute+exact` 落点误差很小,
    /// 3 秒足够覆盖首个 time-pos 的延迟,又不会把文件开头误判为已就位。
    private static let settledPositionTolerance: Double = 3
}
