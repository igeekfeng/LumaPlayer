import Foundation

/// 播放统计信息 overlay 的内容(按 I 键开关)。
///
/// 数据来自播放引擎的归一化统计快照(`PlaybackEngine.stats() -> PlayerStats`),
/// 再加上 Emby 侧的播放方式与容器。本类型只做格式化,是纯函数,便于测试。
/// 某个字段内核给不了(nil)时对应的行直接不显示,不填「未知」凑数。
struct PlayerStatistics: Equatable {
    struct Line: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let lines: [Line]

    init(stats s: PlayerStats, session: PlaybackSession?) {
        var lines: [Line] = []
        func add(_ label: String, _ parts: [String?]) {
            let value = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !value.isEmpty { lines.append(Line(label: label, value: value)) }
        }

        if let session {
            add("播放方式", [session.plan.method.displayName, session.mediaSource.container?.uppercased()])
        }

        let size: String? = {
            guard let w = s.width, let h = s.height else { return nil }
            return "\(w)×\(h)"
        }()
        add("视频", [s.videoCodec.map(Self.shortCodecName), size, s.frameRate.flatMap(Self.fpsText)])

        let colour: String? = {
            guard let primaries = s.colorPrimaries, let transfer = s.colorTransfer else { return nil }
            return "\(primaries) / \(transfer)"
        }()
        add("色彩", [s.pixelFormat, colour])
        add("解码", [Self.decoderText(name: s.decoderName, hardware: s.isHardwareDecoded)])
        add("视频码率", [s.videoBitRate.flatMap(Self.bitrateText)])

        let sampleRate = s.audioSampleRate.map {
            "\(($0 / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
        }
        let channels = s.audioChannels.map { "\($0) 声道" }
        add("音频", [s.audioCodec, sampleRate, channels, s.audioBitRate.flatMap(Self.bitrateText)])

        if let rendered = s.renderedFrames {
            add("帧", ["已渲染 \(rendered)", s.droppedFrames.map { "丢帧 \($0)" }])
        }

        let headroom = s.edrHeadroom.map {
            "headroom \($0.formatted(.number.precision(.fractionLength(0...2))))"
        }
        add("输出", [s.outputMode, headroom])
        add("显存", [s.memoryBytes.map(Self.byteText)])

        self.lines = lines
    }

    // MARK: - 格式化(internal:单元测试直接验)

    /// `H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10` → `H.264`
    static func shortCodecName(_ raw: String) -> String {
        raw.components(separatedBy: " / ").first ?? raw
    }

    /// 解码方式:优先按「是否硬解」的布尔量,其次退回后端名。
    /// `hardware` 为 nil(内核没给帧数)时只显示后端名。
    static func decoderText(name: String?, hardware: Bool?) -> String? {
        switch hardware {
        case true:
            return name.map { "硬件解码(\($0))" } ?? "硬件解码"
        case false:
            return "软件解码"
        case nil:
            return name
        }
    }

    /// bit/s → `8.2 Mbps` / `192 kbps`。0 或负数返回 nil。
    static func bitrateText(_ bits: Int) -> String? {
        guard bits > 0 else { return nil }
        if bits >= 1_000_000 {
            return "\((Double(bits) / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps"
        }
        return "\(Int((Double(bits) / 1000).rounded())) kbps"
    }

    static func fpsText(_ fps: Double) -> String? {
        guard fps.isFinite, fps > 0 else { return nil }
        return "\(fps.formatted(.number.precision(.fractionLength(0...3)))) fps"
    }

    /// 字节数 → `320 MB`(十进制单位,与系统「活动监视器」一致)
    static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .decimal)
    }
}
