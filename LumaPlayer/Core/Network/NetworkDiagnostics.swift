import Foundation
import OSLog

/// 网络请求失败的诊断出口(docs/PITFALLS.md Q31)。
///
/// 背景:项目此前**没有任何日志设施**,App 只在 UI 上显示
/// 「服务器返回异常状态码(400)」这类由状态码推出的文案,服务端到底回了什么
/// 无从得知 —— 首页「下一集」行的 400 因此卡在「本地复现不出来、真实服务器上
/// 也看不到响应体」的僵局里。
///
/// 本类型只做一件事:把**失败**请求的端点名、host、URL、请求体与响应体开头,
/// 同时写进**系统日志**与**容器内文件**两条通道:
///
/// 1. 系统日志(随时可查,不需 App 在场):
///    `/usr/bin/log show --last 10m --predicate 'subsystem == "com.local.LumaPlayer"' --info`
///    ⚠️ 用 `/usr/bin/log` 绝对路径 —— zsh 把裸 `log` 当 `watch` 的内建别名。
/// 2. 容器内文件(可直接打开,便于事后提交):
///    `~/Library/Containers/com.local.LumaPlayer/Data/Library/Logs/LumaPlayer/network.log`
///
/// 走两条通道是因为它们各自的短板互补:系统日志有留存策略、不适合当交付物;
/// 文件在沙盒容器里,只能由 App 自己写,`log show` 看不到。
///
/// 三类失败都记(`Failure`):非 2xx、2xx 但解码失败(服务端版本差异最常见的形态)、
/// 传输层错误(超时 / TLS / 连接被断;取消不算失败,不记)。
///
/// 记录口径(CLAUDE.md「安全与隐私」):
/// - 只记路径与**脱敏后**的查询串,⛔ 不记 `Authorization` / `X-Emby-Token`;
/// - 请求体 / 响应体是 JSON 时**按结构脱敏**(按键名替换值,见 `redactedJSON`),
///   不走正则 —— 正则取值遇到空格、逗号、转义引号就停,含这些字符的密码会漏出后半段;
/// - 请求体不是 JSON 时只记字节数(本 App 发出的请求体全是 JSON,出现别的就是异常);
///   响应体不是 JSON(HTML 错误页、纯文本)时才退回 `SecretRedactor.redacted` 正则;
/// - 截断到 `bodyLimit` 个字符;
/// - **只记失败**:正常请求不产生日志,避免刷屏,也不做隐式的行为监控。
///
/// ⚠️ 日志里的 host、路径中的 UserId / ItemId 是真实值。本机留存没问题,
/// 但贴进仓库或 issue 前必须按 `API_CONTRACT.md` 9.3 再脱敏一遍。
enum NetworkDiagnostics {
    /// 失败的种类。
    enum Failure: Sendable {
        /// 服务端返回非 2xx
        case http(status: Int, body: Data)
        /// 服务端返回 2xx,但响应体解不成期望的模型。
        /// `detail` 是 `DecodingError` 的描述,含 `codingPath`,能直接指出是哪个字段。
        case decoding(status: Int, detail: String, body: Data)
        /// 请求没拿到 HTTP 响应(超时、TLS、连接被断……)
        case transport(URLError.Code)
    }

    /// 与 `PRODUCT_BUNDLE_IDENTIFIER` 一致,`log show` 按它过滤
    static let subsystem = "com.local.LumaPlayer"
    /// 单条日志里请求体 / 响应体的字符上限。Emby 的错误响应通常几十到几百字节,
    /// 1 KiB 足够看清原因,又不至于把日志刷爆。
    static let bodyLimit = 1024
    /// 解码错误描述的字符上限。`DecodingError` 描述通常一两百字符,
    /// 深层嵌套时 `codingPath` 会很长,给宽一点。
    static let detailLimit = 1024
    /// 落盘文件的大小上限。超过就清空重写 —— 排障场景下旧记录价值低,
    /// 不值得为轮转逻辑再加一套复杂度。
    static let fileSizeLimit = 256 * 1024

    private static let logger = Logger(subsystem: subsystem, category: "network")

    /// 落盘路径:容器内的 `Library/Logs/LumaPlayer/network.log`。
    ///
    /// App 开了沙盒,`.libraryDirectory` 拿到的是**容器内**的 Library,
    /// 因此这个路径不需要(也无法)写成宿主机的 `~/Library/Logs`。
    static var logFileURL: URL? {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appending(path: "Logs/LumaPlayer/network.log")
    }

    /// 记一条失败请求。
    ///
    /// - Parameters:
    ///   - failure: 失败种类与服务端返回的原始字节(调用方不必先解码)
    ///   - endpointName: `EmbyEndpoint.name`(只有端点名,不含路径参数与凭据)
    ///   - method: HTTP 方法
    ///   - url: 请求 URL;记录前经 `SecretRedactor.redactedDescription(of:)`
    ///   - requestBody: 请求体原始字节(`URLRequest.httpBody`),没有就传 `nil`
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
        // 所有插值都显式标 .public:Logger 默认把字符串当私密内容脱敏成
        // <private>,不标的话日志里只剩一片占位符,等于白记。
        logger.error("\(text, privacy: .public)")
        append(text)
    }

    /// 记一条播放失败(内核已拿到 URL 但没播起来,如 `Unrecognized file format`)。
    ///
    /// 与 `record(_:...)` 的区别:失败发生在内核内部,App 看不到 HTTP 状态与响应体,
    /// 只能留下内核的错误消息;内核自己的日志由 `recordEngineLogs` 跟着记 `ENGINE` 行,
    /// 响应体到底回了什么由 `PlaybackFailureProbe` 另记一条 `PROBE`(对同一个 URL
    /// 补一次只读探测)。
    static func recordPlaybackFailure(
        message: String,
        url: URL,
        method: String,
        directStreamURLProvided: Bool
    ) {
        let text = playbackFailureLine(
            message: message, url: url, method: method,
            directStreamURLProvided: directStreamURLProvided,
            userAgent: ClientUserAgent.value)
        logger.error("\(text, privacy: .public)")
        append(text)
    }

    /// 记一条起播耗时(成功起播也记,用来对比快慢服务器;不含 URL / token)。
    static func recordTiming(_ text: String) {
        logger.info("\(text, privacy: .public)")
        append(text)
    }

    /// 记一条播放失败后的响应体探测结果(见 `PlaybackFailureProbe`)。
    static func recordProbe(url: URL, summary: String) {
        let text = "\(Date.now.ISO8601Format()) PROBE host=\(url.host() ?? "?") "
            + "url=\(SecretRedactor.redactedDescription(of: url)) \(flattened(SecretRedactor.redacted(summary)))"
        logger.error("\(text, privacy: .public)")
        append(text)
    }

    /// 记播放失败时内核自己的日志(`PlaybackEngine.diagnosticLogs()`),紧跟在 `PLAYBACK` 之后。
    ///
    /// 内核看得到 App 看不到的东西(FFmpeg 的解封装 / 解码报错、硬解初始化失败),
    /// 一条 `PLAYBACK` 只有一句错误消息,原因往往在这里。
    static func recordEngineLogs(_ entries: [PlayerLogEntry]) {
        for text in engineLogLines(entries) {
            logger.error("\(text, privacy: .public)")
            append(text)
        }
    }

    /// 读内核日志失败也留一行,免得「没有 ENGINE 行」被误读成「内核没报什么」。
    static func recordEngineLogsUnavailable(_ message: String) {
        let text = "\(Date.now.ISO8601Format()) ENGINE logs unavailable: \(describeDetail(message))"
        logger.error("\(text, privacy: .public)")
        append(text)
    }

    /// 内核日志的完整文本,一条一行。纯函数。
    ///
    /// 形如:`{时间} ENGINE warn ffmpeg ×3 [mov,mp4 @ 0x…] moov atom not found`。
    /// 内核导出时已脱敏,这里再过一次 `SecretRedactor`(双保险),并压平、截断到 `detailLimit`。
    /// 没有条目时也写一行,表明查过了。
    static func engineLogLines(_ entries: [PlayerLogEntry], date: Date = .now) -> [String] {
        guard !entries.isEmpty else {
            return ["\(date.ISO8601Format()) ENGINE <no warn/error entries since open>"]
        }
        return entries.map { entry in
            var parts = [entry.date.ISO8601Format(), "ENGINE", entry.level, entry.source]
            if entry.count > 1 { parts.append("×\(entry.count)") }
            parts.append(describeDetail(entry.text))
            return parts.joined(separator: " ")
        }
    }

    /// 播放失败日志的完整文本。纯函数。
    ///
    /// 形如:`{时间} PLAYBACK method=directStream host=… url=… message="…"`
    /// URL 经 `SecretRedactor.redactedDescription`,错误消息再过一次 `redacted`(双保险)。
    static func playbackFailureLine(
        message: String,
        url: URL,
        method: String,
        directStreamURLProvided: Bool = false,
        userAgent: String? = nil,
        date: Date = .now
    ) -> String {
        var parts = [
            date.ISO8601Format(),
            "PLAYBACK",
            "method=\(method)",
            "host=\(url.host() ?? "?")",
            "url=\(SecretRedactor.redactedDescription(of: url))",
            "message=\"\(flattened(SecretRedactor.redacted(message)))\"",
            // 服务端有没有给 MediaSource.DirectStreamUrl(issue #2:有就用它,没有才自拼)
            "dsu=\(directStreamURLProvided ? "provided" : "absent")",
        ]
        if let userAgent {
            parts.append("ua=\"\(flattened(SecretRedactor.redacted(userAgent)))\"")
        }
        return parts.joined(separator: " ")
    }

    /// 一条日志的完整文本。纯函数,单独拆出来便于测试。
    ///
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

    /// 响应体的可读描述:脱敏 + 截断 + 压平换行。
    ///
    /// 服务端在 400 / 500 时可能返回 HTML 错误页或二进制,不能假定是 UTF-8;
    /// 解不出来就退化成字节数说明,不要在这一步抛错 —— 诊断代码自己失败
    /// 会让排查彻底断线。
    static func describe(_ body: Data) -> String {
        guard !body.isEmpty else { return "<empty>" }
        // 整段解码再按字符截断:按字节截会切在多字节字符中间,
        // 让中文错误信息被误判成「非 UTF-8」
        guard let text = String(data: body, encoding: .utf8) else {
            return "<\(body.count) bytes, non-UTF8>"
        }
        if let json = redactedJSON(body) {
            return limited(json, totalBytes: body.count)
        }
        // 非 JSON 才退回正则。先截断再脱敏,免得对几 MB 的 HTML 跑正则;
        // 先脱敏再压平,`Authorization` 那条「取到行尾」的规则才不会吞掉整段
        let redacted = flattened(SecretRedactor.redacted(truncated(text, limit: bodyLimit)))
        return text.count > bodyLimit
            ? "\(redacted)…(共 \(body.count) 字节)"
            : redacted
    }

    /// 请求体的可读描述。只接受 JSON(本 App 发出的请求体全是 JSON)。
    ///
    /// ⛔ 不是 JSON 时**不记内容**,不退回正则:请求体里有登录密码(`Pw`),
    /// 正则取值遇到空格、逗号、转义引号就停,会把密码后半段原样写进日志。
    static func describeRequestBody(_ body: Data) -> String {
        guard !body.isEmpty else { return "<empty>" }
        guard let json = redactedJSON(body) else {
            return "<\(body.count) bytes, non-JSON>"
        }
        return limited(json, totalBytes: body.count)
    }

    /// 把 JSON 按结构脱敏后重新序列化成单行;不是 JSON 返回 `nil`。
    ///
    /// 敏感判断复用 `SecretRedactor.isSensitive`(按键名,大小写不敏感),
    /// 命中的键**整值**替换,与值里有什么字符无关。字符串叶子另外过一遍
    /// `SecretRedactor.redacted`,兜住 `TranscodingUrl` 这类值里嵌的 `api_key=…`。
    /// 重新序列化会让键按字母序排、去掉空白 —— 诊断用,不要求与原文逐字一致。
    static func redactedJSON(_ data: Data) -> String? {
        // `try?` 不是吞错:解析失败正是「不是 JSON」的判据,调用方据 nil 走各自的退路
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

    /// 超过 `bodyLimit` 时截断,并在尾部说明原始总字节数 ——
    /// 只看前半段容易误判「响应就这么多」
    private static func limited(_ text: String, totalBytes: Int) -> String {
        text.count > bodyLimit
            ? "\(truncated(text, limit: bodyLimit))…(共 \(totalBytes) 字节)"
            : text
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }

    /// 换行会把一条日志拆成多行,压平后更便于 grep
    private static func flattened(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// 追加一行到容器内日志文件。
    ///
    /// 落盘失败**不静默**:写进系统日志。吞掉的话就等于「日志系统坏了但没人知道」,
    /// 正是本类型要消灭的那类问题。
    private static func append(_ line: String) {
        // 测试进程里不落盘。单元测试会成批构造 4xx/5xx(401/403/404/429/500…),
        // 而测试**跑在宿主 App 进程里**、共享同一个沙盒容器 —— 实测一次
        // `xcodebuild test` 就写进 37 行 mock 记录。不挡的话跑几轮测试就能把
        // `fileSizeLimit` 顶满,把真实排障记录冲掉。系统日志那一路不挡:
        // 那里的噪音本来就大,留着还能调试测试本身。
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
            // 逐个 try 而不是 defer + try?:规则 2 不允许静默吞错,
            // 而这里每一步失败都有 catch 兜着,不需要 defer 保底。
            try handle.close()
        } catch {
            logger.error("诊断日志落盘失败: \(String(describing: error), privacy: .public)")
        }
    }

    private static func resetIfOversized(_ url: URL) throws {
        // 文件不存在时 resourceValues 会抛 NSFileReadNoSuchFileError ——
        // 首次写入必然走到这里,不能省这个 guard。
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size > fileSizeLimit {
            try Data().write(to: url)
        }
    }
}
