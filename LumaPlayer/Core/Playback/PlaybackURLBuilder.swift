import Foundation

/// 播放 URL 的唯一构造处(API_CONTRACT.md 4.5)。⛔ 不得在别处手拼串流 URL。
struct PlaybackURLBuilder: Sendable, Equatable {
    /// 站点根,不含 `/emby`(API_CONTRACT.md 1.2)
    var baseURL: URL
    /// `/emby` 或 "",探测确定后写入(1.2、1.4)
    var apiPathPrefix: String

    /// `{base}{prefix}/Videos/{Id}/stream[.{Container}]?static=true&MediaSourceId=..&PlaySessionId=..`
    ///
    /// 扩展名取 `MediaSource.Container`(DirectStream 输出即输入);容器未知时用无扩展名的 `/stream`,不猜。
    func directStreamURL(
        itemID: String,
        container: String?,
        mediaSourceID: String,
        playSessionID: String
    ) -> URL? {
        var url = baseURL
        if !apiPathPrefix.isEmpty {
            url.append(path: apiPathPrefix)
        }
        url.append(path: "Videos")
        url.append(path: itemID)
        url.append(path: streamPathComponent(container: container))
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // 顺序固定,便于测试断言
        components.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: mediaSourceID),
            URLQueryItem(name: "PlaySessionId", value: playSessionID),
        ]
        return components.url
    }

    /// 采用服务端给的 `MediaSource.DirectStreamUrl`(API_CONTRACT.md 4.5.1),同 Emby Web;
    /// 自拼地址在部分带网关的服务器上会拿到 200 + JSON 错误体。
    ///
    /// 相对路径相对 API 根(`baseURL` + `apiPathPrefix`),已带前缀不重复加;绝对地址原样用其 host。
    /// 剥掉 `api_key`(认证走请求头,6.1)。解析不了返回 nil,调用方退回自拼。
    func directStreamURL(serverProvided raw: String) -> URL? {
        guard !raw.isEmpty, var components = URLComponents(string: raw) else { return nil }
        if components.scheme == nil {
            let prefix = apiPathPrefix
            var path = components.path
            if !path.hasPrefix("/") { path = "/" + path }
            if !prefix.isEmpty, path != prefix, !path.hasPrefix(prefix + "/") {
                path = prefix + path
            }
            guard var base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
            let basePath = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
            base.path = basePath + path
            base.query = components.query
            components = base
        }
        components.queryItems = components.queryItems?.filter { $0.name.lowercased() != "api_key" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }

    /// `MediaSource.TranscodingUrl` 是相对路径(通常已带 `/emby`),拼到站点根;绝对地址原样采用。
    /// ⛔ 不在这里补认证参数,认证头由 mpv 携带(第 6 节)。
    ///
    /// 已知局限(Q17,未验证,刻意不改):`baseURL` 带子路径(反代)时,以 `/` 开头的值会替换整个 path、
    /// 丢掉子路径,与 `directStreamURL` 不一致;服务端是否已写进子路径无从判断,待真机核实。
    func transcodeURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        return URL(string: relativePath, relativeTo: baseURL)
    }

    private func streamPathComponent(container: String?) -> String {
        guard let container, !container.isEmpty else { return "stream" }
        return "stream.\(container)"
    }
}
