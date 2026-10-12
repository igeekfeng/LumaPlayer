import Foundation

/// TMDB 用到的端点(`docs/TMDB_API.md` §1 - §2)。
///
/// ⛔ 与 `EmbyEndpoint` / `BaiduPanEndpoint` 是三个东西,不得混用
/// (CLAUDE.md 硬规则 1:端点、参数名以文档为准,不得发明)。
/// 路径与参数名逐个对着 `docs/TMDB_API.md` 抄,响应字段在官方 OpenAPI 规格核实过。
///
/// ## 认证不放这里
///
/// TMDB 的 v4 token 走 `Authorization: Bearer` **请求头**(§1),
/// 所以端点**不携带** token —— 它只负责「路径 + 查询参数」,
/// 请求头由 `TMDBClient` 组装。好处是端点的诊断名(`name`)天然不含凭据。
///
/// ## 查询串手拼
///
/// 与 `BaiduPanEndpoint` 同一手法:只保留 unreserved 字符(`A-Za-z0-9-._~`),
/// 空格编成 `%20`(官方 cURL 示例用的是 `+`,TMDB 两种都收,`%20` 无歧义)。
/// 不走 `URLComponents.queryItems`:它对 `/` 一类字符的处置与我们的口径不一致,
/// 中文标题这类非 ASCII 也要保证按 UTF-8 逐字节编码。
enum TMDBEndpoint: Sendable, Equatable {

    /// `GET /3/search/movie?query=&year=&language=`
    case searchMovie(query: String, year: Int?, language: String)
    /// `GET /3/search/tv?query=&first_air_date_year=&language=`
    case searchTV(query: String, year: Int?, language: String)
    /// `GET /3/tv/{series_id}/season/{season_number}?language=`
    ///
    /// 取一季的**分集**(剧照 / 集名 / 单集简介),`docs/TMDB_API.md` §7。
    /// ⚠️ 剧级海报 / 简介 / 首播年**不**走它 —— 那些 `/3/search/tv` 已经给过(§3),
    /// 这里只补分集。
    case tvSeason(seriesID: Int, seasonNumber: Int, language: String)
    /// `GET /3/tv/{series_id}?language=`
    ///
    /// 按**显式 id** 直取剧集(跳过搜索)—— 标准命名里的 `{tmdbid-63926}`
    /// 已经给了 id,再按标题搜一遍既慢又可能搜错(`docs/TMDB_API.md` §9)。
    case tvDetails(id: Int, language: String)
    /// `GET /3/movie/{movie_id}?language=`
    ///
    /// 按**显式 id** 直取电影。与 `tvDetails` 成对 —— 标签只给 id,
    /// 是电影还是剧由调用方按上下文决定(见 `TMDBClient.details`)。
    case movieDetails(id: Int, language: String)

    // MARK: - 形状

    /// 元数据接口主机(图片主机是另一个,见 `TMDBImage`)
    var host: String { "api.themoviedb.org" }

    /// 不含 host 的路径
    var path: String {
        switch self {
        case .searchMovie: return "/3/search/movie"
        case .searchTV: return "/3/search/tv"
        case .tvSeason(let seriesID, let seasonNumber, _):
            return "/3/tv/\(seriesID)/season/\(seasonNumber)"
        case .tvDetails(let id, _): return "/3/tv/\(id)"
        case .movieDetails(let id, _): return "/3/movie/\(id)"
        }
    }

    var method: String { "GET" }

    /// 诊断用端点名。**不含任何凭据**,可安全进日志(CLAUDE.md「安全与隐私」)。
    var name: String {
        switch self {
        case .searchMovie: return "search/movie"
        case .searchTV: return "search/tv"
        case .tvSeason: return "tv/season"
        case .tvDetails: return "tv/details"
        case .movieDetails: return "movie/details"
        }
    }

    /// 查询参数。顺序固定(便于断言与排障),值一律整体 URL 编码。
    var queryItems: [(name: String, value: String)] {
        switch self {
        case .searchMovie(let query, let year, let language):
            var items: [(name: String, value: String)] = [("query", query)]
            // 年份解析不出来时**不传**这个参数,⛔ 不填 0 / 空串这类假默认值
            // (`docs/TMDB_API.md` §2)
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
            // 季详情的 series_id / season_number 走 **path**(§7),不进查询串
            return [("language", language)]
        case .tvDetails(_, let language), .movieDetails(_, let language):
            // 按 id 直取:id 走 path,只有语言进查询串
            return [("language", language)]
        }
    }

    /// 拼好的绝对地址。
    var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.percentEncodedQuery = encodedQuery
        return components.url
    }

    /// 手拼的查询串(POSIX 编码:空格 → `%20`)
    var encodedQuery: String {
        queryItems.compactMap { item -> String? in
            guard let name = Self.encode(item.name), let value = Self.encode(item.value) else {
                return nil
            }
            return "\(name)=\(value)"
        }
        .joined(separator: "&")
    }

    /// 只保留 unreserved 字符(`A-Za-z0-9-._~`)。
    static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}