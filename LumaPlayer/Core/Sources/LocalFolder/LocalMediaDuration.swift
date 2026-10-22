import AVFoundation
import Foundation

/// 本地视频的总时长(秒),只读文件开头一小段,⛔ 不为一个数字读整部片。
///
/// - Matroska:自己解 EBML 头取 `Segment/Info/Duration`(AVFoundation 不认 mkv);
/// - MP4 家族:交给 AVFoundation(只读 `moov`)。
///
/// 其余容器返回 nil,⛔ 不估算(播过一次后续播库里有内核报的时长)。
enum LocalMediaDuration {

    /// `Info` 通常在前几 KB;64 KB 内没见到就放弃。
    static let matroskaProbeBytes = 64 * 1024

    static let matroskaExtensions: Set<String> = ["mkv", "webm", "mk3d"]
    static let avFoundationExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// 读不出来返回 nil。
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

    /// 只走「EBML 头 → Segment → Info」:
    /// - `Duration` 是浮点数,单位 `TimestampScale` 纳秒(缺省 1 000 000,即毫秒);
    /// - 走到 `Cluster` 还没见到 `Info`,或元素长度未知 / 越界就停。
    static func matroskaDuration(in data: Data) -> Double? {
        let bytes = [UInt8](data)
        var offset = 0
        guard let header = element(in: bytes, at: offset), header.id == EBMLID.header,
              let headerSize = header.size else { return nil }
        offset = header.dataOffset + headerSize
        guard let segment = element(in: bytes, at: offset), segment.id == EBMLID.segment else {
            return nil
        }
        // Segment 长度常是「未知」,不影响:只在它里面往下走
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

    /// 读元素头(ID + 长度),不合法返回 nil。
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

/// 本地时长的进程内缓存:本地目录每次进都重新读盘,但每次重读文件头在慢盘上会明显卡。
/// 键含修改时间与大小,文件被替换就失效。
actor LocalMediaDurationCache {
    /// nil = 读过但读不出来,也要记,免得每次重试
    private var known: [String: Double?] = [:]

    /// 读不出来的不在结果里。没记过的并发读,最多同时 4 个。
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
