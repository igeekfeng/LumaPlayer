import Foundation

/// 播放 URL 的构造处(API_CONTRACT.md 4.5)。
///
/// 值类型、无状态 → 天然 Sendable,可以不经过网络层直接单测。
/// ⛔ 不得在别处手拼串流 URL:路径与参数名一律以 4.5 为准。
struct PlaybackURLBuilder: Sendable, Equatable {
    /// 站点根,**不含** `/emby`(API_CONTRACT.md 1.2)
    var baseURL: URL
    /// `/emby` 或 ""。由探测确定后写入,不每次重猜(1.2、1.4)
    var apiPathPrefix: String

    /// DirectStream:`{base}{prefix}/Videos/{Id}/stream[.{Container}]?static=true&MediaSourceId=..&PlaySessionId=..`
    ///
    /// - `static=true` 是 DirectStream 的标识:服务端按静态资源原样吐文件,
    ///   客户端可自由 seek(4.5)。
    /// - 扩展名按**输出**格式取;DirectStream 输出 == 输入,故用
    ///   `MediaSource.Container`。容器未知时用不带扩展名的 `/stream`
    ///   —— 官方两种写法都列了,不猜扩展名。
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
        // 顺序固定(4.5 的必填参数表),便于测试断言
        components.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: mediaSourceID),
            URLQueryItem(name: "PlaySessionId", value: playSessionID),
        ]
        return components.url
    }

    /// DirectStream:采用服务端在 `MediaSource.DirectStreamUrl` 里给的地址(API_CONTRACT.md 4.5.1)。
    ///
    /// - Emby Web 就是原样请求这个地址;自拼的 `/Videos/{id}/stream.{ext}?static=true` 在部分
    ///   服务器(带网关)上拿到的是 200 + JSON 错误体(issue #2)。
    /// - 相对路径**相对 API 根**(`baseURL` + `apiPathPrefix`),不是站点根;已带前缀的不重复加。
    /// - 剥掉 `api_key`:认证由请求头承担(6.1),URL 不带 token。绝对地址原样采用其 host。
    /// - 解析不了返回 nil,由调用方退回 `directStreamURL(itemID:…)`。
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

    /// 转码:直接拼 `MediaSource.TranscodingUrl`。
    ///
    /// 该值是**相对路径**(通常已带 `/emby` 前缀,如
    /// `/emby/videos/{id}/master.m3u8?...`),拼到站点根上即可;
    /// 少数服务器给绝对地址时 `URL(string:relativeTo:)` 会原样采用。
    /// ⛔ 不在这里补认证参数:认证头由播放内核携带(第 6 节)。
    ///
    /// ⚠️ **已知局限(docs/KNOWN_ISSUES.md Q17,未验证,行为刻意保持不变)**:
    /// `baseURL` 带子路径时(反代部署,如 `https://example.com/media`),
    /// 以 `/` 开头的 `TranscodingUrl` 按 RFC 3986 会替换整个 path,
    /// 子路径段被丢掉 —— 而 `directStreamURL` 用 `append(path:)` 会保留它,
    /// 两条路径对同一个 baseURL 给出不一致的结果。
    /// 服务端是否已把部署子路径写进 `TranscodingUrl` 无从判断,
    /// 不猜:留待真机核实后再改。
    func transcodeURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        return URL(string: relativePath, relativeTo: baseURL)
    }

    private func streamPathComponent(container: String?) -> String {
        guard let container, !container.isEmpty else { return "stream" }
        return "stream.\(container)"
    }
}
