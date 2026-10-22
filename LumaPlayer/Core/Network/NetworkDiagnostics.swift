import Foundation
import OSLog

/// 网络请求失败的诊断出口(PITFALLS.md Q31):UI 只有状态码,服务端回了什么只能在这里看。
///
/// 同时写两条通道:
/// 1. 系统日志:`/usr/bin/log show --last 10m --predicate 'subsystem == "com.local.LumaPlayer"' --info`
///    (⚠️ 用绝对路径,zsh 里裸 `log` 是内建命令);
/// 2. 容器内文件 `~/Library/Containers/com.local.LumaPlayer/Data/Library/Logs/LumaPlayer/network.log`
///    (系统日志有留存策略,不适合当交付物)。
///
/// 记三类失败:非 2xx、2xx 但解码失败、传输层错误(取消不记)。**只记失败**,正常请求不留痕。
///
/// 脱敏口径:
/// - ⛔ 不记 `Authorization` / `X-Emby-Token`;查询串脱敏后记;
/// - JSON 体**按结构脱敏**(按键名整值替换),⛔ 不走正则:正则遇到空格、逗号、转义引号就停,密码会漏出后半段;
/// - 请求体不是 JSON 时只记字节数;响应体不是 JSON 时才退回 `SecretRedactor.redacted` 正则;
/// - 截断到 `bodyLimit` 个字符。
///
/// ⚠️ host、路径里的 UserId / ItemId 是真实值,贴进仓库或 issue 前按 `API_CONTRACT.md` 9.3 再脱敏。
enum NetworkDiagnostics {
    enum Failure: Sendable {
        case http(status: Int, body: Data)
        /// 2xx 但解不成模型。`detail` 是 `DecodingError` 描述,含 `codingPath`
        case decoding(status: Int, detail: String, body: Data)
        /// 没拿到 HTTP 响应(超时、TLS、连接被断……)
        case transport(URLError.Code)
    }

    /// 与 `PRODUCT_BUNDLE_IDENTIFIER` 一致,`log show` 按它过滤
    static let subsystem = "com.local.LumaPlayer"
    /// 请求体 / 响应体的字符上限
    static let bodyLimit = 1024
    /// 解码错误描述的字符上限(深层嵌套时 `codingPath` 很长)
    static let detailLimit = 1024
    /// 字节。超过就清空重写,不做轮转
    static let fileSizeLimit = 256 * 1024

    private static let logger = Logger(subsystem: subsystem, category: "network")

    /// 沙盒下 `.libraryDirectory` 是容器内的 Library。
    static var logFileURL: URL? {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appending(path: "Logs/LumaPlayer/network.log")
    }

    /// - Parameters:
    ///   - endpointName: `EmbyEndpoint.name`(不含路径参数与凭据)
    ///   - url: 记录前经 `SecretRedactor.redactedDescription(of:)`
    ///   - requestBody: 原始字节,脱敏在这里做
    static func record(
        _ failure: Failure,
        endpointName: String,
        method: String,
        url: URL,
        requestBody: Data?
    ) {
        let text = line(
            for: failure,
            endpointName: endpointName,
            method: method,
            url: url,
            requestBody: requestBody
        )
        // 必须标 .public:Logger 默认把插值脱敏成 <private>(内容已自行脱敏)
        logger.error("\(text, privacy: .public)")
        append(text)
    }

    /// 播放失败(libmpv 已拿到 URL 但没播起来)。App 看不到 HTTP 状态,只能留 mpv 的错误消息与最近日志。
    static func recordPlaybackFailure(
        message: String,
        url: URL,
        method: String,
        directStreamURLProvided: Bool,
        mpvLog: [String]
    ) {
        let text = playbackFailureLine(
            message: message, url: url, method: method,
            directStreamURLProvided: directStreamURLProvided,
            userAgent: ClientUserAgent.value, mpvLog: mpvLog)
        logger.error("\(text, privacy: .public)")
        append(text)
    }

    /// 起播耗时(成功也记,对比快慢服务器;不含 URL / token)。
    static func recordTiming(_ text: String) {
        logger.info("\(text, privacy: .public)")
        append(text)
    }

    /// 起播耗时的 mpv 明细,只留拉流 / 探测相关模块。
    static func recordTimingDetail(host: String?, mpvLog: [String]) {
        let lines = timingDetailLines(mpvLog)
        guard !lines.isEmpty else { return }
        let text = "\(Date.now.ISO8601Format()) TIMING-MPV host=\(host ?? "?") "
            + "mpvlog=[\(lines.map { flattened(SecretRedactor.redacted($0)) }.joined(separator: " | "))]"
        logger.info("\(text, privacy: .public)")
        append(text)
    }

    /// 保留 `[stream…]` / `[ffmpeg]` / `[demux]` / `[lavf]` / `[cplayer]` 的行,取最后 40 条
    static func timingDetailLines(_ mpvLog: [String]) -> [String] {
        let modules = ["[stream", "[ffmpeg", "[demux", "[lavf", "[cplayer"]
        let kept = mpvLog.filter { line in
            // 行形如 `+1.23 [ffmpeg] …`,模块在时间戳之后
            guard let space = line.firstIndex(of: " ") else { return false }
            let rest = line[line.index(after: space)...]
            return modules.contains { rest.hasPrefix($0) }
        }
        return Array(kept.suffix(40))
    }

    /// 见 `PlaybackFailureProbe`。
    static func recordProbe(url: URL, summary: String) {
        let text = "\(Date.now.ISO8601Format()) PROBE host=\(url.host() ?? "?") "
            + "url=\(SecretRedactor.redactedDescription(of: url)) \(flattened(SecretRedactor.redacted(summary)))"
        logger.error("\(text, privacy: .public)")
        append(text)
    }

    /// 形如:`{时间} PLAYBACK method=directStream host=… url=… mpv="…" mpvlog=[a | b | c]`
    static func playbackFailureLine(
        message: String,
        url: URL,
        method: String,
        directStreamURLProvided: Bool = false,
        userAgent: String? = nil,
        mpvLog: [String],
        date: Date = .now
    ) -> String {
        var parts = [
            date.ISO8601Format(),
            "PLAYBACK",
            "method=\(method)",
            "host=\(url.host() ?? "?")",
            "url=\(SecretRedactor.redactedDescription(of: url))",
            "mpv=\"\(flattened(SecretRedactor.redacted(message)))\"",
            // 服务端有没有给 MediaSource.DirectStreamUrl
            "dsu=\(directStreamURLProvided ? "provided" : "absent")",
        ]
        if let userAgent {
            parts.append("ua=\"\(flattened(SecretRedactor.redacted(userAgent)))\"")
        }
        if !mpvLog.isEmpty {
            let lines = mpvLog.suffix(playbackLogLines).map { flattened(SecretRedactor.redacted($0)) }
            parts.append("mpvlog=[\(lines.joined(separator: " | "))]")
        }
        return parts.joined(separator: " ")
    }

    /// 取最后 N 条,错误总在末尾附近
    static let playbackLogLines = 30

    /// 形如:
    /// `{时间} HTTP 400 POST Items/{Id}/PlaybackInfo host=… url=… req={…} body={…}`
    /// `{时间} DECODE HTTP 200 GET Users/{UserId}/Items host=… url=… error=… body={…}`
    /// `{时间} TRANSPORT URLError -1001 GET Shows/NextUp host=… url=…`
    static func line(
        for failure: Failure,
        endpointName: String,
        method: String,
        url: URL,
        requestBody: Data?,
        date: Date = .now
    ) -> String {
        var parts = [date.ISO8601Format()]
        switch failure {
        case .http(let status, _):
            parts.append("HTTP \(status)")
        case .decoding(let status, _, _):
            parts.append("DECODE HTTP \(status)")
        case .transport(let code):
            parts.append("TRANSPORT URLError \(code.rawValue)")
        }
        parts += [
            method,
            endpointName,
            "host=\(url.host() ?? "?")",
            "url=\(SecretRedactor.redactedDescription(of: url))",
        ]
        if let requestBody {
            parts.append("req=\(describeRequestBody(requestBody))")
        }
        switch failure {
        case .http(_, let body):
            parts.append("body=\(describe(body))")
        case .decoding(_, let detail, let body):
            parts.append("error=\(describeDetail(detail))")
            parts.append("body=\(describe(body))")
        case .transport:
            break
        }
        return parts.joined(separator: " ")
    }

    /// 脱敏 + 截断 + 压平换行。不能假定 UTF-8,解不出就退化成字节数;⛔ 不在这里抛错。
    static func describe(_ body: Data) -> String {
        guard !body.isEmpty else { return "<empty>" }
        // 整段解码再按字符截断:按字节截会切断多字节字符,被误判成非 UTF-8
        guard let text = String(data: body, encoding: .utf8) else {
            return "<\(body.count) bytes, non-UTF8>"
        }
        if let json = redactedJSON(body) {
            return limited(json, totalBytes: body.count)
        }
        // 先截断再脱敏(免得对几 MB 的 HTML 跑正则);先脱敏再压平
        //(`Authorization`「取到行尾」的规则才不会吞掉整段)
        let redacted = flattened(SecretRedactor.redacted(truncated(text, limit: bodyLimit)))
        return text.count > bodyLimit
            ? "\(redacted)…(共 \(body.count) 字节)"
            : redacted
    }

    /// ⛔ 不是 JSON 时不记内容、不退回正则:请求体里可能有 `Pw`(见类型注释)。
    static func describeRequestBody(_ body: Data) -> String {
        guard !body.isEmpty else { return "<empty>" }
        guard let json = redactedJSON(body) else {
            return "<\(body.count) bytes, non-JSON>"
        }
        return limited(json, totalBytes: body.count)
    }

    /// 按结构脱敏后重新序列化成单行(键排序、去空白);不是 JSON 返回 `nil`。
    /// 敏感键(`SecretRedactor.isSensitive`)整值替换;字符串叶子另过一遍 `redacted`,
    /// 兜住 `TranscodingUrl` 这类值里嵌的 `api_key=…`。
    static func redactedJSON(_ data: Data) -> String? {
        // 解析失败正是「不是 JSON」的判据
        guard let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let output = try? JSONSerialization.data(
                  withJSONObject: redactingJSONValue(object),
                  options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
              )
        else { return nil }
        return String(data: output, encoding: .utf8)
    }

    // MARK: - 内部

    private static func redactingJSONValue(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                result[key] = SecretRedactor.isSensitive(key)
                    ? SecretRedactor.placeholder
                    : redactingJSONValue(child)
            }
            return result
        case let array as [Any]:
            return array.map(redactingJSONValue)
        case let string as String:
            return SecretRedactor.redacted(string)
        default:
            return value
        }
    }

    private static func describeDetail(_ detail: String) -> String {
        let cleaned = flattened(SecretRedactor.redacted(detail))
        return cleaned.count > detailLimit
            ? "\(truncated(cleaned, limit: detailLimit))…"
            : cleaned
    }

    /// 截断时在尾部注明原始总字节数,免得误判「响应就这么多」
    private static func limited(_ text: String, totalBytes: Int) -> String {
        text.count > bodyLimit
            ? "\(truncated(text, limit: bodyLimit))…(共 \(totalBytes) 字节)"
            : text
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }

    /// 一条日志一行,便于 grep
    private static func flattened(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// 落盘失败不静默,写进系统日志。
    private static func append(_ line: String) {
        // 测试进程不落盘:测试跑在宿主 App 里、共享同一个容器,成批的 mock 4xx/5xx
        // 会把真实排障记录冲掉。系统日志那一路不挡。
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        guard let url = logFileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try resetIfOversized(url)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(line)\n".utf8))
            // 不用 defer + try?:close 失败也要进 catch
            try handle.close()
        } catch {
            logger.error("诊断日志落盘失败: \(String(describing: error), privacy: .public)")
        }
    }

    private static func resetIfOversized(_ url: URL) throws {
        // 文件不存在时 resourceValues 会抛,首次写入必经
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size > fileSizeLimit {
            try Data().write(to: url)
        }
    }
}
