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
    /// `GET /3/tv/{series_id}/aggregate_credits?language=`(§10)
    /// ⚠️ 不用 `/credits`:那个只返回**最新一季**,前几季的演员不在响应里。
    case tvAggregateCredits(id: Int, language: String)
    /// `GET /3/movie/{movie_id}/credits?language=`,与剧集侧的 `credits` 同形(电影没有 aggregate 端点)
    case movieCredits(id: Int, language: String)
    /// `GET /3/tv/{series_id}/images?language=`(§12)
    case tvImages(id: Int, language: String)
    /// `GET /3/movie/{movie_id}/images?language=`(§12)
    case movieImages(id: Int, language: String)
    /// `GET /3/tv/{series_id}/season/{season_number}/images?language=`(§12)
    case tvSeasonImages(seriesID: Int, seasonNumber: Int, language: String)
    /// `GET /3/tv/{series_id}/season/{season_number}/episode/{episode_number}/images?language=`(§12)
    /// ⚠️ 每集一次请求,只在用户点开某一集的图片时才发(§12 请求纪律)。
    case tvEpisodeImages(seriesID: Int, seasonNumber: Int, episodeNumber: Int, language: String)

    // MARK: - 发现(「看什么」,`docs/DISCOVERY.md` §3)

    /// `GET /3/trending/{all|movie|tv}/{day|week}?language=`(§14)
    ///
    /// 这是「今晚看什么」的主入口:TMDB 自己按热度排,不需要用户先有片名。
    /// ⚠️ `all` 里混着人物(`media_type: "person"`),解码时按 `media_type` 分派,⛔ 不猜。
    /// `page` 是查询参数(1 起,规格里 `/3/trending/{media_type}/{time_window}` 支持翻页)。
    case trending(
        mediaType: TMDBTrendingMediaType,
        window: TMDBTrendingWindow,
        page: Int,
        language: String
    )

    /// `GET /3/discover/movie?sort_by=&page=&language=&with_genres=&vote_count.gte=`(§14)
    case discoverMovie(TMDBDiscoverQuery, language: String)

    /// `GET /3/discover/tv?sort_by=&page=&language=&with_genres=&vote_count.gte=`(§14)
    case discoverTV(TMDBDiscoverQuery, language: String)

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
        case .tvAggregateCredits(let id, _): return "/3/tv/\(id)/aggregate_credits"
        case .movieCredits(let id, _): return "/3/movie/\(id)/credits"
        case .tvImages(let id, _): return "/3/tv/\(id)/images"
        case .movieImages(let id, _): return "/3/movie/\(id)/images"
        case .tvSeasonImages(let seriesID, let season, _):
            return "/3/tv/\(seriesID)/season/\(season)/images"
        case .tvEpisodeImages(let seriesID, let season, let episode, _):
            return "/3/tv/\(seriesID)/season/\(season)/episode/\(episode)/images"
        case .trending(let mediaType, let window, _, _):
            return "/3/trending/\(mediaType.rawValue)/\(window.rawValue)"
        case .discoverMovie: return "/3/discover/movie"
        case .discoverTV: return "/3/discover/tv"
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
        case .tvAggregateCredits: return "tv/aggregate_credits"
        case .movieCredits: return "movie/credits"
        case .tvImages: return "tv/images"
        case .movieImages: return "movie/images"
        case .tvSeasonImages: return "tv/season/images"
        case .tvEpisodeImages: return "tv/episode/images"
        case .trending(let mediaType, let window, _, _):
            return "trending/\(mediaType.rawValue)/\(window.rawValue)"
        case .discoverMovie: return "discover/movie"
        case .discoverTV: return "discover/tv"
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
             .tvAggregateCredits(_, let language), .movieCredits(_, let language),
             .tvImages(_, let language), .movieImages(_, let language),
             .tvSeasonImages(_, _, let language), .tvEpisodeImages(_, _, _, let language):
            // ⛔ 不传 include_image_language:拿官方给的全部候选(§12)
            return [("language", language)]
        case .trending(_, _, let page, let language):
            return [("page", String(page)), ("language", language)]
        case .discoverMovie(let query, let language), .discoverTV(let query, let language):
            return query.queryItems + [("language", language)]
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
// MARK: - 发现参数(`docs/DISCOVERY.md` §3)

/// `/3/trending/{media_type}/{time_window}` 的两段路径参数。
///
/// 取自官方 OpenAPI 规格(`paths./3/trending/all/{time_window}`):`time_window` 只有
/// `day` / `week` 两个枚举值,`media_type` 有 `all` / `movie` / `tv` / `person`。
/// 本项目只用前三个 —— `person` 不是可播放内容。
enum TMDBTrendingMediaType: String, Sendable, CaseIterable {
    case all
    case movie
    case tv
}

enum TMDBTrendingWindow: String, Sendable, CaseIterable {
    case day
    case week
}

/// `/3/discover/{movie|tv}` 的查询参数。**只放本项目真正会传的**,
/// 规格里其余几十个参数(`with_companies` / `with_watch_providers` 等)⛔ 不预先加进来 ——
/// 没人用的参数只会让「为什么请求是这样」变难查。
struct TMDBDiscoverQuery: Sendable, Equatable {
    /// 规格枚举:`popularity.desc` / `vote_average.desc` / `primary_release_date.desc` 等。
    /// 本项目只暴露三档,见 `TMDBDiscoverSort`。
    var sortBy: TMDBDiscoverSort = .popularity
    var page: Int = 1
    /// 类型 id 的逗号分隔串(TMDB genre id)。`nil` = 不限
    var genreIDs: [Int] = []
    /// 评分下限(0–10)。`nil` = 不限
    var minimumRating: Double?
    /// 评分人数下限。**排序用 `vote_average.desc` 时必须给** ——
    /// 否则会搜出「1 个人打了 10 分」的冷门片(这是 TMDB 的已知行为,官方也建议配 `vote_count.gte`)
    var minimumVoteCount: Int?
    /// 上映 / 首播日期下限(含)。`YYYY-MM-DD`
    var releasedAfter: String?
    /// 上映 / 首播日期上限(含)。`YYYY-MM-DD`
    var releasedBefore: String?
    /// 原始语言(`zh` / `en` / `ja`…)。`nil` = 不限
    var originalLanguage: String?

    /// 顺序固定(便于断言与排障)。⛔ 空值不传,不写空串。
    var queryItems: [(name: String, value: String)] {
        var items: [(name: String, value: String)] = [
            ("sort_by", sortBy.rawValue),
            ("page", String(page)),
            // 官方默认就是 false,显式传是为了让「搜到成人内容」这件事不可能发生
            ("include_adult", "false"),
        ]
        if !genreIDs.isEmpty {
            items.append(("with_genres", genreIDs.map(String.init).joined(separator: ",")))
        }
        if let minimumRating { items.append(("vote_average.gte", String(minimumRating))) }
        if let minimumVoteCount { items.append(("vote_count.gte", String(minimumVoteCount))) }
        if let releasedAfter { items.append(("primary_release_date.gte", releasedAfter)) }
        if let releasedBefore { items.append(("primary_release_date.lte", releasedBefore)) }
        if let originalLanguage { items.append(("with_original_language", originalLanguage)) }
        return items
    }
}

/// 发现页的排序档位。⛔ 只给这三档:其余排序在「看什么」场景里没有意义。
enum TMDBDiscoverSort: String, Sendable, CaseIterable {
    /// 热度(默认)
    case popularity = "popularity.desc"
    /// 评分。⚠️ 必须配 `minimumVoteCount`,见 `TMDBDiscoverQuery.minimumVoteCount`
    case rating = "vote_average.desc"
    /// 最新上映
    case newest = "primary_release_date.desc"

    var displayName: String {
        switch self {
        case .popularity: return "热度"
        case .rating: return "评分"
        case .newest: return "最新"
        }
    }

    /// 这一档是否要求评分人数下限
    var requiresVoteCount: Bool { self == .rating }
}
