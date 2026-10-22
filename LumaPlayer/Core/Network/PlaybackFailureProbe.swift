import Foundation

/// 播放失败后的响应体探测:libmpv 看不到 HTTP 状态与响应体,这里对同一个播放 URL
/// 补发一次 `Range: bytes=0-511` 的只读 GET,把状态码、Content-Type、重定向目标 host
/// 与脱敏后的前几百字节落诊断日志。
///
/// 只在 mpv 已失败且日志表明值得探时触发,每次失败只探一轮、不重试(真实服务器使用纪律)。
/// ⛔ 不让 URLSession 自动跟随重定向(会把 `X-Emby-Token` 带到任意 host);跨 host 时手动补探一跳。
enum PlaybackFailureProbe {
    /// 两种失败值得探:mpv 日志里出现文本类 Content-Type(收到的不是媒体),或 ffmpeg 报
    /// `HTTP error 4xx/5xx`(ffmpeg 已跟随重定向,看不出 403 来自 Emby 还是跳转后的 CDN)。
    static func shouldProbe(mpvLog: [String]) -> Bool {
        mpvLog.contains { line in
            if line.range(of: #"HTTP error [45][0-9]{2}"#, options: .regularExpression) != nil { return true }
            guard let range = line.range(of: "Mime-type: '") else { return false }
            let mime = line[range.upperBound...].lowercased()
            return mime.hasPrefix("application/json") || mime.hasPrefix("text/")
        }
    }

    static let bytesLimit = 512

    /// ⛔ 只探这一次,不加对照变体:不多打别人的服务器。
    static func run(url: URL, headers: [String: String]) async {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let location = await probe(url: url, headers: headers, label: "as-played", session: session)
        // 跨 host 跳转:对目标各补一次(不带 / 带认证头)判断它认不认这些头。
        // ffmpeg 跟随跳转本来就会把认证头发给它,不新增暴露面。
        guard let location, let target = URL(string: location.absoluteString, relativeTo: url)?.absoluteURL,
              target.host() != url.host()
        else { return }
        // 目标 query 里是它自己的签名,SecretRedactor 不认识 → 日志只记路径
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
                // 只记参数名不记值
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
