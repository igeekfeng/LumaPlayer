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

    // MARK: 只有详情端点才给的字段(`docs/TMDB_API.md` §9)

    // ⚠️ 搜索响应里**没有**下面这几个 → 恒为 nil,所以一律可选。
    // 要显示类型名(`genres`)或评分之外的剧级信息,就得走 `/3/{tv|movie}/{id}`。

    /// 类型。⚠️ 搜索响应只有 `genre_ids`(数字),要名字必须走详情端点。
    let genres: [TMDBGenre]?
    /// 标语(可能为空串)
    let tagline: String?
    /// 连载 / 上映状态(如 `Ended` / `Released`)。⛔ 规格里**没有**枚举定义,
    /// 所以客户端不做完整映射,只认官方示例里出现过的值(见 `TMDBMatch.statusText`)。
    let status: String?
    let productionCompanies: [TMDBCompany]?
    /// 电视台。⛔ 电影侧没有这个字段。
    let networks: [TMDBCompany]?

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
        case genres
        case tagline
        case status
        case productionCompanies = "production_companies"
        case networks
    }
}

/// 类型(`genres[]` 元素,`docs/TMDB_API.md` §9)。只读 `name` —— `id` 本项目不用。
struct TMDBGenre: Decodable, Sendable, Equatable {
    let name: String?
}

/// 公司 / 电视台(`production_companies[]` 与 `networks[]` 元素,§9)。
/// 两者形状相同(`{id,name,logo_path,origin_country}`),只读 `name`。
struct TMDBCompany: Decodable, Sendable, Equatable {
    let name: String?
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

    // MARK: 详情端点才有的(`docs/TMDB_API.md` §9)

    // ⚠️ 走搜索命中时下面这些是**空** —— 它们只有 `/3/{tv|movie}/{id}` 才给。
    // 所以类型 / 状态 / 公司这类字段只在详情页有值,列表卡片上拿不到(⛔ 不为此改搜索链路)。

    /// 类型名(如 `剧情` / `奇幻`)。搜索响应只有数字 id → 空数组。
    let genres: [String]
    let tagline: String?
    /// 连载 / 上映状态。⛔ **规格里没有枚举定义**,所以这里只做有限的展示映射
    /// (`statusText`),认不出来的值原样返回 —— 不猜一个中文词盖上去。
    let status: String?
    let productionCompanies: [String]
    /// 电视台(电影侧恒空)
    let networks: [String]

    /// 海报绝对地址(`image.tmdb.org`)。没有 `poster_path` 时为 `nil` → UI 降级成图标卡。
    var posterURL: URL? { TMDBImage.posterURL(path: posterPath) }

    /// 状态的**展示文案**。
    ///
    /// ⚠️ 官方 OpenAPI 规格里 `status` 只是 `{"type":"string"}`,**没有枚举定义**
    /// (2026-10-14 核实),所以这里只能映射规格示例里出现过的值。
    /// 其余取值**原样显示英文** —— 那是 TMDB 给的原文,好过猜一个可能不对的中文词。
    var statusText: String? {
        guard let status = nonEmptyString(status) else { return nil }
        switch status {
        case "Ended": return "已完结"      // 规格示例(tv)
        case "Released": return "已上映"   // 规格示例(movie)
        default: return status
        }
    }

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
        self.overview = nonEmptyString(result.overview)
        // `poster_path` 为 `null` 或空串都当「没有海报」
        self.posterPath = nonEmptyString(result.posterPath)
        self.voteAverage = result.voteAverage
        self.genres = (result.genres ?? []).compactMap { nonEmptyString($0.name) }
        self.tagline = nonEmptyString(result.tagline)
        self.status = nonEmptyString(result.status)
        self.productionCompanies = (result.productionCompanies ?? [])
            .compactMap { nonEmptyString($0.name) }
        self.networks = (result.networks ?? []).compactMap { nonEmptyString($0.name) }
    }

    /// `YYYY-MM-DD` 取前 4 位当年份;短于 4 位或不是数字时为 `nil`。
    static func year(fromDate date: String?) -> Int? {
        guard let date = nonEmptyString(date), date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }
}

/// 空串与 `nil` 一样看待 —— TMDB 偶尔给 `""` 而不是 `null`(`docs/TMDB_API.md` §7)。
func nonEmptyString(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

// MARK: - 演职员(`docs/TMDB_API.md` §10)

/// 一个演职员。
///
/// ⚠️ `cast[]` 与 `crew[]` 是**同一形状的两种填法**:演员给 `character`,
/// 剧组给 `job` + `department`。所以这里用一个类型 + 自定义解码同时收下两边,
/// 调用方按 `role` 展示(演员是角色名,剧组是职务)。
///
/// ⚠️ **除 `id` 外一律可选**:真实数据里 `character` 可能是空串、`profile_path` 可能是
/// `null`、`name` 也可能缺(缺了就是空串,由上层滤掉,⛔ 不伪造一个名字)。
struct TMDBPerson: Sendable, Equatable, Identifiable, Decodable {
    let id: Int
    let name: String
    /// 演员:角色名;剧组:职务(`Director` / `Writer` / …)。空串当没有。
    let role: String?
    /// 部门(只有剧组给:`Directing` / `Writing` / `Production`)
    let department: String?
    let profilePath: String?
    /// TMDB 给的主要程度(`cast[]` 的 `order`,0 起;剧组没有这个字段 → 0)
    let order: Int

    /// 头像绝对地址(§11)。没有 `profile_path` 时为 `nil` → UI 降级成图标。
    var profileURL: URL? { TMDBImage.profileURL(path: profilePath) }

    /// 有没有可展示的头像
    var hasProfile: Bool { profilePath != nil }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case character
        case job
        case department
        case order
        case profilePath = "profile_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        // 演员给 `character`、剧组给 `job`,取到哪个用哪个
        let character = try container.decodeIfPresent(String.self, forKey: .character)
        let job = try container.decodeIfPresent(String.self, forKey: .job)
        self.role = nonEmptyString(character) ?? nonEmptyString(job)
        self.department = nonEmptyString(
            try container.decodeIfPresent(String.self, forKey: .department))
        self.profilePath = nonEmptyString(
            try container.decodeIfPresent(String.self, forKey: .profilePath))
        self.order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }
}

/// 一次演职员查询的结果(§10)。tv 与 movie 两个端点响应同形。
struct TMDBCredits: Sendable, Equatable {
    /// 演员表,**已按 TMDB 的 `order` 升序**(主要程度)
    let cast: [TMDBPerson]
    /// 剧组(导演 / 编剧 / 制片人…混在一起,按 `job` 取用)
    let crew: [TMDBPerson]

    /// 剧组里担任某个职务的人名(如 `Director` / `Writer`)。
    /// ⛔ 不给就是空数组,UI 那一行整块不显示。
    func names(withJob job: String) -> [String] {
        crew.filter { $0.role == job }.map(\.name).filter { !$0.isEmpty }
    }
}

/// 演职员端点的**线格式**(§10)。
///
/// ⚠️ 两个数组都写成可选:200 响应缺了某一个不该让整条解失败
/// —— 与 §3 / §7 的解码立场一致。
struct TMDBCreditsResponse: Decodable, Sendable {
    let cast: [TMDBPerson]?
    let crew: [TMDBPerson]?
}

/// 详情页要的**剧级扩展信息**:详情端点(§9)的字段 + 演职员(§10)。
///
/// ⚠️ 与列表刮削(`BaiduPanMetadataScraper.enrich`)**分开**,不是同一趟:
/// 那一趟按**标题**批量查、只补封面 / 简介 / 年份,一屏三十个目录也就那几次;
/// 这一趟按 **id** 精确取、要多发两次请求,所以只在**详情页**发。
/// 混在一起会让一屏三十个目录多烧六十次 TMDB 请求。
struct TMDBSeriesProfile: Sendable, Equatable {
    /// 详情端点命中的条目(类型 / 评分 / 标语 / 状态 / 制片公司都在它上面)
    let match: TMDBMatch
    /// 演员表(按 TMDB 的 `order` 升序)
    let cast: [TMDBPerson]
    /// 剧组
    let crew: [TMDBPerson]

    /// 演员表最多展示几个 —— 与 Emby 详情页的 `DetailPeopleRow` 同一上限
    static let maxCastShown = 30

    /// 剧组里担任某个职务的人名(如 `Director` / `Writer`)。
    /// ⛔ 不给就是空数组,详情页那一行整块不显示(与 `TMDBCredits.names(withJob:)` 同口径)。
    func crewNames(withJob job: String) -> [String] {
        crew.filter { $0.role == job }.map(\.name).filter { !$0.isEmpty }
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
    /// 人物头像档位(§11):头像卡片约 75pt 宽,`w185` 与剧照档位同一量级取舍
    static let profileSize = "w185"

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

    /// 人物头像的地址(§11)。拼法同上,只有档位不同 —— 头像接近方形。
    static func profileURL(path: String?, size: String = profileSize) -> URL? {
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