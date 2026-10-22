import Foundation

/// TMDB 端点,路径与参数名以 `docs/TMDB_API.md` 为准,⛔ 不发明。
///
/// 不携带 token:v4 token 走 `Authorization: Bearer` 头(§1),由 `TMDBClient` 组装,`name` 因此天然不含凭据。
/// 查询串手拼,只保留 unreserved 字符、空格编 `%20`;⛔ 不走 `URLComponents.queryItems`
/// (它对 `/` 等字符的编码口径不同)。
enum TMDBEndpoint: Sendable, Equatable {

    /// `GET /3/search/movie?query=&year=&language=`
    case searchMovie(query: String, year: Int?, language: String)
    /// `GET /3/search/tv?query=&first_air_date_year=&language=`
    case searchTV(query: String, year: Int?, language: String)
    /// `GET /3/tv/{series_id}/season/{season_number}?language=`(§7)
    /// 只补分集(剧照 / 集名 / 简介);剧级信息 `/3/search/tv` 已给。
    case tvSeason(seriesID: Int, seasonNumber: Int, language: String)
    /// `GET /3/tv/{series_id}?language=`
    /// 文件名带 `{tmdbid-…}` 时按 id 直取,跳过搜索(§9)。
    case tvDetails(id: Int, language: String)
    /// `GET /3/movie/{movie_id}?language=`
    /// 标签只给 id,电影还是剧由调用方按上下文定(`TMDBClient.details`)。
    case movieDetails(id: Int, language: String)
    /// `GET /3/tv/{series_id}/credits?language=`(§10)
    /// 不用 `aggregate_credits`:它把多季角色放进 `roles[]`,形状不同。
    case tvCredits(id: Int, language: String)
    /// `GET /3/movie/{movie_id}/credits?language=`,与 `tvCredits` 同形
    case movieCredits(id: Int, language: String)

    // MARK: - 形状

    /// 元数据接口主机(图片主机是另一个,见 `TMDBImage`)
    var host: String { "api.themoviedb.org" }

    var path: String {
        switch self {
        case .searchMovie: return "/3/search/movie"
        case .searchTV: return "/3/search/tv"
        case .tvSeason(let seriesID, let seasonNumber, _):
            return "/3/tv/\(seriesID)/season/\(seasonNumber)"
        case .tvDetails(let id, _): return "/3/tv/\(id)"
        case .movieDetails(let id, _): return "/3/movie/\(id)"
        case .tvCredits(let id, _): return "/3/tv/\(id)/credits"
        case .movieCredits(let id, _): return "/3/movie/\(id)/credits"
        }
    }

    var method: String { "GET" }

    /// 诊断名,不含凭据,可进日志。
    var name: String {
        switch self {
        case .searchMovie: return "search/movie"
        case .searchTV: return "search/tv"
        case .tvSeason: return "tv/season"
        case .tvDetails: return "tv/details"
        case .movieDetails: return "movie/details"
        case .tvCredits: return "tv/credits"
        case .movieCredits: return "movie/credits"
        }
    }

    /// 顺序固定(便于断言与排障)。
    var queryItems: [(name: String, value: String)] {
        switch self {
        case .searchMovie(let query, let year, let language):
            var items: [(name: String, value: String)] = [("query", query)]
            // 没年份就不传,⛔ 不填 0 / 空串(§2)
            if let year { items.append(("year", String(year))) }
            items.append(("language", language))
            // `include_adult` 用官方默认值 false,不显式传
            return items
        case .searchTV(let query, let year, let language):
            var items: [(name: String, value: String)] = [("query", query)]
            if let year { items.append(("first_air_date_year", String(year))) }
            items.append(("language", language))
            return items
        case .tvSeason(_, _, let language):
            return [("language", language)]
        case .tvDetails(_, let language), .movieDetails(_, let language),
             .tvCredits(_, let language), .movieCredits(_, let language):
            return [("language", language)]
        }
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.percentEncodedQuery = encodedQuery
        return components.url
    }

    var encodedQuery: String {
        queryItems.compactMap { item -> String? in
            guard let name = Self.encode(item.name), let value = Self.encode(item.value) else {
                return nil
            }
            return "\(name)=\(value)"
        }
        .joined(separator: "&")
    }

    /// 只保留 unreserved 字符(`A-Za-z0-9-._~`)
    static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}