import Foundation

/// 播放统计信息 overlay 的内容(按 I 键开关)。
///
/// ## `exp/avkit-rust-core` 上换的是什么
///
/// `main` 上这些行来自 mpv 的属性字典(`MPVPlayer.stringProperties`,键名对照
/// mpv 0.41 的 `--list-properties`)。AVFoundation **没有等价的属性字典**,
/// 所以数据源换成播放层从 AVKit 采到的读数(`Readings`)——
/// 本类型只做格式化,是纯函数,便于测试。
///
/// 某个读数没有时对应的行**直接不显示**,不填「未知」凑数(与 `main` 一致)。
///
/// ## 明确降级的部分(文档第 3 节已列的损失,⛔ 别当成 bug)
///
/// 拿不到的:`cache-buffering-state` / `cache-speed`(缓冲百分比与瞬时网速)、
/// `hwdec-current`(软/硬解)、视频像素格式与色彩空间、`container-fps`、
/// 解码器丢帧。拿得到的是 `AVPlayerItemAccessLog` 的**掉帧数 / 观测码率 /
/// 停顿次数 / 传输耗时**与 `ErrorLog` 的最后一条 —— 够回答「卡不卡、从哪来、错在哪」。
struct PlayerStatistics: Equatable {
    struct Line: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// 播放层采到的原始读数。
    ///
    /// ⛔ 全是 `Sendable` 值类型、不带 AVFoundation 类型:格式化的规则要能脱离
    /// 真实播放器单测(本机起不了 App,见 `KNOWN_ISSUES.md` Q34)。
    struct Readings: Equatable, Sendable {
        /// 决策给的中文播放方式名(Rust 侧生成,Swift 不重拼一份)
        var methodDisplayName: String?
        var container: String?
        var videoWidth: Int?
        var videoHeight: Int?
        var videoTrackCount = 0
        var audioTrackCount = 0
        var subtitleTrackCount = 0
        /// `AVPlayerItemAccessLogEvent.numberOfDroppedVideoFrames`
        var droppedFrameCount: Int?
        /// `observedBitrate`(bit/s)
        var observedBitrate: Double?
        /// `numberOfStalls`
        var stallCount: Int?
        /// 已缓冲到的位置(秒,已是绝对媒体位置)
        var bufferedSeconds: Double?
        var rate: Double?
        /// `AVPlayerItem.status` 的可读名
        var itemStatusText: String?
        /// `ErrorLog` 最后一条(状态码 + 说明)
        var lastErrorText: String?
    }

    let lines: [Line]

    init(readings r: Readings) {
        var lines: [Line] = []
        func add(_ label: String, _ parts: [String?]) {
            let value = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !value.isEmpty { lines.append(Line(label: label, value: value)) }
        }

        add("播放方式", [r.methodDisplayName, r.container?.uppercased()])

        let size: String? = {
            guard let width = r.videoWidth, let height = r.videoHeight else { return nil }
            return "\(width)×\(height)"
        }()
        add("画面", [size])

        add("轨道", [Self.trackCounts(r)])

        add("网络", [
            r.observedBitrate.flatMap(Self.bitrateText).map { "\($0) 实测" },
            r.bufferedSeconds.map {
                "已缓冲 \($0.formatted(.number.precision(.fractionLength(1)))) 秒"
            },
        ])

        add("丢帧", [
            r.droppedFrameCount.map { "掉帧 \($0)" },
            r.stallCount.map { "停顿 \($0) 次" },
        ])

        add("倍速", [r.rate.map(Metrics.speedText)])
        add("状态", [r.itemStatusText, r.lastErrorText])

        self.lines = lines
    }

    /// 「视频 1 · 音频 2 · 字幕 3」;全为 0 时返回 nil(整行不显示)。
    static func trackCounts(_ r: Readings) -> String? {
        var parts: [String] = []
        if r.videoTrackCount > 0 { parts.append("视频 \(r.videoTrackCount)") }
        if r.audioTrackCount > 0 { parts.append("音频 \(r.audioTrackCount)") }
        if r.subtitleTrackCount > 0 { parts.append("字幕 \(r.subtitleTrackCount)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 格式化(internal:单元测试直接验)

    /// bit/s → `8.2 Mbps` / `192 kbps`。0 或不可解析时返回 nil。
    static func bitrateText(_ bits: Double) -> String? {
        guard bits.isFinite, bits > 0 else { return nil }
        if bits >= 1_000_000 {
            return "\((bits / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps"
        }
        return "\(Int((bits / 1000).rounded())) kbps"
    }

    /// `AVPlayerItem.Status` 的可读名。⛔ 不猜未知取值。
    static func statusText(_ rawValue: Int) -> String {
        switch rawValue {
        case 0: return "未就绪"
        case 1: return "已就绪"
        case 2: return "失败"
        default: return "状态 \(rawValue)"
        }
    }
}
