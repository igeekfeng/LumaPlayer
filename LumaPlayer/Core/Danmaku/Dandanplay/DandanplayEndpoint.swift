import Foundation

/// 弹弹play 端点(`docs/DANDANPLAY_API.md` §2 - §5)。⛔ 只用文档里列出的端点 / 参数
/// (对照官方 OpenAPI 规格 `api.dandanplay.net/swagger/v2/swagger.json`)。
/// 签名头由 `DandanplayClient` 组装,这里只管方法、路径、查询参数、请求体。
enum DandanplayEndpoint: Sendable, Equatable {

    /// `POST /api/v2/match`(§2)
    case match(DandanplayMatchRequest)
    /// `GET /api/v2/search/episodes`(§3)。`anime` 与 `tmdbId` 至少给一个;
    /// `tmdbIdType` 只配合 `tmdbId`:0 = 电视剧,1 = 电影。
    case searchEpisodes(
        anime: String?, episode: String?, tmdbID: Int? = nil, tmdbIDType: Int? = nil)
    /// `GET /api/v2/bangumi/{animeId}`,只读其中的剧集列表(§4)
    case bangumi(animeID: Int64)
    /// `GET /api/v2/comment/{episodeId}`(§5)
    case comments(episodeID: Int64, withRelated: Bool, chineseConversion: ChineseConversion)

    /// `chConvert`:简繁转换(§5)
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

    /// 参与签名的路径:不含协议、域名与查询串,小写、不 URL 编码(§1)。
    var signaturePath: String { path.lowercased() }

    var method: String {
        switch self {
        case .match: return "POST"
        case .searchEpisodes, .bangumi, .comments: return "GET"
        }
    }

    /// 诊断用端点名。⛔ 不含凭据、搜索词、文件名(用户观看内容)。
    var name: String {
        switch self {
        case .match: return "match"
        case .searchEpisodes: return "search/episodes"
        case .bangumi: return "bangumi"
        case .comments: return "comment"
        }
    }

    /// 顺序固定(便于断言与排障)。
    var queryItems: [(name: String, value: String)] {
        switch self {
        case .match, .bangumi:
            return []
        case .searchEpisodes(let anime, let episode, let tmdbID, let tmdbIDType):
            var items: [(name: String, value: String)] = []
            // 空串不算给了(anime 至少 2 个字符)
            if let anime, !anime.isEmpty { items.append(("anime", anime)) }
            // 不知道集数时不传(⛔ 不填 0 / 空串:服务端会按指定集数过滤)
            if let episode, !episode.isEmpty { items.append(("episode", episode)) }
            if let tmdbID {
                items.append(("tmdbId", String(tmdbID)))
                // 不给时服务端按 0 处理
                if let tmdbIDType { items.append(("tmdbIdType", String(tmdbIDType))) }
            }
            return items
        case .comments(_, let withRelated, let conversion):
            return [
                ("withRelated", withRelated ? "true" : "false"),
                ("chConvert", String(conversion.rawValue)),
            ]
        }
    }

    /// 只有 `match` 有。
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

    /// 手拼查询串,只保留 unreserved 字符(同 `TMDBEndpoint`)。
    var encodedQuery: String {
        queryItems.compactMap { item -> String? in
            guard let name = TMDBEndpoint.encode(item.name),
                  let value = TMDBEndpoint.encode(item.value) else { return nil }
            return "\(name)=\(value)"
        }
        .joined(separator: "&")
    }
}
