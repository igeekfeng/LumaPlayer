import Foundation

/// 弹弹play 开放平台用到的端点(`docs/DANDANPLAY_API.md` §2 - §5)。
///
/// ⛔ 只用文档里列出的端点 / 参数(CLAUDE.md 硬规则 1 的同一口径)。
/// 路径与参数名逐个对着官方 OpenAPI 规格(`api.dandanplay.net/swagger/v2/swagger.json`)抄。
///
/// ## 认证不放这里
///
/// 签名三件套(`X-AppId` / `X-Timestamp` / `X-Signature`)是**请求头**,由 `DandanplayClient`
/// 组装;端点只管「方法 + 路径 + 查询参数 + 请求体」,诊断名(`name`)天然不含凭据。
///
/// ## 路径一律小写
///
/// 签名串里要带路径(§1),官方建议「路径全部使用小写字母,不需要经过 URL 编码」。
/// 本文件的路径本来就只有小写字母、数字与 `/`,`signaturePath` 再显式 `lowercased()` 一次兜底。
enum DandanplayEndpoint: Sendable, Equatable {

    /// `POST /api/v2/match`:按文件名(及可选的 Hash / 大小 / 时长)找可能的节目(§2)
    case match(DandanplayMatchRequest)
    /// `GET /api/v2/search/episodes?anime=&episode=`:关键词搜剧集(§3)
    case searchEpisodes(anime: String, episode: String?)
    /// `GET /api/v2/bangumi/{animeId}`:作品详情,只读其中的剧集列表(§4)
    case bangumi(animeID: Int64)
    /// `GET /api/v2/comment/{episodeId}?withRelated=&chConvert=`:一个弹幕库的全部弹幕(§5)
    case comments(episodeID: Int64, withRelated: Bool, chineseConversion: ChineseConversion)

    /// `chConvert` 参数(§5):中文简繁转换。
    enum ChineseConversion: Int, Sendable, Equatable {
        case none = 0
        case simplified = 1
        case traditional = 2
    }

    static let host = "api.dandanplay.net"

    var path: String {
        switch self {
        case .match: return "/api/v2/match"
        case .searchEpisodes: return "/api/v2/search/episodes"
        case .bangumi(let id): return "/api/v2/bangumi/\(id)"
        case .comments(let id, _, _): return "/api/v2/comment/\(id)"
        }
    }

    /// 参与签名的路径:不含协议、域名与查询串,小写(§1)。
    var signaturePath: String { path.lowercased() }

    var method: String {
        switch self {
        case .match: return "POST"
        case .searchEpisodes, .bangumi, .comments: return "GET"
        }
    }

    /// 诊断用端点名。**不含凭据,也不含搜索词 / 文件名**(那是用户的观看内容)。
    var name: String {
        switch self {
        case .match: return "match"
        case .searchEpisodes: return "search/episodes"
        case .bangumi: return "bangumi"
        case .comments: return "comment"
        }
    }

    /// 查询参数。顺序固定(便于断言与排障)。
    var queryItems: [(name: String, value: String)] {
        switch self {
        case .match, .bangumi:
            return []
        case .searchEpisodes(let anime, let episode):
            var items: [(name: String, value: String)] = [("anime", anime)]
            // 不知道集数时**不传**(⛔ 不填 0 / 空串:服务端会按「指定集数」过滤)
            if let episode { items.append(("episode", episode)) }
            return items
        case .comments(_, let withRelated, let conversion):
            return [
                ("withRelated", withRelated ? "true" : "false"),
                ("chConvert", String(conversion.rawValue)),
            ]
        }
    }

    /// JSON 请求体(只有 `match` 有)。
    func body() throws -> Data? {
        switch self {
        case .match(let request): return try JSONEncoder().encode(request)
        case .searchEpisodes, .bangumi, .comments: return nil
        }
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = path
        let query = encodedQuery
        components.percentEncodedQuery = query.isEmpty ? nil : query
        return components.url
    }

    /// 手拼查询串:只保留 unreserved 字符(与 `TMDBEndpoint` 同一手法,中文按 UTF-8 逐字节编码)。
    var encodedQuery: String {
        queryItems.compactMap { item -> String? in
            guard let name = TMDBEndpoint.encode(item.name),
                  let value = TMDBEndpoint.encode(item.value) else { return nil }
            return "\(name)=\(value)"
        }
        .joined(separator: "&")
    }
}
