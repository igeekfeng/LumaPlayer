import Foundation

/// 播放统计信息 overlay 的内容(按 I 键开关)。
///
/// 输入是**播放器内核的属性读数**(`[属性名: 字符串]`),再加上 Emby 侧的播放方式
/// 与容器。本类型只做格式化,是纯函数,便于测试。
/// 某个属性读不到(内核返回空)时对应的行直接不显示,不填「未知」凑数。
///
/// ⚠️ `exp/avkit-rust-core`:`main` 上这些属性来自 mpv 的
/// `MPVPlayer.stringProperties`,换成 AVKit 后要另找数据源(AVFoundation 没有等价的
/// 属性字典)。但**格式化规则本身与内核对无关、且是产品行为**(哪些行、缺失怎么处理),
/// 所以类型与单测照旧留着,只换喂数据的生产者。属性名见 `propertyNames`。
struct PlayerStatistics: Equatable {
    struct Line: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let lines: [Line]

    /// 需要轮询的属性名。⚠️ 这批名字是 mpv 的,均已对照本机 mpv 0.41 的
    /// `--list-properties` 核实;换成 AVKit 后本节要整体重写(键名对不上),
    /// 但 `lines` 的格式化契约不变。
    static let propertyNames = [
        "video-codec", "video-params/w", "video-params/h", "video-params/pixelformat",
        "video-params/primaries", "video-params/gamma", "container-fps", "estimated-vf-fps",
        "hwdec-current", "video-bitrate",
        "audio-codec-name", "audio-params/samplerate", "audio-params/channel-count", "audio-bitrate",
        "frame-drop-count", "decoder-frame-drop-count", "display-fps",
        "demuxer-cache-duration", "cache-speed",
    ]

    init(properties p: [String: String], session: PlaybackSession?) {
        var lines: [Line] = []
        func add(_ label: String, _ parts: [String?]) {
            let value = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !value.isEmpty { lines.append(Line(label: label, value: value)) }
        }

        if let session {
            add("播放方式", [session.plan.method.displayName, session.mediaSource.container?.uppercased()])
        }

        let size: String? = {
            guard let w = p["video-params/w"], let h = p["video-params/h"] else { return nil }
            return "\(w)×\(h)"
        }()
        let fps = (p["estimated-vf-fps"] ?? p["container-fps"]).flatMap(Self.fpsText)
        add("视频", [p["video-codec"].map(Self.shortCodecName), size, fps])
        let colour: String? = {
            guard let primaries = p["video-params/primaries"], let gamma = p["video-params/gamma"] else { return nil }
            return "\(primaries) / \(gamma)"
        }()
        add("色彩", [p["video-params/pixelformat"], colour])
        add("解码", [p["hwdec-current"].map(Self.decoderText)])
        add("视频码率", [p["video-bitrate"].flatMap(Self.bitrateText)])

        let sampleRate = p["audio-params/samplerate"].flatMap(Double.init).map {
            "\(($0 / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
        }
        let channels = p["audio-params/channel-count"].map { "\($0) 声道" }
        add("音频", [p["audio-codec-name"], sampleRate, channels, p["audio-bitrate"].flatMap(Self.bitrateText)])

        if let output = p["frame-drop-count"], let decoder = p["decoder-frame-drop-count"] {
            add("丢帧", ["输出 \(output)", "解码 \(decoder)"])
        }
        add("显示", [p["display-fps"].flatMap(Double.init).map { "\(Int($0.rounded())) Hz" }])

        let cached = p["demuxer-cache-duration"].flatMap(Double.init).map {
            "已缓存 \($0.formatted(.number.precision(.fractionLength(1)))) 秒"
        }
        add("网络", [cached, p["cache-speed"].flatMap(Double.init).map(Self.speedText)])

        self.lines = lines
    }

    // MARK: - 格式化(internal:单元测试直接验)

    /// `H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10` → `H.264`
    static func shortCodecName(_ raw: String) -> String {
        raw.components(separatedBy: " / ").first ?? raw
    }

    /// mpv 的 `hwdec-current`:`no` 表示软解,其余是硬解接口名(如 `videotoolbox`)。
    static func decoderText(_ raw: String) -> String {
        raw == "no" || raw.isEmpty ? "软件解码" : "硬件解码(\(raw))"
    }

    /// bit/s → `8.2 Mbps` / `192 kbps`。0 或不可解析时返回 nil。
    static func bitrateText(_ raw: String) -> String? {
        guard let bits = Double(raw), bits > 0 else { return nil }
        if bits >= 1_000_000 {
            return "\((bits / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps"
        }
        return "\(Int((bits / 1000).rounded())) kbps"
    }

    static func fpsText(_ raw: String) -> String? {
        guard let fps = Double(raw), fps > 0 else { return nil }
        return "\(fps.formatted(.number.precision(.fractionLength(0...3)))) fps"
    }

    /// 字节/秒 → `3.2 MB/s` / `850 KB/s`(十进制单位,与系统「活动监视器」一致)。
    static func speedText(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .decimal) + "/s"
    }
}
