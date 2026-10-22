import AVFoundation
import Foundation

/// 本地视频的总时长(秒),只读文件头。卡片上的时长 / 剩余 / 进度条靠它。
///
/// 百度那边的时长来自 `filemetas`(服务端给);本地没有服务端,只能自己读。
/// 读法按容器分两路,都只碰文件**开头一小段**,⛔ 不为一个数字把整部片读一遍:
///
/// - **Matroska(mkv / webm)**:自己解 EBML 头,取 `Segment/Info` 里的 `Duration`
///   (`matroskaDuration(in:)`,纯函数,单测覆盖)。AVFoundation 不认 mkv,而片库里
///   mkv 恰恰最多;
/// - **MP4 家族(mp4 / m4v / mov)**:交给 AVFoundation(它只读 `moov`)。
///
/// 其余容器(avi / ts / rmvb …)读不出来就是 nil —— 卡片上不显示时长,
/// 播过一次之后续播库里有内核报的时长。⛔ 不估算。
enum LocalMediaDuration {

    /// 解 Matroska 头时最多读多少字节。`Info` 通常在前几 KB(紧跟 `SeekHead`);
    /// 64 KB 没见到就当这个文件把 `Info` 放在了后面,不再往下读。
    static let matroskaProbeBytes = 64 * 1024

    static let matroskaExtensions: Set<String> = ["mkv", "webm", "mk3d"]
    static let avFoundationExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// 读这个文件的时长。读不出来(容器不支持 / 头里没写 / 读盘失败)返回 nil。
    static func seconds(of url: URL) async -> Double? {
        let ext = url.pathExtension.lowercased()
        if matroskaExtensions.contains(ext) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: matroskaProbeBytes) else { return nil }
            return matroskaDuration(in: head)
        }
        if avFoundationExtensions.contains(ext) {
            guard let duration = try? await AVURLAsset(url: url).load(.duration),
                  duration.isNumeric else { return nil }
            let seconds = duration.seconds
            return seconds.isFinite && seconds > 0 ? seconds : nil
        }
        return nil
    }

    // MARK: - Matroska

    private enum EBMLID {
        static let header: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let info: UInt32 = 0x1549_A966
        static let cluster: UInt32 = 0x1F43_B675
        static let timestampScale: UInt32 = 0x2A_D7B1
        static let duration: UInt32 = 0x4489
    }

    /// 从 Matroska 文件开头的字节里取总时长(秒)。纯函数。
    ///
    /// 只走「EBML 头 → Segment → Info」这一条路:
    /// - `Duration` 是浮点数,单位是 `TimestampScale` 纳秒(缺省 1 000 000,即毫秒);
    /// - 走到 `Cluster`(媒体数据开始)还没见到 `Info`,或者某个元素的长度未知 / 越界,
    ///   就停 —— 再往下就是在数据里瞎找。
    static func matroskaDuration(in data: Data) -> Double? {
        let bytes = [UInt8](data)
        var offset = 0
        // 顶层:跳过 EBML 头,进 Segment
        guard let header = element(in: bytes, at: offset), header.id == EBMLID.header,
              let headerSize = header.size else { return nil }
        offset = header.dataOffset + headerSize
        guard let segment = element(in: bytes, at: offset), segment.id == EBMLID.segment else {
            return nil
        }
        // Segment 的长度常是「未知」(直播式写法),不影响:只在它里面往下走
        offset = segment.dataOffset
        while let child = element(in: bytes, at: offset) {
            if child.id == EBMLID.cluster { return nil }
            guard let size = child.size else { return nil }
            if child.id == EBMLID.info {
                let end = child.dataOffset + size
                guard end <= bytes.count else { return nil }
                return infoDuration(bytes, from: child.dataOffset, to: end)
            }
            offset = child.dataOffset + size
        }
        return nil
    }

    private static func infoDuration(_ bytes: [UInt8], from start: Int, to end: Int) -> Double? {
        var scale: UInt64 = 1_000_000
        var rawDuration: Double?
        var offset = start
        while offset < end, let child = element(in: bytes, at: offset), let size = child.size {
            let payloadEnd = child.dataOffset + size
            guard payloadEnd <= end else { return nil }
            let payload = bytes[child.dataOffset..<payloadEnd]
            switch child.id {
            case EBMLID.timestampScale:
                guard (1...8).contains(size) else { return nil }
                scale = payload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            case EBMLID.duration:
                rawDuration = float(payload)
            default:
                break
            }
            offset = payloadEnd
        }
        guard let rawDuration, scale > 0 else { return nil }
        let seconds = rawDuration * Double(scale) / Double(NSEC_PER_SEC)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// 大端 4 / 8 字节浮点。其它长度不合规范,不认。
    private static func float(_ payload: ArraySlice<UInt8>) -> Double? {
        let bits = payload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        switch payload.count {
        case 4: return Double(Float(bitPattern: UInt32(bits)))
        case 8: return Double(bitPattern: bits)
        default: return nil
        }
    }

    private struct Element {
        let id: UInt32
        /// nil = 长度未知(全 1)
        let size: Int?
        let dataOffset: Int
    }

    /// 读一个元素头(ID + 长度)。字节不够 / 编码不合法返回 nil。
    private static func element(in bytes: [UInt8], at offset: Int) -> Element? {
        guard let id = vint(bytes, at: offset, maxLength: 4, keepMarker: true),
              let size = vint(bytes, at: offset + id.length, maxLength: 8, keepMarker: false)
        else { return nil }
        let allOnes = (UInt64(1) << (7 * UInt64(size.length))) - 1
        return Element(
            id: UInt32(id.value),
            size: size.value == allOnes ? nil : Int(exactly: size.value),
            dataOffset: offset + id.length + size.length)
    }

    /// EBML 变长整数。首字节里第一个 1 的位置给出总长度。
    private static func vint(
        _ bytes: [UInt8], at offset: Int, maxLength: Int, keepMarker: Bool
    ) -> (value: UInt64, length: Int)? {
        guard offset < bytes.count else { return nil }
        let first = bytes[offset]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= maxLength, offset + length <= bytes.count else { return nil }
        var value = UInt64(keepMarker ? first : first & (0xFF >> length))
        for index in 1..<length {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return (value, length)
    }
}

/// 本地时长的**进程内**记忆。
///
/// 本地目录不走会话缓存(每次进都重新读盘,见 `FileSourceViewModel` 的 `cachesDirectories`),
/// 时长却没必要每次都去读文件头 —— 外接机械盘 / 网络卷上一层几十集,每次进来都开几十个文件
/// 会明显卡。键带文件的修改时间与大小:文件被替换了,键就变,⛔ 不会端出旧时长。
actor LocalMediaDurationCache {
    /// 值为 nil 表示「读过,读不出来」—— 也要记,否则读不出来的那些每次都重试
    private var known: [String: Double?] = [:]

    /// 这批文件的时长(读不出来的不在结果里)。没记过的并发读,最多同时开 4 个文件。
    func durations(for files: [(file: BaiduPanFile, url: URL)]) async -> [UInt64: Double] {
        var result: [UInt64: Double] = [:]
        var missing: [(key: String, fsID: UInt64, url: URL)] = []
        for entry in files {
            let key = Self.key(entry.file)
            if let cached = known[key] {
                if let cached { result[entry.file.fsID] = cached }
            } else {
                missing.append((key, entry.file.fsID, entry.url))
            }
        }
        guard !missing.isEmpty else { return result }
        let probed = await withTaskGroup(of: (String, UInt64, Double?).self) { group in
            var pending = missing[...]
            var collected: [(String, UInt64, Double?)] = []
            for _ in 0..<4 {
                guard let next = pending.popFirst() else { break }
                group.addTask { (next.key, next.fsID, await LocalMediaDuration.seconds(of: next.url)) }
            }
            while let finished = await group.next() {
                collected.append(finished)
                if let next = pending.popFirst() {
                    group.addTask { (next.key, next.fsID, await LocalMediaDuration.seconds(of: next.url)) }
                }
            }
            return collected
        }
        for (key, fsID, seconds) in probed {
            known[key] = seconds
            if let seconds { result[fsID] = seconds }
        }
        return result
    }

    private static func key(_ file: BaiduPanFile) -> String {
        let stamp = file.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "nomtime"
        return "\(file.fsID)|\(stamp)|\(file.sizeBytes.map(String.init) ?? "nosize")"
    }
}
