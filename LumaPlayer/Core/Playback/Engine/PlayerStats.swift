import Foundation

/// 播放统计快照(**与内核无关**),供「按 I 的统计 overlay」显示。
///
/// 这是各内核统计接口的**归一化并集**:适配器把内核的解码 / 渲染 / 输出 / 资源
/// 统计拼成这些字段。某个字段内核给不了就是 `nil`,对应行**不显示**,
/// ⛔ 不填「未知 / 0」占位。
///
/// ⚠️ 语义随内核而异,几个字段在当前内核(Erika)下是近似值:
/// - `droppedFrames` 取内核的「背压丢帧」计数,不是显示端丢帧;
/// - `colorPrimaries` / `colorTransfer` 是内核给的色彩枚举码,已知码转成人读名,
///   未知码原样显示数字(不猜);
/// - `memoryBytes` 取渲染器跟踪的显存占用,不是整机显存。
/// 这些在 docs/KNOWN_ISSUES.md 里登记为待真机核实项。
struct PlayerStats: Sendable, Equatable {
    // 视频
    var width: Int?
    var height: Int?
    var pixelFormat: String?
    var colorPrimaries: String?
    var colorTransfer: String?
    var frameRate: Double?
    var videoCodec: String?
    var videoBitRate: Int?

    // 解码
    var decoderName: String?
    var isHardwareDecoded: Bool?

    // 音频
    var audioCodec: String?
    var audioSampleRate: Int?
    var audioChannels: Int?
    var audioBitRate: Int?

    // 渲染
    var renderedFrames: Int?
    var droppedFrames: Int?

    // 输出(HDR / EDR)
    var outputMode: String?
    var edrHeadroom: Float?

    // 资源
    var memoryBytes: Int?

    init() {}
}
