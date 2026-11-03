import Foundation

/// 弹弹play 服务地址。
///
/// 默认官方 `https://api.dandanplay.net`。自建的弹弹play 兼容服务(第三方实现的 dandanplay 协议)
/// 填它的根地址 —— 这类服务的令牌写在 URL 路径里,所以要带路径前缀,
/// 例如 `http://127.0.0.1:9321/87654321`。
///
/// ⛔ 空串 = 官方服务;非空但解析不出来 = `nil`,调用方如实报错。
/// 把用户填错的地址静默换成官方服务,只会换来一串看不懂的 403。
struct DandanplayBase: Sendable, Equatable {

    /// 官方服务。硬编码,⛔ 不从设置里读。
    static let official = DandanplayBase(scheme: "https", host: "api.dandanplay.net", port: nil, pathPrefix: "")

    let scheme: String
    let host: String
    /// 80 / 443 不写进 URL,其余端口要。
    let port: Int?
    /// 令牌等路径前缀,以 `/` 开头、不含尾 `/`。官方为空。
    let pathPrefix: String

    init(scheme: String, host: String, port: Int?, pathPrefix: String) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.pathPrefix = pathPrefix
    }

    /// 空串 = 官方服务;非空但解析不出来 = nil。
    init?(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self = .official
            return
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty,
              url.query == nil, url.fragment == nil
        else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        self.scheme = scheme
        self.host = host
        self.port = (url.port ?? defaultPort) == defaultPort ? nil : url.port
        self.pathPrefix = Self.normalizedPath(url.path)
    }

    /// `URL.path` 已归一成以 `/` 开头,这里只去掉尾 `/`。
    private static func normalizedPath(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// 拼出接口完整地址。`path` 以 `/` 开头,`query` 是已 percent-encoded 的查询串。
    func url(path: String, percentEncodedQuery query: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = pathPrefix + path
        components.percentEncodedQuery = query.isEmpty ? nil : query
        return components.url
    }
}
