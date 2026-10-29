import Foundation
import os

/// 服务端给了响应但没有可播路径也走这里(失败要可解释,不能只显示“播放失败”)。
extension LoadFailure {
    init(_ error: PlaybackError) {
        self.init(message: error.userMessage, needsLogin: false)
    }
}

/// 播放页的状态机(会话、进度同步、轨道、seek 分派)。
///
/// 流程:取会话 → 建 `MPVPlayer` → **等 GL 上下文挂接** → `load` → 首帧后上报。
/// ⚠️ 等挂接不是可选的(render.h:32-34 / 113-115):上下文晚于播放建立,
/// `vo=libmpv` 的视频初始化会失败或退化成自建窗口的 VO。
@MainActor
@Observable
final class PlayerViewModel {
    private let container: AppContainer
    /// 本次要播的内容(含来源身份 —— Emby / 百度网盘)
    private let request: PlaybackRequest
    /// Emby 来源才有;百度来源下为 nil
    private var server: ServerProfile? { request.embyServer }
    private var item: EmbyItem? { request.embyItem }
    /// 会话准备(按来源装配)。⛔ 播放页只认这个协议,新增来源改组合根。
    private let preparer: any PlaybackSessionPreparing
    /// 进度出口(Emby → 服务端上报;百度 → 本地续播库,API_CONTRACT.md 5.4)。
    private let reporter: any PlaybackReporting
    /// 播放期的显示器休眠断言。⛔ 不能依赖 mpv 的 `stop-screensaver`(`vo=libmpv` 下不生效),
    /// 判据见 `shouldPreventDisplaySleep`(GitHub issue #1)。
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

    private(set) var positionSeconds: Double = 0 {
        didSet { refreshCurrentChapterID() }
    }
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
    /// 用户要的字幕延迟。单独存是因为读回值有延迟(连按 Z / X 会丢步),
    /// 且新 mpv 一律是 0,重新起流要设回去。
    /// ⛔ 只活在这一集:不跨集沿用(不进 `PageCarryOver`)、不持久化。
    private var requestedSubtitleDelay: Double = 0

    // MARK: - 音频延迟(MPV_INTEGRATION.md 7.2)

    /// 音频延迟(秒,mpv `audio-delay` 读回值):正 = 音频晚于画面。
    private(set) var audioDelay: Double = 0
    /// 用户要的音频延迟,理由同 `requestedSubtitleDelay`(读回有延迟,连按会丢步;新 mpv 一律是 0)。
    /// ⛔ 只活在这一集,与字幕延迟同一套策略。
    private var requestedAudioDelay: Double = 0

    // MARK: - 章节(MPV_INTEGRATION.md 7.3)

    /// 内核看到的容器章节(Emby / 百度 / 本地文件夹统一由 mpv 给)。转码流通常没有。
    /// 新播放器 = 新文件,起播前清空(`prepareAndLoad`)。
    private(set) var chapters: [MPVChapter] = [] {
        didSet { refreshCurrentChapterID() }
    }

    // MARK: - 画面适配(MPV_INTEGRATION.md 7.4)

    /// 当前生效的填充 / 缩放 / 旋转 / 宽高比。新 mpv 一律是默认值,
    /// 所以转码 seek 与换集都要重新套用(`applyPlaybackAdjustments`)。
    private(set) var picture = PictureSettings.default

    // MARK: - 体验打磨(倍速 / 缓冲 / 播完 / 下一集 / 屏显提示)

    /// 播放速率(mpv `speed` 读回值,不是设置值);跨集沿用见 `container.playbackSpeeds`。
    private(set) var speed: Double = 1

    /// 本次播放的倍速键(Emby 是 `SeriesId`;百度是剧目录,非剧退化成 `fs_id`)。
    /// ⚠️ 依赖 `episodeQueue`,所以起播前就必须有值(`PlaybackRequest.episodeQueue`)。
    private var speedScope: PlaybackSpeedScope {
        switch request.source {
        case .emby(let server, let item):
            return .emby(serverID: server.id, item: item)
        case .baiduPan(let file):
            return .baiduPan(file: file, isEpisodeSeries: episodeQueue != nil)
        case .localFolder(let file, let source):
            return .localFolder(sourceID: source.id, file: file, isEpisodeSeries: episodeQueue != nil)
        }
    }

    /// 起播倍速:本剧记过的 > 设置页「默认倍速」> 1×。仅测试 / 日志观察,
    /// 播放决策在 `applyRememberedSpeed`。⛔ 记的值不落 `UserDefaults`(`PlaybackSpeedStore`)。
    var startupSpeed: Double {
        container.playbackSpeeds.speed(for: speedScope) ?? container.preferences.defaultSpeed
    }
    /// 播放中因缓存不足暂停(mpv `paused-for-cache`)
    private(set) var isBuffering = false
    /// 已自然播完(`end-file` reason = eof)。重播 / 重试时复位。
    private(set) var isEnded = false
    /// 当前播放器已画出第一帧真实视频帧(`firstVideoFrameRendered`)。重试时复位。
    private(set) var hasRenderedFirstVideoFrame = false
    /// track-list 已到、里面没有视频轨(纯音频文件):永远等不到第一帧
    private var hasNoVideoTrack = false

    /// 当前播放器会有画面但还没出来;期间把上一帧留在屏上(`lingeringPlayer`)。
    /// 出错 / 播完 / 纯音频都算「不用再等」,⛔ 不能让定格画面一直压着。
    var isAwaitingFirstVideoFrame: Bool {
        !hasRenderedFirstVideoFrame && !hasNoVideoTrack && failure == nil && !isEnded
    }

    /// 上一个出过画面的播放器(已 shutdown)。`stop()` 时留下,新播放器出第一帧时放掉;
    /// 换集时交给下一集的 ViewModel(`lastFramePlayer` → init),重新起流 / 换集都不黑屏。
    private var frozenPlayer: MPVPlayer?

    /// 视频层要盖在当前播放器上面的定格画面;nil = 不用盖(见 `frozenPlayer`)
    var lingeringPlayer: MPVPlayer? { isAwaitingFirstVideoFrame ? frozenPlayer : nil }

    /// 换集交接用:不看「还等不等」,上一集结束时屏上最后那一帧就是它
    var lastFramePlayer: MPVPlayer? { frozenPlayer }
    /// 可切换的剧集队列(上一集 / 下一集 / 选集面板的唯一数据源)。
    /// 来源:请求自带(百度)或本页查 Emby 当前季;nil = 不是剧集 / 没有兄弟集(电影、单条视频)。
    private(set) var episodeQueue: EpisodeQueue?
    /// 下一集;不是剧集 / 已是最后一集 / 定位不到时为 nil(队列边界处补一次跨季查询)。
    private(set) var nextEpisode: PlaybackEpisode?
    /// 画面上的短暂提示(DesignTokens.swift「界面规则」);每次新 id,视图据此重新计时。
    private(set) var osd: PlayerOSD?
    /// ⚠️ 外挂字幕只能挂一次:`.playing` 会反复到达,重复 `sub-add` 会堆出一排同名轨。
    /// 换播放器(重试 / 转码重新起流)时在 `prepareAndLoad` 里复位。
    private var didAddExternalSubtitles = false
    /// 本次播放最后挂上的字幕;换播放器时**静默**重挂,不读记录也不提示(否则每拖一次闪一句)。
    private var sessionSubtitle: (stored: SubtitleFileStore.Stored, assrtID: Int?)?

    /// 系统「正在播放」的倍速档位:那条命令只能给离散值(播放器内是连续调节)。
    static let speedPresets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    // MARK: - 片头 / 下一集 / 缓冲 / 统计 / 触控板拖动

    /// 剧集的上一集(系统「正在播放」的上一曲、⌘←);查找规则与下一集对称。
    /// Emby 在队列边界处会再补一次跨季查询(上一季的最后一集)。
    private(set) var previousEpisode: PlaybackEpisode?
    /// 选集面板的成员(有序)。当前集由 `currentEpisodeID` 标出;不足两集时面板不出现。
    var episodes: [PlaybackEpisode] { episodeQueue?.episodes ?? [] }
    /// 当前这一集的来源内 id(选集面板高亮用)。
    var currentEpisodeID: String? { episodeQueue?.current?.id }
    /// 最终片头片尾标记(API_CONTRACT.md 4.3.1)= 手动标注覆盖服务端标记,由 `refreshMarkers()` 算。
    /// ⛔ 不要直接写它;都没有时为 `.none`。
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
    /// 触控板横滑的预览目标(秒);nil = 没在拖。松手才 seek —— 转码下一次 seek 就是重新起流。
    private(set) var scrubPreviewSeconds: Double?

    /// 内核这一刻能不能接受 seek。两个判据缺一不可:
    /// - 已有加载好的文件:mpv 在 `FILE_LOADED` 前对 seek 一律返回 `-12`(PITFALLS),
    ///   而 phase 进 `.playing` 与 mpv 认 seek 同刻。
    /// - 还没播完:mpv 播完即卸载文件但 phase 仍停在 `.playing`(§8 / PITFALLS Q7),只能靠 `isEnded`。
    var isReadyToSeek: Bool { (phase == .playing || phase == .paused) && !isEnded }

    /// 进度条可拖:源有可行方案(`session.seekStrategy`,⛔ 不按 `plan.method` 推)且 `isReadyToSeek`;
    /// 会话没取到时按能拖算。
    var allowsSeeking: Bool { (session?.seekStrategy.allowsSeeking ?? true) && isReadyToSeek }

    /// 拖不动时给用户看的理由(从会话取);能拖时为 nil。
    var seekUnavailableReason: String? { session?.seekStrategy.unavailableReason }

    // MARK: - 播放偏好(设置页「播放」页,UserDefaults 持久化)

    /// 转发 `container.preferences`(设置窗口与播放窗口必须同一份);进片头区间自动跳,默认关(标记不准会吃掉开头)。
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
    /// 自动跳片头每次播放只触发一次:拖回片头说明就是想看,不能反复弹走。
    private var didAutoSkipIntro = false
    /// 首个可信的 time-pos 是否已到。DirectStream 续播时 mpv 会先报 0 附近的位置,
    /// 若片头从 0 开始会误触发自动跳过 —— 到续播点附近之前不评估片头 / 下一集。
    private var isPositionSettled = false
    private var upNextTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var monitorTimerTask: Task<Void, Never>?
    private var monitorRequests: AsyncStream<Void>.Continuation?
    /// 开关期间的旧轮不能给重新打开的面板/缓冲状态写回。
    private var statisticsEpoch = 0
    private var bufferingEpoch = 0
    /// 默认使用 mpv 真异步 API;测试注入可控的挂起读取,不需要播放/网络/GL。
    private let readMonitoredProperties: @MainActor (MPVPlayer, [String]) async throws -> [String: String]

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
    /// 文件树来源收尾要落进本地续播库的东西(已看 + 下一集占位);单独存是为了关窗时能等它。
    private var fileSourceFinishTask: Task<Void, Never>?
    /// 合并后的倍速上报任务(连续调节时只留最后一次)
    private var rateReportTask: Task<Void, Never>?
    /// 转码 seek 合并后的重新起流任务(连点时只留最后一次)
    private var seekRestartTask: Task<Void, Never>?
    /// 每次「重新起流 / 收尾」自增。合并任务用它判断自己是否已被作废。
    private var restartEpoch = 0

    /// 播放会话代次,每次 `stop()` +1,用来丢弃上一轮播放器的迟到事件。
    /// ⛔ `MPVEventBridge` 经 `Task { @MainActor }` 投递,旧实例事件必然晚于 `retry()` 到达,
    /// 会把上一轮错误写到新会话上 —— 必须靠代次丢弃。
    private var generation = 0

    /// 换集时从上一集带过来的播放页级状态(ViewModel 与 mpv 仍是每集一份,§8 一实例一 URL)。
    /// 带:音量 / 静音(新 mpv 默认 100 且不静音)、统计面板、画面适配(同剧各集通常是同一种压制)。
    /// ⛔ 不带这一集的东西:字幕延迟、音频延迟、续播位置、轨道选择;倍速走 `PlaybackSpeedStore`。
    struct PageCarryOver: Equatable {
        var volume: Double
        var isMuted: Bool
        var showsStatistics: Bool
        var picture = PictureSettings.default
    }

    /// 交给下一集的状态。播放器没建起来时音量是占位值,那时只带统计面板与画面适配。
    var pageCarryOver: PageCarryOver? {
        guard player != nil else {
            guard showsStatistics || picture != .default else { return nil }
            return PageCarryOver(
                volume: Metrics.defaultVolume, isMuted: false,
                showsStatistics: showsStatistics, picture: picture)
        }
        return PageCarryOver(
            volume: volume, isMuted: isMuted, showsStatistics: showsStatistics, picture: picture)
    }

    /// 上一集带过来的页面级状态;nil = 新开的播放页。只在建 mpv 时读。
    private let carryOver: PageCarryOver?

    init(
        container: AppContainer,
        request: PlaybackRequest,
        carryOver: PageCarryOver? = nil,
        lastFramePlayer: MPVPlayer? = nil,
        preparer: (any PlaybackSessionPreparing)? = nil,
        reporter: (any PlaybackReporting)? = nil,
        displaySleep: (any DisplaySleepInhibiting)? = nil,
        readMonitoredProperties: @escaping @MainActor (MPVPlayer, [String]) async throws -> [String: String] = {
            try await $0.stringPropertiesAsync($1)
        }
    ) {
        self.container = container
        self.readMonitoredProperties = readMonitoredProperties
        self.request = request
        self.preferredSourceID = request.preferredMediaSourceID
        self.carryOver = carryOver
        self.frozenPlayer = lastFramePlayer
        self.showsStatistics = carryOver?.showsStatistics ?? false
        self.picture = carryOver?.picture ?? .default
        // 会话准备与进度出口按来源装配;测试可注入替身(接线规则不该依赖网络)。
        self.preparer = preparer ?? container.makeSessionPreparer(for: request)
        self.reporter = reporter ?? container.makeReporter(for: request)
        // 显示器休眠断言:App 用真的 IOKit 断言,单测注入替身。
        self.displaySleep = displaySleep ?? DisplaySleepAssertion()
        self.danmaku = DanmakuController(
            query: DanmakuMediaQuery.make(for: request.source),
            service: container.danmaku,
            enabledByDefault: container.danmakuSettings.settings.isEnabled)
        // 起播位置:Emby 的进度在响应里,init 时同步算好(UI 与测试依赖这一点);
        // 百度在本地续播库(actor),只能等 `start()` 异步算(`resolveStartPosition()`)。
        if case .emby(_, let item) = request.source {
            let resume = request.startFromBeginning ? 0
                : item.userData?.playbackPositionTicks
                    .flatMap { TickConverter.seconds(fromTicks: $0) } ?? 0
            self.startSeconds = Self.resumePosition(from: resume)
            self.didResolveStartPosition = true
        } else {
            self.startSeconds = 0
        }
        // 请求自带队列(百度或换集带过来的):当场定出上一集 / 下一集,⛔ 不用等网络(百度配额 §7)。
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

    /// 续播起点:往回退 `Metrics.resumeRewind` 秒接前情,不退到 0 以下;0 原样返回。
    static func resumePosition(from saved: Double) -> Double {
        guard saved > 0 else { return 0 }
        return max(0, saved - Metrics.resumeRewind)
    }

    /// 起播位置(秒);仅供测试与日志观察,不参与播放决策。
    var resumeStartSeconds: Double { startSeconds }

    /// 是否正持有阻止显示器休眠的断言(仅供测试 / 日志观察;权威观察点是 `pmset -g assertions`)。
    var isPreventingDisplaySleep: Bool { displaySleep.isHeld }

    /// 本 ViewModel 播的那一次请求(播放页换集后据此给旧会话发收尾广播)
    var playbackRequest: PlaybackRequest { request }

    /// 正在播的 Emby 项(Emby 来源才有;标题栏 / 系统「正在播放」用)
    var playingItem: EmbyItem? { item }
    var playingServer: ServerProfile? { server }

    /// 来源无关的播放标题(窗口标题 / 系统「正在播放」兜底):文件树来源就是文件名。
    var playingTitle: String {
        switch request.source {
        case .emby(_, let item): return item.name
        case .baiduPan(let file), .localFolder(let file, _): return file.name
        }
    }

    private var nextEpisodeTask: Task<Void, Never>?

    /// 这一集的弹幕(`docs/DANMAKU.md`)。每集一份,换集随 ViewModel 一起换新。
    let danmaku: DanmakuController

    // MARK: - 生命周期

    func start() {
        guard startTask == nil else { return }
        timeline = PlaybackTimeline()
        timelineStart = ContinuousClock.now
        startTask = Task {
            // 续播位置只在首次起播算一次:转码 seek 时 `startSeconds` 已是用户目标,⛔ 不能覆盖回去。
            if !didResolveStartPosition {
                didResolveStartPosition = true
                await resolveStartPosition()
            }
            await prepareAndLoad()
        }
        // 上一集 / 下一集单独查、只查一次(重新起流也走 start());请求已带队列就不查。
        if nextEpisodeTask == nil, episodeQueue == nil, item?.kind == .episode {
            nextEpisodeTask = Task { [weak self] in await self?.loadEpisodeQueue() }
        }
        // 弹幕同样与播放本身无关,只在第一次 start() 发起(`startIfNeeded` 自己判重)
        danmaku.durationProvider = { [weak self] in
            guard let duration = self?.durationSeconds, duration > 0 else { return nil }
            return duration
        }
        danmaku.matchHintsProvider = { [weak self] in
            guard let self else { return .none }
            return DanmakuMatchHints(tmdbID: self.item?.tmdbID, isMovie: self.item?.kind == .movie)
        }
        danmaku.fingerprintProvider = { [weak self] in
            await self?.mediaFingerprint() ?? nil
        }
        danmaku.startIfNeeded()
    }

    /// 媒体指纹(前 16 MiB 的 MD5),给弹幕 `/match` 的 `fileHash`。
    /// Emby 只在直连流上算(转码流前 16 MiB 是编码器输出,MD5 无意义);最多等会话 10 秒,超时 nil(退回文件名匹配)。
    /// 本地文件走 `localFileFingerprint`,百度不算。
    /// ⚠️ 代价是额外一次 `Range` 请求拉 16 MiB(对限速 / 计费服务器是实打实负担),由用户开关决定
    /// (设置 › 弹幕 › 用文件指纹提高匹配准确度,默认开)。
    private func mediaFingerprint() async -> String? {
        guard container.danmakuSettings.settings.usesFileFingerprint else { return nil }
        switch request.source {
        case .emby: break
        // 百度:为一个指纹多拉 16 MiB 网盘流量不划算(`DanmakuFingerprint` 的成本说明)
        case .baiduPan: return nil
        // 本地文件:读盘不花流量,会话就绪后直接读文件头
        case .localFolder: return await localFileFingerprint()
        }
        // 会话可能还在准备(与弹幕并行),等一小会儿而不是直接放弃
        let deadline = Date().addingTimeInterval(10)
        while session == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return nil }
        }
        guard let session, session.plan.method == .directStream else { return nil }
        return await DanmakuFingerprint.md5(
            of: session.plan.url,
            headers: session.plan.headers,
            expectedFileSize: session.mediaSource.size,
            session: container.session)
    }

    /// 本地文件的指纹:等会话就绪拿到文件地址(访问权由组合根打开),再读前 16 MiB。
    private func localFileFingerprint() async -> String? {
        let deadline = Date().addingTimeInterval(10)
        while session == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return nil }
        }
        guard let url = session?.plan.url, url.isFileURL else { return nil }
        return await DanmakuFingerprint.md5(ofFileAt: url)
    }

    /// 起播位置:由组合根按来源给(`AppContainer.resumeSeconds(for:fromBeginning:)`)。
    /// 0 即从头开始,⛔ 不猜「看过了多少」(`API_CONTRACT.md` 8.1)。
    private func resolveStartPosition() async {
        let saved = await container.resumeSeconds(
            for: request, fromBeginning: request.startFromBeginning)
        startSeconds = Self.resumePosition(from: saved)
    }

    /// 重试:播放器实例不可复用(MPV_INTEGRATION.md §8 一实例一 URL),必须整体重建。
    func retry() {
        stop()
        failure = nil
        session = nil
        isPreparing = true
        phase = .idle
        isPaused = false
        isRestarting = false
        isEnded = false
        // 新播放器 = 新上报会话:不复位的话重试后不会补 seek 到起播位置,也不发 Playing。
        didApplyStartOffset = false
        didBeginReporting = false
        isPositionSettled = false
        start()
    }

    /// 播完后从头再播。mpv 播完即卸载文件,所以不是 seek 到 0 而是整体重建(§8 一实例一 URL)。
    func replay() {
        startSeconds = 0
        positionSeconds = 0
        // 重看一遍 = 全新的一次观看:片头可以再自动跳、下一集可以再提示
        didAutoSkipIntro = false
        isUpNextDismissed = false
        retry()
    }

    /// 关窗 / 换集:`stop()` 之外再给文件树来源收尾 —— 越过 90% 直接关窗也是看完了,续播卡要指向下一集。
    /// ⛔ 不放进 `stop()`:重试与转码重新起流也走它,那不是这一集结束。播完那次已在 `.endFile(.eof)` 收过。
    func close() {
        stop()
        guard !isEnded else { return }
        settleFileSourceEpisode(naturalEnd: false)
    }

    /// 收尾:先按 API_CONTRACT.md 5.4 结束上报会话(最终 Progress + Stopped),再拆播放器。
    func stop() {
        finishReporting(sendFinalProgress: true)
        // 无条件释放而不是按 phase 重算:stop() 返回后调用方才置回 .idle,重算会又拿一份断言。
        displaySleep.setActive(false)
        // 先递增:此后旧播放器再投递的事件代次都对不上,一律丢弃。
        generation &+= 1
        startTask?.cancel()
        startTask = nil
        monitorRequests?.finish()
        monitorRequests = nil
        monitorTimerTask?.cancel()
        monitorTimerTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        // 待发的倍速上报属于已经结束的会话:Stopped 之前的最终 Progress 会带上倍速
        rateReportTask?.cancel()
        rateReportTask = nil
        // 待起流的合并 seek 作废:代次 +1 给「已过 sleep、cancel 无效」的任务兜底(`restartStream` 内部也调 stop())。
        seekRestartTask?.cancel()
        seekRestartTask = nil
        restartEpoch &+= 1
        isRestarting = false
        stopUpNextCountdown()
        scrubPreviewSeconds = nil
        // 出过画面就留最后一帧(`frozenPlayer`),没出过就沿用更早那一帧。
        // ⛔ 必须与 `player = nil` 同步写,隔一拍视频层会变成空 layer。
        if let player, player.hasRenderedVideoFrame {
            frozenPlayer = player
        }
        player?.shutdown()
        player = nil
        hasRenderedFirstVideoFrame = false
        hasNoVideoTrack = false
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

    /// 倍速:连续值,夹在 `Metrics.speedRange` 内;转码流同样由 mpv 在客户端变速。
    func setSpeed(_ value: Double) {
        let target = Self.clampedSpeed(value)
        do { try player?.setSpeed(target) } catch { return }
        // 记住用户的选择:换集是新建播放器(一律 1×),不记就会被打回 1×。
        // 播放器还没建起来时照样记,那个值会在新 mpv 上生效。
        container.playbackSpeeds.remember(target, for: speedScope)
        flash(Self.speedText(target), systemImage: "gauge.with.dots.needle.67percent")
    }

    /// 新建的 mpv 一律是 1×,把起播倍速(`startupSpeed`)设回去。
    /// 在挂事件桥之前调用:控件一出现就是目标倍速,不会先闪一下 1×。这次变化的事件由 `MPVPlayer`
    /// 积着、挂桥时补发(`eventsBeforeBridge`),所以 `speed` 读回值照样会到。
    private func applyRememberedSpeed(to player: MPVPlayer) {
        let startup = startupSpeed
        guard startup != 1 else { return }
        do {
            try player.setSpeed(startup)
        } catch {
            // 设不回去只是本集退回 1×,不挂 failure,但要留痕免得排障时误判。
            let reason = String(describing: error)
            Self.logger.error(
                "倍速 \(startup, privacy: .public)× 设回新建播放器失败,本集按 1× 起播:\(reason, privacy: .public)")
        }
    }

    /// 换集带过来的音量 / 静音优先(`PageCarryOver`),否则「默认音量」;时机同 `applyRememberedSpeed`。
    private func applyDefaultVolume(to player: MPVPlayer) {
        let target = carryOver?.volume ?? container.preferences.defaultVolume
        do {
            if carryOver?.isMuted == true { try player.setMuted(true) }
            guard target != Metrics.defaultVolume else { return }
            try player.setVolume(target)
        } catch {
            let reason = String(describing: error)
            Self.logger.error(
                "起播音量 \(target, privacy: .public) / 静音设到新建播放器失败:\(reason, privacy: .public)")
        }
    }

    // MARK: 字幕延迟

    /// 能不能调字幕延迟:要有会话且选中了字幕轨(字幕关着时调了看不出效果)。
    var canAdjustSubtitleDelay: Bool {
        session != nil && selectedSubtitleTrackID != nil
    }

    /// 设字幕延迟,夹在 `Metrics.subtitleDelayRange` 内;播放器没建起来也记下,由 `applySubtitleSettings` 设上。
    func setSubtitleDelay(_ seconds: Double) {
        let target = Self.clampedSubtitleDelay(seconds)
        do { try player?.setSubtitleDelay(target) } catch { return }
        requestedSubtitleDelay = target
        flash(Self.subtitleDelayText(target), systemImage: "captions.bubble")
    }

    /// Z / X(`step` 默认 `Metrics.subtitleDelayStep`,⇧ 为 `subtitleDelayLargeStep`);从要的值步进,见 `requestedSubtitleDelay`。
    func stepSubtitleDelay(later: Bool, step: Double = Metrics.subtitleDelayStep) {
        guard canAdjustSubtitleDelay else { return }
        setSubtitleDelay(requestedSubtitleDelay + (later ? step : -step))
    }

    func resetSubtitleDelay() {
        guard canAdjustSubtitleDelay else { return }
        setSubtitleDelay(0)
    }

    /// 夹到区间并抹到两位小数(0.1 连加会累出 `0.30000000000000004`);非有限值归零。
    static func clampedSubtitleDelay(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let clamped = min(max(value, Metrics.subtitleDelayRange.lowerBound),
                          Metrics.subtitleDelayRange.upperBound)
        let rounded = (clamped * 100).rounded() / 100
        // -0.0 显示成「提前 0 秒」,统一成 0
        return rounded == 0 ? 0 : rounded
    }

    /// 屏显用:「字幕延后 0.3 秒」…;用延后 / 提前而不是正负号(没人记得住 `+0.3` 是谁快了)。
    static func subtitleDelayText(_ seconds: Double) -> String {
        guard seconds != 0 else { return "字幕无延迟" }
        return "字幕\(seconds > 0 ? "延后" : "提前") \(delaySecondsText(abs(seconds))) 秒"
    }

    /// 菜单里的当前值(「+0.3 秒」);`unit`:App 内界面用「秒」,菜单栏传 `"s"`(`PlayerCommands`)。
    static func subtitleDelayValueText(_ seconds: Double, unit: String = "秒") -> String {
        guard seconds != 0 else { return "0 \(unit)" }
        return "\(seconds > 0 ? "+" : "-")\(delaySecondsText(abs(seconds))) \(unit)"
    }

    // MARK: 音频延迟

    /// 能不能调音频延迟:有会话即可(不像字幕要求选了轨 —— 有声音就能对)。
    var canAdjustAudioDelay: Bool { session != nil }

    /// 设音频延迟,夹在 `Metrics.audioDelayRange` 内;播放器没建起来也记下,由 `applyPlaybackAdjustments` 设上。
    func setAudioDelay(_ seconds: Double) {
        let target = Self.clampedAudioDelay(seconds)
        do { try player?.setAudioDelay(target) } catch { return }
        requestedAudioDelay = target
        flash(Self.audioDelayText(target), systemImage: "waveform")
    }

    /// 从要的值步进(理由同字幕:读回值滞后,连按会丢步)。
    func stepAudioDelay(later: Bool, step: Double = Metrics.audioDelayStep) {
        guard canAdjustAudioDelay else { return }
        setAudioDelay(requestedAudioDelay + (later ? step : -step))
    }

    func resetAudioDelay() {
        guard canAdjustAudioDelay else { return }
        setAudioDelay(0)
    }

    /// 夹到区间并抹到两位小数;非有限值归零。
    static func clampedAudioDelay(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let clamped = min(max(value, Metrics.audioDelayRange.lowerBound),
                          Metrics.audioDelayRange.upperBound)
        let rounded = (clamped * 100).rounded() / 100
        return rounded == 0 ? 0 : rounded
    }

    /// 屏显用:「音频延后 0.3 秒」。正 = 音频晚于画面,与 mpv `audio-delay` 同向。
    static func audioDelayText(_ seconds: Double) -> String {
        guard seconds != 0 else { return "音频无延迟" }
        return "音频\(seconds > 0 ? "延后" : "提前") \(delaySecondsText(abs(seconds))) 秒"
    }

    /// 菜单里的当前值;`unit` 约定同 `subtitleDelayValueText`。
    static func audioDelayValueText(_ seconds: Double, unit: String = "秒") -> String {
        guard seconds != 0 else { return "0 \(unit)" }
        return "\(seconds > 0 ? "+" : "-")\(delaySecondsText(abs(seconds))) \(unit)"
    }

    /// 两位以内、去掉尾随 0,固定 POSIX(不受系统地区的小数点影响)。
    private static func delaySecondsText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
    }

    // MARK: 章节

    /// 当前章节:按播放位置反推。⛔ 不观察 mpv 的 `chapter` —— 那是内核自己 seek 出来的状态,
    /// 转码流下永远追不上客户端重新起流的位置。
    var currentChapter: MPVChapter? {
        MPVChapter.current(at: positionSeconds, in: chapters)
    }

    /// 当前章节 id,只在跨章时才变。菜单内容读它而不是 `currentChapter`:后者随 `positionSeconds`
    /// 每 0.2s 失效,会让展开 / 悬停中的菜单反复重建、一直闪。
    private(set) var currentChapterID: Int?

    private func refreshCurrentChapterID() {
        let id = currentChapter?.id
        if id != currentChapterID { currentChapterID = id }
    }

    /// 下一章:严格晚于当前位置的第一条
    var nextChapter: MPVChapter? {
        guard positionSeconds.isFinite else { return nil }
        return chapters.first { $0.time > positionSeconds }
    }

    /// 上一章:先回本章开头,已经在开头才退到上一章 —— 连按能一路往前退
    var previousChapter: MPVChapter? {
        guard let current = currentChapter else { return nil }
        if positionSeconds - current.time > Self.chapterRestartTolerance { return current }
        return chapters.last { $0.time < current.time }
    }

    /// 至少两章才值得给入口(单章列表等于整片)
    var hasChapters: Bool { chapters.count > 1 }

    /// 有章节、源能 seek(`PlaybackSeekStrategy`)才给菜单与快捷键
    var canSkipChapter: Bool { hasChapters && allowsSeeking }

    /// 跳章节:走 `seek` 的分派 —— 转码流必须由客户端重新起流(API_CONTRACT.md 4.5),
    /// ⛔ 不能设 mpv 的 `chapter` 属性让内核自己 seek(会静默失败或跳回 0)。
    func seekToChapter(_ chapter: MPVChapter) {
        guard canSkipChapter else { return }
        seek(to: chapter.time)
        flash(chapter.displayName, systemImage: "list.bullet.rectangle")
    }

    func skipChapter(by delta: Int) {
        guard canSkipChapter else { return }
        let target = delta >= 0 ? nextChapter : previousChapter
        guard let target else { return }
        seekToChapter(target)
    }

    /// 离本章起点多近算「已经在本章开头」(再按上一章才退到前一章)
    private static let chapterRestartTolerance: Double = 1

    // MARK: 画面适配

    /// 套用一整组画面设置。失败只留痕不挂 `failure`:画面修正不上不该挡住播放(与字幕外观一致)。
    func setPicture(_ new: PictureSettings) {
        let target = new.clamped
        picture = target
        guard let player else { return }
        do {
            try player.setPicture(target)
        } catch {
            Self.logger.error("画面适配设置失败: \(String(describing: error), privacy: .public)")
        }
    }

    func setPictureFit(_ fit: PictureSettings.Fit) {
        var next = picture
        next.fit = fit
        setPicture(next)
        flash(fit.displayName, systemImage: "rectangle.inset.filled")
    }

    /// 缩放一档约 7%;夹在 `PictureSettings.zoomRange`(50%–200%)内。
    func stepPictureZoom(up: Bool) {
        var next = picture
        next.zoom += up ? PictureSettings.zoomStep : -PictureSettings.zoomStep
        setPicture(next)
        flash(Self.zoomText(next.zoom),
              systemImage: up ? "plus.magnifyingglass" : "minus.magnifyingglass")
    }

    func resetPictureZoom() {
        var next = picture
        next.zoom = 0
        setPicture(next)
        flash(Self.zoomText(0), systemImage: "1.magnifyingglass")
    }

    /// 顺时针 90°:0 → 90 → 180 → 270 → 0(手机竖拍 / 元数据标错时用)
    func rotatePicture() {
        var next = picture
        let rotations = PictureSettings.rotations
        let index = rotations.firstIndex(of: next.rotation) ?? 0
        next.rotation = rotations[(index + 1) % rotations.count]
        setPicture(next)
        flash("旋转 \(next.rotation)°", systemImage: "rotate.right")
    }

    func setPictureAspect(_ aspect: PictureSettings.Aspect) {
        var next = picture
        next.aspect = aspect
        setPicture(next)
        flash(aspect.displayName, systemImage: "arrow.left.and.right")
    }

    /// 整组复位(默认值就是 mpv 默认,不持久化)
    func resetPicture() {
        setPicture(.default)
        flash("画面已复位", systemImage: "arrow.counterclockwise")
    }

    /// 动过画面设置(菜单里「复位」的启用判据,也是跨集要不要带过去的判据)
    var isPictureAdjusted: Bool { picture != .default }

    /// 「缩放 113%」
    private static func zoomText(_ zoom: Double) -> String {
        var value = PictureSettings.default
        value.zoom = zoom
        return "缩放 \(value.clamped.zoomPercent)%"
    }

    // MARK: 字幕外观

    /// 把字幕外观偏好套到 mpv(设置改了由 `PlayerWindowView` 的 onChange 调;新建 mpv 也走这里)。
    func applySubtitleStyle() {
        guard let player else { return }
        applySubtitleStyle(container.subtitleStyles.style, to: player)
    }

    private func applySubtitleStyle(_ style: SubtitleStyle, to player: MPVPlayer) {
        do {
            try player.setSubtitleProperties(style.mpvProperties)
        } catch {
            // 外观设不上不影响播放,不挂 failure;但要留痕,否则「设置改了没反应」无从查起。
            Self.logger.error("字幕外观设置失败: \(String(describing: error), privacy: .public)")
        }
    }

    /// 新建的 mpv:把本集的字幕延迟与外观偏好设上。
    /// ⛔ 要在挂事件桥**之前**调用 —— 否则屏显会先闪一下 0。
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

    /// 新建的 mpv:把本集的音频延迟与画面适配设上(转码 seek / 重试会换播放器,这两项要跟过去)。
    /// 时机同 `applySubtitleSettings`:挂事件桥之前,免得屏显先闪一下默认值。
    private func applyPlaybackAdjustments(to player: MPVPlayer) {
        if requestedAudioDelay != 0 {
            do {
                try player.setAudioDelay(requestedAudioDelay)
            } catch {
                let delay = requestedAudioDelay
                Self.logger.error(
                    "音频延迟 \(delay, privacy: .public) 秒设回新建播放器失败: \(String(describing: error), privacy: .public)")
            }
        }
        guard picture != .default else { return }
        do {
            try player.setPicture(picture)
        } catch {
            Self.logger.error("画面适配设回新建播放器失败: \(String(describing: error), privacy: .public)")
        }
    }

    /// 挂本次会话的外挂字幕(百度侧同目录 `.srt` / `.ass` …)。只挂一次(见 `didAddExternalSubtitles`),否则菜单堆同名轨。
    /// 失败不打断播放(附加轨),但要一句 OSD 说清哪几条没挂上(`CLAUDE.md` 硬规则 4)。
    /// `auto`:用户还没选过字幕轨时自动选它,真正的选择仍走 `sid`(`selectSubtitleTrack`)。
    private func addExternalSubtitlesIfNeeded() {
        guard !didAddExternalSubtitles else { return }
        didAddExternalSubtitles = true
        // 每个新播放器都恢复一次:转码 seek / 重试会换播放器,手动挂的字幕要跟过去
        restoreRememberedSubtitle()
        guard let player, let session, !session.externalSubtitles.isEmpty else { return }
        var failed: [String] = []
        for subtitle in session.externalSubtitles {
            do {
                try player.addSubtitle(url: subtitle.url, title: subtitle.title)
            } catch {
                failed.append(subtitle.title ?? subtitle.url.lastPathComponent)
                Self.logger.error(
                    "外挂字幕加载失败 \(subtitle.title ?? "-", privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        guard !failed.isEmpty else { return }
        flash("外挂字幕加载失败:\(failed.joined(separator: "、"))", systemImage: "captions.bubble")
    }

    /// 文件选择面板本身失败(不是用户取消)。⛔ 不静默:面板打不开也是事实。
    func reportSubtitlePickerFailure(_ error: Error) {
        flash("选择字幕文件失败:\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
    }

    /// 挂一条用户从磁盘选的字幕(控制栏「字幕 › 打开本地字幕…」)。
    /// 先复制进容器(`SubtitleFileStore`,顺手把 GBK / BIG5 转成 UTF-8),再 `sub-add` 并选中。
    /// ⚠️ `sub-add` 要求文件已加载,所以先按 `phase` 判一次并给人话,不把 mpv 错误码抛给用户。
    func attachLocalSubtitle(at url: URL) {
        guard phase == .playing || phase == .paused else {
            flash("画面出来后才能加载字幕", systemImage: "captions.bubble")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let stored = try await self.container.subtitleFiles.importLocalFile(at: url)
                try self.attach(stored, assrtID: nil)
            } catch {
                self.reportSubtitleFailure(error, fileName: url.lastPathComponent)
            }
        }
    }

    // MARK: - 在线字幕(assrt)

    /// 在线字幕搜索框的初始关键词:复用 `DanmakuMediaQuery`,⛔ 不另造一套来源判断。
    /// ⚠️ 只给作品名不拼季集号(assrt 没有集数参数,「剧名 S01E03」会把全集条目筛掉)。
    var subtitleSearchKeyword: String { danmaku.query.title }

    /// 搜在线字幕。失败如实抛给面板显示,⛔ 不在这里吞掉。
    func searchSubtitles(keyword: String) async throws -> [SubtitleSearchResult] {
        try await container.subtitleService.search(keyword: keyword)
    }

    /// 下载一条在线字幕并挂上,返回名字;下载与落盘在 `SubtitleService` 里,这里只管 `sub-add`。
    @discardableResult
    func downloadSubtitle(_ result: SubtitleSearchResult) async throws -> String {
        let stored = try await container.subtitleService.download(result)
        try attach(stored, assrtID: result.id)
        return stored.title
    }

    /// 把已落盘的字幕挂到当前播放器并记成这一集的字幕(本地 / 在线 / 自动恢复共用)。
    /// `assrtID`:在线字幕的 id(缓存清掉后凭它重取);`quiet`:换播放器后重挂,不提示也不写记录。
    private func attach(
        _ stored: SubtitleFileStore.Stored, assrtID: Int?, announcement: String? = nil, quiet: Bool = false
    ) throws {
        guard let player, phase == .playing || phase == .paused else {
            throw SubtitleAttachError.notPlaying
        }
        try player.addSubtitle(url: stored.url, title: stored.title, flags: .select)
        // 用户显式选了字幕:起播偏好让位,否则下一次 track-list 会把它顶掉
        hasUserChosenSubtitle = true
        sessionSubtitle = (stored, assrtID)
        guard !quiet else { return }
        flash(announcement ?? "字幕:\(stored.title)", systemImage: "captions.bubble")
        remember(stored, assrtID: assrtID)
    }

    /// 记下这一集用的字幕并刷新文件使用时间(缓存清理按它判断);写失败要说出来,否则下次查不到原因。
    private func remember(_ stored: SubtitleFileStore.Stored, assrtID: Int?) {
        let key = danmaku.query.itemKey
        let binding = SubtitleBindingStore.Binding(
            relativePath: stored.relativePath, title: stored.title, assrtID: assrtID, lastUsed: Date())
        let bindings = container.subtitleBindings
        let files = container.subtitleFiles
        Task { [weak self] in
            do {
                try await bindings.bind(binding, for: key)
                try await files.markUsed(relativePath: stored.relativePath)
            } catch {
                Self.logger.error("记住字幕失败:\(String(describing: error), privacy: .public)")
                self?.flash("没能记住这条字幕:\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
            }
        }
    }

    /// 自动挂上这一集上次用的字幕(`SubtitleBindingStore`)。
    /// 文件还在缓存就直接挂;被清掉的在线字幕按 assrt id 重取;本地字幕无从重取,提示并删记录。
    /// ⚠️ 恢复带 `select`;之后用户在菜单里改选别的轨,记录不变。
    private func restoreRememberedSubtitle() {
        if let current = sessionSubtitle {
            // 本次播放已经挂过(换了播放器):文件就在手上,同步重挂
            do {
                try attach(current.stored, assrtID: current.assrtID, quiet: true)
            } catch {
                reportSubtitleFailure(error, fileName: current.stored.title)
            }
            return
        }
        let key = danmaku.query.itemKey
        let generation = self.generation
        let player = self.player
        Task { [weak self] in
            guard let self,
                  let binding = await self.container.subtitleBindings.binding(for: key) else { return }
            do {
                let stored: SubtitleFileStore.Stored
                if let cached = await self.container.subtitleFiles.existingFile(relativePath: binding.relativePath) {
                    stored = cached
                } else if let assrtID = binding.assrtID {
                    stored = try await self.container.subtitleService.download(assrtID: assrtID)
                } else {
                    try await self.container.subtitleBindings.unbind(itemKey: key)
                    self.flash("上次用的本地字幕「\(binding.title)」已被清理,需要重新选择", systemImage: "captions.bubble")
                    return
                }
                // 等待期间播放器换了(新播放器会自己恢复)或用户已手动挂别的:放弃。
                guard self.generation == generation, self.player === player,
                      self.sessionSubtitle == nil else { return }
                try self.attach(stored, assrtID: binding.assrtID, announcement: "字幕:已挂上上次用的「\(stored.title)」")
            } catch {
                guard self.generation == generation else { return }
                self.reportSubtitleFailure(error, fileName: binding.title)
            }
        }
    }

    /// 字幕失败统一出口:一句 OSD + 一条日志。⛔ 不静默、不弹对话框打断播放。
    private func reportSubtitleFailure(_ error: Error, fileName: String) {
        let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        flash("字幕加载失败:\(reason)", systemImage: "exclamationmark.triangle")
        Self.logger.error(
            "字幕加载失败 \(fileName, privacy: .public):\(String(describing: error), privacy: .public)")
    }

    /// 按步长加 / 减(`[` `]` 与倍速菜单的「加快 / 减慢」);已经贴着区间端点就不动。
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

    /// 拖动到指定秒数。⛔ 三条路不是同一件事(API_CONTRACT.md 4.5):
    /// 直连交给内核 seek;能重新起流的转码是「停流 + 带起流点重取一路」;
    /// 拖不动的源(如百度转码流)如实说一句,⛔ 不装作拖成功了。
    /// 判据一律取 `session.seekStrategy`,⛔ 不按 `plan.method` 反推(两边转码流都用 `.transcode`)。
    /// 转码带合并:连点只在停下来时起一次流(`seekRestartMergeDelay`);`positionSeconds` 仍立即更新。
    func seek(to seconds: Double) {
        guard let session else { return }
        let target = max(0, min(seconds, durationSeconds > 0 ? durationSeconds : seconds))
        switch session.seekStrategy {
        case .clientSeek:
            do {
                try player?.seek(to: target)
            } catch {
                // 内核没加载好文件时 seek 一律返回 -12(PITFALLS):不是播放失败,
                // ⛔ 不占错误位、也 ⛔ 不先把进度条跳过去(否则上报也跟着错)。
                flash("拖动失败", systemImage: "exclamationmark.triangle")
                return
            }
            positionSeconds = target
            // 5.2:拖动结束立即上报,不等 10 秒定时器
            pushState()
            reportNow(.timeUpdate)

        case .restartStream:
            positionSeconds = target
            scheduleRestartStream(at: target)

        case .unsupported(let reason):
            // ⛔ 不动 `positionSeconds`、不上报:否则「继续观看」会记到没播到的点。
            flash(reason, systemImage: "nosign")
        }
    }

    /// 转码 seek 的合并起流:等 `seekRestartMergeDelay` 内没有新 seek 再起流。
    /// ⛔ 拖动也要走合并:否则残留任务会以不同的目标位置起流,这里统一收敛到最后一次。
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
            // 三重判据:没被取消、self 还在、代次没被 stop() / 新 seek 推进。
            // 最后一条是关键:过了 sleep 的任务 cancel 不掉,没代次会在关窗后自己起流。
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

    /// 键盘调音量(↑ ↓,步长 `Metrics.volumeStep`);顺带解除静音,否则按 ↑ 听不到声音像没生效。
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
    /// 选过之后起播默认偏好让位(`applyPreferredSubtitle()` 不再覆盖),否则会被回推的 track-list 顶掉。
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
    /// 只在 track-list 首次到达时做,用户手动选过之后不再介入。
    /// ⛔ 不起 OSD、不发 `SubtitleTrackChange`:这不是用户操作,索引由首次 Progress 带上去。
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
            // 乐观更新;mpv 随后会重推 track-list 按 `selected` 读回覆盖。
            selectedSubtitleTrackID = id
        } catch {
            // 设不上就保持原状:mpv 下次重推 track-list 时会再判一次
        }
    }

    /// 换到下一集:写一个新请求(沿用本页 `pageID`),播放页保留、只换会话(`PlayerWindowView.switchSession`);
    /// 本 ViewModel 随之 `stop()` 走完收尾。
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

    /// 换到某一集:装配新请求交给播放窗口(换集 = 换请求)。
    /// 队列只给文件树来源(兄弟集丢了要再列目录、烧百度配额);Emby 的兄弟集在服务端,新页自己查更全。
    private func switchToEpisode(_ episode: PlaybackEpisode?) {
        guard let episode else { return }
        stopUpNextCountdown()
        // 文件树来源:补记「继续观看」快照,⛔ 不能等渲染续播区时再列目录(百度配额)。
        if let item = episode.resumeItem, let file = episode.source.file {
            Task { await container.rememberResumeCard(item: item, file: file) }
        }
        let carried = episode.source.file != nil ? episodeQueue?.selecting(episode) : nil
        // 沿用本页的 `pageID`:播放窗口据此只换会话、不重建播放页(见 `PlaybackRequest`)
        container.play(PlaybackRequest(
            source: episode.source,
            episodeQueue: carried,
            // 这一集的外挂字幕随队列带过来 —— 换集时文件列表已经不在手上
            subtitleFiles: episode.subtitleFiles,
            continuingPage: request.pageID))
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

    /// 落库 + 立即生效 + 屏显反馈:内存先改、落盘异步(标注要立刻影响跳过按钮)。
    /// 写盘失败不静默吞(硬规则 4),内存里的改动保留。
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
        statisticsEpoch &+= 1
        if showsStatistics {
            // 唤醒唯一 worker;在途轮不取消,最多合并一个待刷轮,不因反复开关堆积核心读取。
            monitorRequests?.yield(())
        } else {
            statistics = nil
        }
    }

    /// 低频 timer 只发刷新信号,唯一 worker 串行 await(长读取不占 MainActor)。
    /// bufferingNewest(1) 合并慢核心期间的 tick;internal 供无网络测试安装空闲 mpv。
    func startMonitoring(player: MPVPlayer) {
        monitorRequests?.finish()
        monitorTimerTask?.cancel()
        monitorTask?.cancel()
        self.player = player
        let requests = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        monitorRequests = requests.continuation
        monitorTask = Task { [weak self] in
            defer { requests.continuation.finish() }
            for await _ in requests.stream {
                guard !Task.isCancelled else { return }
                // 强引用只维持单轮;在等下一次 tick 时不永久持有 ViewModel。
                guard let self else { return }
                await self.refreshMonitoredProperties()
            }
        }
        monitorTimerTask = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(Metrics.playerMonitorInterval)) } catch { return }
                if case .terminated = requests.continuation.yield(()) { return }
            }
        }
        if showsStatistics { requests.continuation.yield(()) }
    }

    private func refreshMonitoredProperties() async {
        guard let player else { return }
        let generation = generation
        let statisticsEpoch = statisticsEpoch
        let bufferingEpoch = bufferingEpoch
        let readsStatistics = showsStatistics
        let readsBuffering = isBuffering
        var names = ["demuxer-cache-time"]
        if readsBuffering { names += ["cache-buffering-state", "cache-speed"] }
        if readsStatistics { names += PlayerStatistics.propertyNames }
        let values: [String: String]
        do {
            values = try await readMonitoredProperties(player, names)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, self.generation == generation, self.player === player else { return }
            Self.logger.error("播放监控属性读取失败:\(String(describing: error), privacy: .public)")
            return // 诊断失败不能盖住正常视频;不伪造空字典或覆盖旧读数。
        }
        guard !Task.isCancelled, self.generation == generation, self.player === player else { return }
        bufferedUntilSeconds = values["demuxer-cache-time"].flatMap(Double.init)
        if readsBuffering, isBuffering, self.bufferingEpoch == bufferingEpoch {
            bufferingPercent = values["cache-buffering-state"].flatMap(Int.init)
            cacheSpeedBytesPerSecond = values["cache-speed"].flatMap(Double.init)
        }
        if readsStatistics, showsStatistics, self.statisticsEpoch == statisticsEpoch {
            statistics = PlayerStatistics(
                properties: values, session: session,
                renderBackend: player.statisticsSnapshot().renderBackend)
        }
    }

    private func flash(_ text: String, systemImage: String) {
        osd = PlayerOSD(text: text, systemImage: systemImage)
    }

    /// 查本季分集装配队列,再定出上一集 / 下一集。
    /// 队列成员只有本季;边界处跨季补查的上一集 / 下一集不进队列。
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
            // 上一集 / 下一集是附加功能:查不到只是不显示入口,不弹错误(错误位留给播放本身)。
            return
        }
    }

    /// `EmbyItem` → `PlaybackEpisode`(Emby 进度走服务端,`resumeItem` 为 nil)。
    /// 封面取分集自己的 `Primary`(`landscapeImage` 第一条),没有才退到 Thumb / Backdrop,与 `EpisodeCard` 同口径。
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
        // 只在起播慢时附带 mpv 明细:每次都写会很快顶满 256KB 日志、清掉失败记录。
        if timeline.isSlow {
            NetworkDiagnostics.recordTimingDetail(
                host: session.plan.url.host(), mpvLog: player?.recentLogLines() ?? [])
        }
    }

    private func prepareAndLoad() async {
        do {
            // 会话准备按来源装配(Emby 决策器 / 百度播放映射),⛔ 播放页不认具体来源。
            var prepared = try await preparer.makeSession(
                startTimeTicks: nil, mediaSourceID: preferredSourceID)
            try Task.checkCancellation()
            // 能重新起流的转码 + 非零起播:4.5 规定服务端从 StartTimeTicks 处起流。先取一次再带值,
            // 是因为 StartTimeTicks 也是决策输入 —— 一上来就带可能把本可 DirectStream 的文件推去转码。
            // ⛔ 判据是 `seekStrategy` 而不是 `plan.method`:拖不动的源重取也只会从头开始。
            if prepared.seekStrategy == .restartStream, startSeconds > 0 {
                prepared = try await preparer.makeSession(
                    startTimeTicks: TickConverter.ticks(fromSeconds: startSeconds),
                    mediaSourceID: preferredSourceID)
                try Task.checkCancellation()
            }
            session = prepared
            // 来源自己知道的权威总时长(百度转码流未转完时内核只看到已转那段);Emby 返回 nil。
            if let authoritative = await preparer.authoritativeDurationSeconds, authoritative > 0 {
                durationSeconds = authoritative
            }
            markTimeline(.playbackInfo)
            serverMarkers = PlaybackMarkers(chapters: prepared.mediaSource.chapters)
            // 手动标注(同一部剧共用)读回来与服务端合并,手动优先(重新起流时会再读一次)。
            manualMarkers = await container.manualMarkers.record(for: manualMarkersScopeKey)
            refreshMarkers()

            // 渲染后端策略见 MPVRenderBackendPolicy;新播放器 = 新字幕轨列表,重试 / 起流都要重挂字幕。
            // 码率给缓冲预算标定(MPVCacheBudget):回退命中身后缓冲才不用重新拉流。
            didAddExternalSubtitles = false
            // 新播放器 = 新文件:上一集的章节刻度不能留在进度条上(转码流的新章节可能永远不来)
            chapters = []
            let player = MPVPlayer(
                backendPolicy: container.preferences.renderBackendPolicy,
                bitrateBitsPerSecond: prepared.mediaSource.bitrate)
            // `MPVPlayer.init` 的失败路径都是直接 return,只写 `initializationFailure` 不抛错。
            // 不在这里查就会一路走到 glAttached 轮询,2s 后误报成「渲染上下文超时」,
            // 把真正原因(mpv_create NULL / 选项被拒 / initialize 失败)丢掉(docs/PITFALLS.md Q1)。
            if let reason = player.initializationFailure {
                player.shutdown()
                isPreparing = false
                failure = LoadFailure(message: "播放器初始化失败:\(reason)")
                return
            }

            // 新 mpv 是默认值(1× / 音量 100 / 无字幕延迟):把起播偏好设回去,都在挂事件桥之前。
            applyRememberedSpeed(to: player)
            applyDefaultVolume(to: player)
            applySubtitleSettings(to: player)
            applyPlaybackAdjustments(to: player)

            let generation = self.generation
            let bridge = MPVEventBridge { [weak self] event in
                self?.handle(event, generation: generation)
            }
            player.attach(eventBridge: bridge)
            // 先挂出去让视图把 GL layer 建起来,再等上下文就绪
            self.player = player
            startMonitoring(player: player)

            let deadline = Date().addingTimeInterval(Self.glAttachTimeout)
            while !player.statisticsSnapshot().glAttached, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard player.statisticsSnapshot().glAttached else {
                // 与「服务端没给可播路径」不同:渲染上下文没建起来,重开一次通常就好。
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

    /// 用户手选的版本(`MediaSource.Id`),初值来自详情页的选择。nil = 按默认规则。只在本页本集内有效:换集是新 ViewModel。
    private var preferredSourceID: String?

    /// 同一部片的多版本;少于两个时不给选项。
    var versionOptions: [EmbyMediaSource] { session?.availableSources ?? [] }

    /// 切到另一个版本:从当前位置重新起流(与转码 seek 同一条路径,旧会话先收尾上报)。
    func selectVersion(_ id: String) {
        guard let session, session.mediaSource.id != id,
              session.availableSources.contains(where: { $0.id == id }) else { return }
        preferredSourceID = id
        restartStream(at: positionSeconds)
    }

    /// 转码 seek 的重新起流:停旧会话 → 拆 mpv(断开即停流)→ 带新 StartTimeTicks 重新准备(4.5)。
    private func restartStream(at seconds: Double) {
        // stop() 内部会发最终 Progress + Stopped(6.6:切换流即结束旧会话)
        stop()
        // ⛔ 必须在 stop() **之后**置位:stop() 会把 isRestarting 复位,写在前面会被冲掉。
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

    /// 播放期是否该阻止显示器休眠:对齐 mpv `stop-screensaver=yes`(⛔ 不是 `=2` 始终抑制),只有正在播放才抑制。
    /// - `phase == .playing`:暂停 / 加载 / 失败各有别的 phase;
    /// - `!isPaused`:起播前就暂停时 phase 仍会随 FILE_LOADED 变 `.playing`(mpv 先报文件就绪再报 pause);
    /// - `!isEnded`:播完时 phase 停在 `.playing`(§8 无「已结束」态,`docs/PITFALLS.md` Q7)。
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
    /// 轨道索引换算成 Emby 的 `MediaStream.Index`(`StreamIndexMapper`,docs/PITFALLS.md Q21);
    /// 对不齐或字幕关闭时省略该键 —— ⛔ 不发 0,0 是一条真实轨道的索引。
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

    /// 合并连续倍速变化的上报(连点微调 / 按住 `[` `]`),见 `.speed` 事件处的说明。
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
        // 串在上一次收尾之后(播完再关窗会先后调两次),保证 `waitUntilReportingFinished` 等的是最后那次 drain。
        reportingFinishTask = Task { [reporter] in
            await previous?.value
            await reporter.finish(finalState: snapshot, sendFinalProgress: sendFinalProgress)
            await reporter.drain()
        }
    }

    /// 等本轮收尾上报(最终 Progress + Stopped)发完,并等本地续播库那笔写完
    /// (详情页据此再读续播位置,docs/PITFALLS.md Q22);从未收尾时立即返回。
    /// ⚠️ 文件树来源那笔要等:续播区在同一个广播后刷新,不等会读到还没写进去的库。
    func waitUntilReportingFinished() async {
        await reportingFinishTask?.value
        await fileSourceFinishTask?.value
    }

    /// 文件树来源一场播放的收尾:播完落成已看,已看就补下一集占位(`AppContainer.settleFileSourceEpisode`)。
    /// ⚠️ 先等最终进度落盘再判已看,反过来的话「播到 99%」会把状态翻回「进行中」。
    private func settleFileSourceEpisode(naturalEnd: Bool) {
        let playing = request.source
        guard playing.file != nil else { return }
        let queue = episodeQueue
        let final = reportState
        let previous = reportingFinishTask
        let previousSettle = fileSourceFinishTask
        fileSourceFinishTask = Task { [container] in
            await previous?.value
            await previousSettle?.value
            await container.settleFileSourceEpisode(
                playing,
                queue: queue,
                naturalEnd: naturalEnd,
                endedAt: final.positionSeconds,
                durationSeconds: final.durationSeconds)
        }
    }

    // MARK: - 事件

    /// mpv 事件入口。`generation` 是发出事件的播放器实例建立时的代次,不符即丢弃。
    /// (`internal` 而非 `private`:`PlayerViewModelTests` 要直接验这条门。)
    func handle(_ event: MPVPlayerEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .phaseChanged(let newPhase):
            phase = newPhase
            updateDisplaySleepAssertion()
            if newPhase == .playing {
                markTimeline(.playing)
                // `sub-add` 要文件加载完:`.playing` 是第一个保证这点的时点,且字幕轨与起播位置无关。
                addExternalSubtitlesIfNeeded()
                // DirectStream 的恢复位置只能由客户端 seek(转码在起流时就带了 StartTimeTicks)。
                if !didApplyStartOffset {
                    didApplyStartOffset = true
                    if startSeconds > 0, session?.plan.method == .directStream {
                        do {
                            try player?.seek(to: startSeconds)
                            positionSeconds = startSeconds
                        } catch {
                            // 恢复位置失败不打断播放(流是好的);认定位置可信,否则片头 / 下一集永远不评估。
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
            // 5.2 要求改倍速立即上报,但连续调节(0.05 一跳)会打出十几个请求,
            // 所以合并成一次:停手 `Metrics.speedReportDelay` 后发最后那个值。
            // `pushState()` 每次都走,10 秒一次的 Progress 里倍速不会缺。
            scheduleRateChangeReport()

        case .subtitleDelay(let value):
            // 不上报:5.1 的 `SubtitleOffset` 单位未核实(KNOWN_ISSUES.md Q39),发错单位比不发更糟。
            subtitleDelay = value

        case .audioDelay(let value):
            // 纯客户端修正,服务端没有对应字段(与字幕延迟同理)
            audioDelay = value

        case .chapterList(let list):
            chapters = list

        case .buffering(let value):
            if value != isBuffering { bufferingEpoch &+= 1 }
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

        case .firstVideoFrameRendered:
            hasRenderedFirstVideoFrame = true
            frozenPlayer = nil

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
            hasNoVideoTrack = !tracks.isEmpty && !tracks.contains { $0.type == .video }
            audioTracks = tracks.filter { $0.type == .audio }
            subtitleTracks = tracks.filter { $0.type == .sub }
            // 读回验证(第 7 节:设置 aid/sid 后要读回,不能假设设置即生效);`selected` 就是读回结果。
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
            // 文件树来源:落成「已看」+ 补「下一集」占位,否则续播区会停在上一集
            // (Emby 由服务端算 NextUp)。
            settleFileSourceEpisode(naturalEnd: true)
            // 没有片尾标记也没赶上结束前提示时,播完卡片同样按设置倒计时播下一集。
            if autoPlayNext, upNextCountdown == nil { startUpNextCountdown() }

        case .endFile(.error(let message)):
            // mpv 侧失败(拉流 401 / 解码 / 容器不支持)走这里,文案要与 PlaybackError 区分。
            failure = LoadFailure(message: "播放失败:\(message)")
            // 错误码看不出 libmpv 收到了什么,连同最近日志脱敏后落诊断日志(不含 token)。
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

    /// time-pos 是否已可信:只有 DirectStream + 非零续播点才需要等(此前 mpv 报的是文件开头),转码流没有这一步。
    static func isSettledPosition(_ value: Double, startSeconds: Double, method: PlaybackMethod?) -> Bool {
        guard startSeconds > 0, method == .directStream else { return true }
        return abs(value - startSeconds) < settledPositionTolerance
    }

    /// 「已到续播点附近」的容差(秒):3 秒够覆盖首个 time-pos 的延迟,又不会把文件开头误判为就位。
    private static let settledPositionTolerance: Double = 3
}

/// 字幕挂不上的原因(与网络、文件无关,纯粹是播放器还没就绪)。
/// 单独成类型:这条要原样显示给用户,而 `MPVError` 的文案是给排查用的。
enum SubtitleAttachError: LocalizedError, Equatable {
    /// 文件还没加载完(`sub-add` 在 `no file loaded` 时必失败)
    case notPlaying

    var errorDescription: String? {
        switch self {
        case .notPlaying: return "画面出来后才能加载字幕"
        }
    }
}
