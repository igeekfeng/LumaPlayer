import Foundation

/// Erika JSON 诊断接口的解析:`getDiagnosticsSnapshot`(统计面板)与 `getLogs`(播放失败日志)。
///
/// 两者都经 `ErikaPlayer.invoke` 调用(Swift SDK 没有专门的封装),调用在
/// `ErikaPlaybackEngine`;这里只做解析,**不 import Erika**,用 JSON 字面量就能单测。
///
/// 字段以 liberika 0.3.0 `docs/capi_reference.md`「Agent diagnostics (JSON)」为准
/// (ERIKA_INTEGRATION.md §9):文档带 `schema`,同一 schema 内只增字段、不改字段;
/// 内核不知道的值是 `null`,⛔ 不当 0 处理。
enum ErikaDiagnostics {

    // MARK: - 诊断快照

    /// `getDiagnosticsSnapshot` 里用得到的部分(其余分区不解码)。
    struct Snapshot: Decodable, Equatable {
        /// 最近一次解码器切换;第一次切换之前内核给 `null`
        struct Decoder: Decodable, Equatable {
            let requestedBackend: String
            /// 实际在解码的后端(`videotoolbox` / `software` …)
            let activeBackend: String
            let hardware: Bool
            /// 退过回(`fallbackCount > 0` 或实际后端 ≠ 请求的后端)
            let fellBack: Bool
            let reason: String?
        }

        struct Timing: Decodable, Equatable {
            struct Scheduler: Decodable, Equatable {
                /// 迟到超过容差被调度器丢弃的帧(在内核渲染处计,不是显示器 vsync 处)
                let lateDroppedFrames: Int?
            }
            let scheduler: Scheduler?
        }

        let schema: Int
        let decoder: Decoder?
        let timing: Timing?
    }

    static func snapshot(from data: Data) throws -> Snapshot {
        do {
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            throw PlayerError("Erika 诊断快照格式无法识别:\(error)")
        }
    }

    /// 硬解退回软解的原因。没退回、或退回后又恢复了硬解,都是 nil。
    static func fallbackReason(_ decoder: Snapshot.Decoder) -> String? {
        guard decoder.fellBack, !decoder.hardware else { return nil }
        return decoder.reason ?? "\(decoder.requestedBackend) 不可用"
    }

    // MARK: - 日志环

    /// `getLogs` 的一页结果。
    struct LogPage: Equatable {
        /// 下一条日志将拿到的序号;下次带 `sinceSeq` 传它,就只读之后的新日志
        let nextSeq: UInt64
        /// 旧 → 新
        let entries: [PlayerLogEntry]
    }

    /// 解析 `getLogs` 的返回值。
    ///
    /// 条目有两种:结构化诊断给 `data`(对象),其余给 `message`(字符串)。
    /// `data` 没法用 `Decodable` 接任意结构,所以整页走 `JSONSerialization`。
    static func logs(from data: Data) throws -> LogPage {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let nextSeq = (root["nextSeq"] as? NSNumber)?.uint64Value,
            let rawEntries = root["entries"] as? [[String: Any]]
        else {
            throw PlayerError("Erika 日志格式无法识别")
        }
        let entries = try rawEntries.map { raw -> PlayerLogEntry in
            guard
                let unixMs = (raw["unixMs"] as? NSNumber)?.doubleValue,
                let level = raw["level"] as? String,
                let source = raw["source"] as? String
            else {
                throw PlayerError("Erika 日志条目缺少 unixMs / level / source")
            }
            // 重复折叠的条目带 lastUnixMs(最后一次出现的时间)
            let lastUnixMs = (raw["lastUnixMs"] as? NSNumber)?.doubleValue ?? unixMs
            return PlayerLogEntry(
                date: Date(timeIntervalSince1970: lastUnixMs / 1000),
                level: level,
                source: source,
                text: try text(of: raw),
                count: (raw["count"] as? NSNumber)?.intValue ?? 1
            )
        }
        return LogPage(nextSeq: nextSeq, entries: entries)
    }

    private static func text(of entry: [String: Any]) throws -> String {
        if let message = entry["message"] as? String { return message }
        if let structured = entry["data"], !(structured is NSNull) {
            let data = try JSONSerialization.data(
                withJSONObject: structured,
                options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
            if let text = String(data: data, encoding: .utf8) { return text }
        }
        throw PlayerError("Erika 日志条目既没有 message 也没有 data")
    }
}
