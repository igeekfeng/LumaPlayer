import Foundation

/// 播放失败后的响应体探测(issue #2)。
///
/// 播放内核看不到 HTTP 状态与响应体,错误消息只能说明「回的不是媒体」。这里对
/// **同一个播放 URL** 补发一次 `Range: bytes=0-511` 的只读 GET,把状态码、
/// Content-Type、重定向目标 host 与脱敏后的前几百字节落诊断日志。
///
/// 纪律(CLAUDE.md「真实服务器使用纪律」):只在播放已失败时触发,
/// 每次失败最多一次,不重试。不跟随重定向:自定义头(`X-Emby-Token`)会被 URLSession
/// 带到重定向后的任意 host,只记下 Location 的 host 就停。
enum PlaybackFailureProbe {
    static let bytesLimit = 512

    /// 对播放 URL 补一次 `Range` 探测。
    ///
    /// issue #2 已结案(根因是 `PlaybackInfo` 没带 `DeviceProfile`,见 PITFALLS.md 第 3 节),
    /// 当时用过的对照变体(加 `api_key`、Emby Web 路径、去扩展名、参数名大小写)全部收掉,
    /// 只留这一次:失败时仍能看到服务端回了什么,又不多打别人的服务器。
    static func run(url: URL, headers: [String: String]) async {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        await probe(url: url, headers: headers, label: "as-played", session: session)
    }

    private static func probe(url: URL, headers: [String: String], label: String, session: URLSession) async {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(ClientUserAgent.value, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-\(bytesLimit - 1)", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                NetworkDiagnostics.recordProbe(url: url, summary: "variant=\(label) non-HTTP response")
                return
            }
            var parts = ["variant=\(label)", "status=\(http.statusCode)"]
            parts.append("type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "?")")
            if let location = http.value(forHTTPHeaderField: "Location") {
                parts.append("location_host=\(URL(string: location)?.host() ?? "relative")")
            }
            parts.append("body=\(NetworkDiagnostics.describe(data.prefix(bytesLimit)))")
            NetworkDiagnostics.recordProbe(url: url, summary: parts.joined(separator: " "))
        } catch {
            let nsError = error as NSError
            NetworkDiagnostics.recordProbe(
                url: url, summary: "variant=\(label) probe failed: \(nsError.domain) \(nsError.code)")
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
