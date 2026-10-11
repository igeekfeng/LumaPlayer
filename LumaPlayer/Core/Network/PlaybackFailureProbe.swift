import Foundation

/// 播放失败后的响应体探测(issue #2)。
///
/// libmpv 看不到 HTTP 状态与响应体,`Mime-type: 'application/json'` 之类的日志只能说明
/// 「回的不是媒体」。这里对**同一个播放 URL** 补发一次 `Range: bytes=0-511` 的只读 GET,
/// 把状态码、Content-Type、重定向目标 host 与脱敏后的前几百字节落诊断日志。
///
/// 纪律(CLAUDE.md「真实服务器使用纪律」):只在 mpv 已失败且日志表明收到非媒体内容时触发,
/// 每次失败只探一轮,不重试。不让 URLSession 自动跟随重定向(它会把 `X-Emby-Token` 带到任意 host);
/// 跨 host 跳转时手动对目标补两次(见 `run`),仅此一跳。
enum PlaybackFailureProbe {
    /// 值得探测的两种失败:mpv 日志里出现文本类 Content-Type(收到的不是媒体),
    /// 或 ffmpeg 报 `HTTP error 4xx/5xx`。后者 ffmpeg 已跟随过重定向,看不出 403 是 Emby
    /// 本身回的还是 302 之后的网盘 / CDN 回的;探测不跟随重定向,能记下 Location 的 host。
    static func shouldProbe(mpvLog: [String]) -> Bool {
        mpvLog.contains { line in
            if line.range(of: #"HTTP error [45][0-9]{2}"#, options: .regularExpression) != nil { return true }
            guard let range = line.range(of: "Mime-type: '") else { return false }
            let mime = line[range.upperBound...].lowercased()
            return mime.hasPrefix("application/json") || mime.hasPrefix("text/")
        }
    }

    static let bytesLimit = 512

    /// 对播放 URL 补一次 `Range` 探测。
    ///
    /// issue #2 已结案(根因是 `PlaybackInfo` 没带 `DeviceProfile`,见 PITFALLS.md 第 3 节),
    /// 当时用过的对照变体(加 `api_key`、Emby Web 路径、去扩展名、参数名大小写)全部收掉,
    /// 只留这一次:失败时仍能看到服务端回了什么,又不多打别人的服务器。
    static func run(url: URL, headers: [String: String]) async {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let location = await probe(url: url, headers: headers, label: "as-played", session: session)
        // 跨 host 跳转:403 可能来自跳转目标。ffmpeg 跟随跳转会原样带上认证头,目标可能
        // 不认这些头,也可能要求 URL 上带 `api_key`。对目标各补一次(不带 / 带认证头),
        // 两者的结论决定修法。认证头 ffmpeg 本来就会发给它,这里不新增暴露面。
        guard let location, let target = URL(string: location.absoluteString, relativeTo: url)?.absoluteURL,
              target.host() != url.host()
        else { return }
        // 跳转目标的 query 是它自己的签名(`sign=` 之类),SecretRedactor 不认识 → 日志只记路径
        var logged = URLComponents(url: target, resolvingAgainstBaseURL: false)
        logged?.query = nil
        let loggedURL = logged?.url ?? target
        await probe(url: target, loggedURL: loggedURL, headers: [:], label: "redirect-noauth", session: session)
        await probe(url: target, loggedURL: loggedURL, headers: headers, label: "redirect-auth", session: session)
    }

    /// 返回 3xx 的 `Location`(没有则 nil)
    @discardableResult
    private static func probe(
        url: URL, loggedURL: URL? = nil, headers: [String: String], label: String, session: URLSession
    ) async -> URL? {
        let loggedURL = loggedURL ?? url
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(ClientUserAgent.value, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-\(bytesLimit - 1)", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                NetworkDiagnostics.recordProbe(url: loggedURL, summary: "variant=\(label) non-HTTP response")
                return nil
            }
            var parts = ["variant=\(label)", "status=\(http.statusCode)"]
            parts.append("type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "?")")
            let location = http.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0) }
            if let location {
                parts.append("location_host=\(location.host() ?? "relative")")
                // 只记参数名不记值:看跳转是否把 api_key / 签名之类带过去
                let names = URLComponents(url: location, resolvingAgainstBaseURL: false)?
                    .queryItems?.map(\.name) ?? []
                parts.append("location_params=\(names.isEmpty ? "-" : names.joined(separator: ","))")
            }
            parts.append("body=\(NetworkDiagnostics.describe(data.prefix(bytesLimit)))")
            NetworkDiagnostics.recordProbe(url: loggedURL, summary: parts.joined(separator: " "))
            return (300..<400).contains(http.statusCode) ? location : nil
        } catch {
            let nsError = error as NSError
            NetworkDiagnostics.recordProbe(
                url: loggedURL, summary: "variant=\(label) probe failed: \(nsError.domain) \(nsError.code)")
            return nil
        }
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
