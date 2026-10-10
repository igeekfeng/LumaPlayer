import Foundation

/// 「起播后预期应当存在的轨」以及核验结论(纯函数,可脱离内核单测)。
///
/// ## 为什么需要它
///
/// P3 在本机 AVFoundation 上实测到一条**反直觉**的性质
/// (`docs/DECISIONS/avkit-rust-rearchitecture.md` 2.1 第 2 条 / 风险 R12):
///
/// > AVFoundation 遇到不认识的编码**不报错**,而是把那一条轨从
/// > `AVAssetTrack` / `AVPlayerItemTrack` 列表里**删掉** —— `playable` 仍然是
/// > `true`,`play()` 照样成功,`errorLog` 也是空的。
///
/// 结果就是「有声音没画面」或「有画面没声音」这种**静默失败**:它能骗过所有
/// 计数指标,决策器也没有任何理由报错。所以必须在起播后由客户端**主动核一遍**,
/// ⛔ 不能靠错误日志兜底(它是空的)。
///
/// ## 判定口径
///
/// - 依据是**服务端给的** `MediaStreams` —— 客户端唯一的权威来源。
///   ⛔ 不按文件扩展名猜(`ARCHITECTURE.md` 3.3 已禁止)。
/// - 只要求**视频 / 音频**两维。字幕维**不参与**:源里躺一条位图字幕轨、而用户
///   根本没开字幕时,不该为此判成播放失败(与 Rust 决策器对字幕维的立场一致,
///   文档 8.2「刻意留的两处限制」)。
/// - `MediaStreams` 缺失时**不猜**:返回 `unverifiable`,由调用方如实记录 ——
///   ⛔ 不得当成「核实过没问题」。
///
/// 纯值类型 + 纯函数,无 AVFoundation 依赖:`AVPlayerItem` 那一侧的读数由播放内核
/// 采好再喂进来(`AVKitPlaybackKernel.presentedTracks(item:)`)。
enum TrackExpectation {

    /// 起播后**必须真的存在**的轨。
    struct Requirement: Equatable, Sendable {
        var video: Bool
        var audio: Bool

        /// 什么都不要求(没有可核实的输入时用)
        static let none = Requirement(video: false, audio: false)
    }

    /// 从服务端的 `MediaStreams` 推出「必须存在哪些轨」。
    ///
    /// - Parameter streams: `PlaybackInfo` 响应里**被选中**那条 `MediaSource` 的
    ///   `MediaStreams`。两种传输方式下都成立:
    ///   - DirectStream:客户端拿到的是原始文件,轨构成 == `MediaStreams`;
    ///   - Transcode:输出流的轨构成由服务端决定(可能重编码音频、可能丢掉字幕),
    ///     但服务端不会凭空去掉视频或音频维,所以「有视频源就该有视频轨」依然成立。
    /// - Returns: `nil` 表示这次**没有可核实的输入**,不是「不用核实」。
    static func requirement(forStreams streams: [EmbyMediaStream]?) -> Requirement? {
        guard let streams else { return nil }
        return Requirement(
            video: streams.contains { $0.type == Self.videoStreamType },
            audio: streams.contains { $0.type == Self.audioStreamType }
        )
    }

    /// 起播后**实际**看得到的轨(由播放内核从 `AVPlayerItem` 上读出)。
    struct Presented: Equatable, Sendable {
        var video: Bool
        var audio: Bool

        static let none = Presented(video: false, audio: false)
    }

    /// 核验结论。
    enum Outcome: Equatable, Sendable {
        /// 预期存在的轨都出现了(或本来就不要求任何轨)
        case satisfied
        /// 有**预期存在**的轨没有出现 —— 静默删轨发生了,必须报错
        /// - Parameter missing: 缺失维度的中文名,如 `["视频"]`
        case missing([String])
        /// 没有可核实的输入(`MediaStreams` 缺失),这次只能放过
        case unverifiable
    }

    /// 核验。`requirement == nil` 即 `unverifiable`。
    static func evaluate(requirement: Requirement?, presented: Presented) -> Outcome {
        guard let requirement else { return .unverifiable }
        var missing: [String] = []
        if requirement.video, !presented.video { missing.append(videoDimensionName) }
        if requirement.audio, !presented.audio { missing.append(audioDimensionName) }
        return missing.isEmpty ? .satisfied : .missing(missing)
    }

    // MARK: - 取值

    /// `MediaStream.Type` 的两个取值(`API_CONTRACT.md` 4.3,服务端给的是自由字符串,
    /// 与 `StreamIndexMapper` 里的 `"Audio"` / `"Subtitle"` 同一套拼写)。
    static let videoStreamType = "Video"
    static let audioStreamType = "Audio"

    static let videoDimensionName = "视频"
    static let audioDimensionName = "音频"
}
