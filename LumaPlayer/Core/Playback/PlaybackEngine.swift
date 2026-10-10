import AVFoundation
import Foundation

/// 播放内核的失败。**不含**服务端错误(那些在决策阶段就已经抛掉了)。
enum PlaybackEngineFailure: Error, Equatable {
    /// `AVPlayerItem` 在就绪上限内没进 `readyToPlay`
    case notReady(detail: String)
    /// 起播后预期存在的轨没出现(R12 静默删轨)
    case missingTracks([String])
    /// 播放过程中失败(`AVPlayerItem.status == .failed` / 播放中断通知)
    case playback(String)

    var userMessage: String {
        switch self {
        case .notReady(let detail):
            return "播放器准备超时:\(detail)"
        case .missingTracks(let dimensions):
            return "播放流里没有\(dimensions.joined(separator: "、"))轨 —— "
                + "这个格式本机放不了(系统把不认识的轨静默丢掉了)。"
        case .playback(let detail):
            return "播放失败:\(detail)"
        }
    }
}

/// 播放内核的状态变化。播放窗口据此把值搬进自己的 `@Observable` 状态并驱动 UI。
///
/// ⚠️ 事件里携带的是**变化项**,不是全量快照 —— 快照直接读内核属性。
/// 从任意线程调用都会有,但回调固定在主 actor 上执行。
///
/// ⚠️ `position` 是**内核时间原点上的位置**,不是绝对媒体位置:转码流的时间原点
/// 在起流点(见 `PlaybackTimeBase` 与文档 R13)。换算由播放层做,内核不认识 Emby。
enum PlaybackEngineEvent: Equatable {
    case phase(PlaybackPhase)
    case position(Double)
    case duration(Double)
    case buffered(Double?)
    case paused(Bool)
    case rate(Double)
    case volume(Double)
    case muted(Bool)
    case tracksChanged
    /// 起播后的轨核验结论(`unverifiable` 与 `satisfied` 都不是失败)
    case tracksValidated(TrackExpectation.Outcome)
    case ended
    case failed(PlaybackEngineFailure)
}

/// 播放内核的接口(内核是什么圈在一个协议后面)。
///
/// ## 为什么是协议而不是直接依赖 `AVKitPlaybackKernel`
///
/// 上层的播放页(`PlayerViewModel`)要写的是**接线**:什么时候 seek、什么时候上报、
/// 倍速怎么跨集记忆、偏好什么时候套上去。这些规则与「内核是 AVKit 还是别的」无关,
/// 却只有在**换掉内核**时才测得动 —— 本机 `xcodebuild test` 起不了 App
/// (`docs/KNOWN_ISSUES.md` Q34),真实 `AVPlayer` 也不该拖进单测。
///
/// 所以内核行为收在一个协议里,`PlayerViewModel` 只认这一层语义
/// (与 `ARCHITECTURE.md` 6.4「上层依赖的是语义不是内核类型」同一条),
/// 单测注入替身即可覆盖接线规则。
///
/// ## 实现者必须满足的三条(来自 P3 实测)
///
/// 1. **不自动起播**:`load` 只把流放好,之后就绪即 `.paused`,要播必须显式 `play()`。
/// 2. **起播后核轨**:AVFoundation 对不认识的编码是静默删轨,`errorLog` 是空的。
/// 3. **`phase` 里没有「已结束」态**:播完停在 `.playing`,靠 `isEnded` 判
///    (`docs/PITFALLS.md` Q7),`PlaybackRules.shouldPreventDisplaySleep` 依赖这一条。
@MainActor
protocol PlaybackEngine: AnyObject {

    /// 交给播放表面的 `AVPlayer`。⛔ 这是把 AVFoundation 对象漏出去的唯一一处,
    /// 别的都走下面的语义属性。
    var player: AVPlayer { get }

    // MARK: - 状态

    var phase: PlaybackPhase { get }
    var plan: PlaybackPlan? { get }
    var failure: PlaybackEngineFailure? { get }

    /// **内核时间原点上的**位置(秒)。转码流要补偏移才是绝对媒体位置。
    var positionSeconds: Double { get }
    var durationSeconds: Double { get }
    /// 已缓冲到的位置(秒);读不到时为 nil(不填 0 假装已缓冲)
    var bufferedUntilSeconds: Double? { get }
    /// 倍速(1 = 正常速度)
    var rate: Double { get }
    /// 0–100(`Metrics.volumeRange`)
    var volume: Double { get }
    var isMuted: Bool { get }
    /// **期望**的暂停态(不是 `timeControlStatus` 的读数)
    var isPaused: Bool { get }
    var isEnded: Bool { get }

    var audioTracks: [PlaybackTrack] { get }
    var subtitleTracks: [PlaybackTrack] { get }
    var selectedAudioTrackID: Int? { get }
    /// nil = 字幕关闭
    var selectedSubtitleTrackID: Int? { get }

    /// 起播后的轨核验结论;nil = 还没核过
    var trackValidation: TrackExpectation.Outcome? { get }

    /// 事件出口。播放窗口在这里接上。
    var onEvent: ((PlaybackEngineEvent) -> Void)? { get set }

    // MARK: - 命令

    /// 放一条流(不自动起播)。
    ///
    /// - Parameter sourceStreams: 选中那条 `MediaSource.MediaStreams`,用于起播后的轨核验。
    ///   `nil`(服务端没给)时核验结论为 `unverifiable` —— ⛔ 不等于「核实过没问题」。
    func load(plan: PlaybackPlan, sourceStreams: [EmbyMediaStream]?) async throws

    /// 拆掉当前这次播放(关窗、换内容、转码重新起流都走它)。幂等。
    func teardown()

    /// 开始 / 继续播放。⛔ 只有这里会把画面放起来。
    func play()
    func pause()

    func setRate(_ value: Double)
    func setVolume(_ value: Double)
    func setMuted(_ muted: Bool)

    /// 跳转。⚠️ 语义按内核时间原点计:调用方负责换算(见 `PlaybackTimeBase`)。
    func seek(to seconds: Double) async

    func selectAudioTrack(_ id: Int)
    /// nil = 关字幕
    func selectSubtitleTrack(_ id: Int?)
}
