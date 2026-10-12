import Foundation

// MARK: - 线格式(Decodable)

/// 搜索响应(`/3/search/movie` 与 `/3/search/tv` 顶层同形,`docs/TMDB_API.md` §3)。
///
/// ⚠️ 只解本项目**真正读**的 `results`:官方规格里还有 `page` / `total_pages` /
/// `total_results`,但首轮不做翻页,⛔ 不为用不到的字段写代码。
/// `results` 写成**必填**:200 响应没有它就是形状不对,应当抛解码错误而不是静默成空数组。
struct TMDBSearchResponse: Decodable, Sendable {
    let results: [TMDBResult]
}

/// `results[]` 里的一个条目。
///
/// ⚠️ **除 `id` 外一律可选**。TMDB 对没有海报 / 没有上映日的条目会返回 `null`,
/// 把它们写成必填会让整条解失败 —— 与百度侧「能缺的字段一律可选、⛔ 不填假值」
/// (`BaiduPanFileMeta` 的注释)同一口径(`docs/TMDB_API.md` §3)。
struct TMDBResult: Decodable, Sendable, Equatable {
    /// TMDB 条目 id。唯一必给字段。
    let tmdbID: Int

    // 电影侧
    let title: String?
    let originalTitle: String?
    let releaseDate: String?

    // 剧集侧
    let name: String?
    let originalName: String?
    let firstAirDate: String?

    let overview: String?
    let posterPath: String?
    let voteAverage: Double?

    enum CodingKeys: String, CodingKey {
        case tmdbID = "id"
        case title
        case originalTitle = "original_title"
        case releaseDate = "release_date"
        case name
        case originalName = "original_name"
        case firstAirDate = "first_air_date"
        case overview
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
    }
}

// MARK: - 季详情线格式(Decodable)

/// 季详情响应(`/3/tv/{series_id}/season/{season_number}`,`docs/TMDB_API.md` §7)。
///
/// ⚠️ 只解 `episodes`:规格里还有 `name` / `overview` / `poster_path` 等**季级**字段,
/// 但剧级海报 / 简介已经由 `/3/search/tv` 给过(§3),季级那几个本项目不读,
/// ⛔ 不为用不到的字段写代码。
/// `episodes` 写成**必填**:200 响应没有它就是形状不对,应当抛解码错误而不是静默成空数组
/// —— 与 `TMDBSearchResponse.results` 同一口径。
struct TMDBSeasonResponse: Decodable, Sendable {
    let episodes: [TMDBEpisode]
}

/// `episodes[]` 里的一集。
///
/// ⚠️ **除 `episode_number` 外一律可选**(§7 的解码立场):`name` 可能是 `""`、
/// `overview` / `still_path` 可能是 `null`。把它们写成必填会让整季解失败。
/// `episode_number` 是回填时的**匹配键**,没有它这一集就没法用,所以是必填。
struct TMDBEpisode: Decodable, Sendable, Equatable {
    let episodeNumber: Int
    let name: String?
    let overview: String?
    let stillPath: String?

    enum CodingKeys: String, CodingKey {
        case episodeNumber = "episode_number"
        case name
        case overview
        case stillPath = "still_path"
    }

    /// 分集剧照的绝对地址(`docs/TMDB_API.md` §8)。没有剧照时为 `nil` → UI 降级成图标卡。
    var stillURL: URL? { TMDBImage.stillURL(path: stillPath) }
}

// MARK: - 领域类型

/// 一次刮削命中的条目(电影或剧)。⛔ 不伪造字段:缺就是 `nil`。
///
/// 这是**刮削链路的输出**:`BaiduPanMetadataSynthesizer.parse` 从文件名解析出
/// 标题 / 年份后,交给 `TMDBClient` 查询,命中项折成它。它比 `TMDBResult` 干净
/// ——只留下展示用得上的那几个,并已把电影 / 剧两套字段名归一。
///
/// ⚠️ `title` 可为 `nil`(见下),`kind` 由**调用的是哪个端点**决定。
struct TMDBMatch: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable, CaseIterable {
        case movie
        case tv
    }

    let tmdbID: Int
    let kind: Kind
    /// 展示标题:电影取 `title`(退 `original_title`),剧取 `name`(退 `original_name`)。
    ///
    /// ⚠️ 官方规格里这两个字段理论上必给,但真实数据存在 `null`。
    /// 为 `nil` 时由上层退回文件名解析出的标题 —— ⛔ 不用空串冒充有标题。
    let title: String?
    /// 上映 / 首播年(从 `release_date` / `first_air_date` 的 `YYYY-MM-DD` 取前 4 位)。
    let year: Int?
    let overview: String?
    /// 海报相对路径(进 `posterURL`)
    let posterPath: String?
    let voteAverage: Double?

    /// 海报绝对地址(`image.tmdb.org`)。没有 `poster_path` 时为 `nil` → UI 降级成图标卡。
    var posterURL: URL? { TMDBImage.posterURL(path: posterPath) }

    /// 从一个原始条目 + 它来自哪个端点,折成命中项。
    init(result: TMDBResult, kind: Kind) {
        self.tmdbID = result.tmdbID
        self.kind = kind
        switch kind {
        case .movie:
            self.title = result.title ?? result.originalTitle
            self.year = Self.year(fromDate: result.releaseDate)
        case .tv:
            self.title = result.name ?? result.originalName
            self.year = Self.year(fromDate: result.firstAirDate)
        }
        self.overview = Self.nonEmpty(result.overview)
        // `poster_path` 为 `null` 或空串都当「没有海报」
        self.posterPath = Self.nonEmpty(result.posterPath)
        self.voteAverage = result.voteAverage
    }

    /// `YYYY-MM-DD` 取前 4 位当年份;短于 4 位或不是数字时为 `nil`。
    static func year(fromDate date: String?) -> Int? {
        guard let date = nonEmpty(date), date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    /// 空串与 `nil` 一样看待 —— TMDB 偶尔给 `""` 而不是 `null`。
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - 图片地址

/// TMDB 图片 CDN 的地址拼装(`docs/TMDB_API.md` §4)。
///
/// 官方 `docs/image-basics` 的三段拼法:`{base_url}/{file_size}/{file_path}`。
/// 本项目海报固定用 `w500`,不做「先问 `/3/configuration` 再拼」那一趟
/// —— 与百度「能少发请求就少发」同一取舍,⛔ 不为一个常量多发一次请求。
enum TMDBImage {
    static let host = "image.tmdb.org"
    /// 海报档位:宽 500,列表卡片足够,又不至于把原图整张拉下来
    static let posterSize = "w500"
    /// 分集剧照档位:剧照是 16:9 横图(§8),`w300` 与卡片宽度同量级
    static let stillSize = "w300"

    /// `https://image.tmdb.org/t/p/{size}/{path}`。
    /// `path` 形如 `/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg`(自带前导斜杠)。
    /// 没有 `path` 时为 `nil`。
    static func posterURL(path: String?, size: String = posterSize) -> URL? {
        url(path: path, size: size)
    }

    /// 分集剧照的地址(§8)。拼法与海报一致,只有档位不同 —— 剧照比海报宽。
    static func stillURL(path: String?, size: String = stillSize) -> URL? {
        url(path: path, size: size)
    }

    private static func url(path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        // `path` 是 TMDB 给的相对路径(可能不带前导斜杠),统一补一个再拼,
        // 否则会拼成 `/t/p/w500pB8...jpg` 这种错地址。
        components.path = "/t/p/\(size)/" + path.drop(while: { $0 == "/" })
        return components.url
    }
}