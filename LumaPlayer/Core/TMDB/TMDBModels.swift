import Foundation

// MARK: - 线格式(Decodable)

/// 搜索响应(movie / tv 同形,`docs/TMDB_API.md` §3)。不翻页,只解 `results`;
/// 它必填:200 没有它就是形状不对,要抛解码错误而不是静默成空数组。
struct TMDBSearchResponse: Decodable, Sendable {
    let results: [TMDBResult]
}

/// `results[]` 条目。除 `id` 外一律可选:TMDB 对缺海报 / 上映日的条目给 `null`(§3)。
struct TMDBResult: Decodable, Sendable, Equatable {
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
    /// 横版背景图相对路径(§9)。搜索响应也带,可为 `null`
    let backdropPath: String?
    let voteAverage: Double?

    // MARK: 只有详情端点 `/3/{tv|movie}/{id}` 才给(§9),搜索响应里恒为 nil

    /// 搜索响应只有数字 `genre_ids`,要名字必须走详情端点
    let genres: [TMDBGenre]?
    /// 可能为空串
    let tagline: String?
    /// 如 `Ended` / `Released`;规格没有枚举定义(见 `TMDBMatch.statusText`)
    let status: String?
    let productionCompanies: [TMDBCompany]?
    /// 电视台,电影侧没有
    let networks: [TMDBCompany]?
    /// 完结日(tv)。电影侧没有
    let lastAirDate: String?
    /// 全剧总集数 / 总季数(tv)。⛔ 只作展示,不覆盖网盘目录里实际存的东西
    let numberOfEpisodes: Int?
    let numberOfSeasons: Int?
    /// 单集片长(分钟,tv)。电影侧另有 `runtime`(本项目不读)
    let episodeRunTime: [Int]?

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
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case genres
        case tagline
        case status
        case productionCompanies = "production_companies"
        case networks
        case lastAirDate = "last_air_date"
        case numberOfEpisodes = "number_of_episodes"
        case numberOfSeasons = "number_of_seasons"
        case episodeRunTime = "episode_run_time"
    }

    /// 详情端点独有的字段用 `decodeIfPresent`:搜索响应里没有这些键,不该让整条解失败(§3 解码立场)。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tmdbID = try container.decode(Int.self, forKey: .tmdbID)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle)
        self.releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.originalName = try container.decodeIfPresent(String.self, forKey: .originalName)
        self.firstAirDate = try container.decodeIfPresent(String.self, forKey: .firstAirDate)
        self.overview = try container.decodeIfPresent(String.self, forKey: .overview)
        self.posterPath = try container.decodeIfPresent(String.self, forKey: .posterPath)
        self.backdropPath = try container.decodeIfPresent(String.self, forKey: .backdropPath)
        self.voteAverage = try container.decodeIfPresent(Double.self, forKey: .voteAverage)
        self.genres = try container.decodeIfPresent([TMDBGenre].self, forKey: .genres)
        self.tagline = try container.decodeIfPresent(String.self, forKey: .tagline)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.productionCompanies = try container.decodeIfPresent(
            [TMDBCompany].self, forKey: .productionCompanies)
        self.networks = try container.decodeIfPresent([TMDBCompany].self, forKey: .networks)
        self.lastAirDate = try container.decodeIfPresent(String.self, forKey: .lastAirDate)
        self.numberOfEpisodes = try container.decodeIfPresent(Int.self, forKey: .numberOfEpisodes)
        self.numberOfSeasons = try container.decodeIfPresent(Int.self, forKey: .numberOfSeasons)
        self.episodeRunTime = try container.decodeIfPresent([Int].self, forKey: .episodeRunTime)
    }

    /// 测试与合成用;线格式本身只走 `init(from:)`。
    init(
        tmdbID: Int,
        title: String? = nil,
        originalTitle: String? = nil,
        releaseDate: String? = nil,
        name: String? = nil,
        originalName: String? = nil,
        firstAirDate: String? = nil,
        overview: String? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        voteAverage: Double? = nil,
        genres: [TMDBGenre]? = nil,
        tagline: String? = nil,
        status: String? = nil,
        productionCompanies: [TMDBCompany]? = nil,
        networks: [TMDBCompany]? = nil,
        lastAirDate: String? = nil,
        numberOfEpisodes: Int? = nil,
        numberOfSeasons: Int? = nil,
        episodeRunTime: [Int]? = nil
    ) {
        self.tmdbID = tmdbID
        self.title = title
        self.originalTitle = originalTitle
        self.releaseDate = releaseDate
        self.name = name
        self.originalName = originalName
        self.firstAirDate = firstAirDate
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.voteAverage = voteAverage
        self.genres = genres
        self.tagline = tagline
        self.status = status
        self.productionCompanies = productionCompanies
        self.networks = networks
        self.lastAirDate = lastAirDate
        self.numberOfEpisodes = numberOfEpisodes
        self.numberOfSeasons = numberOfSeasons
        self.episodeRunTime = episodeRunTime
    }
}

/// `genres[]` 元素(§9),只读 `name`。
struct TMDBGenre: Decodable, Sendable, Equatable {
    let name: String?
}

/// `production_companies[]` / `networks[]` 元素(同形),只读 `name`。
struct TMDBCompany: Decodable, Sendable, Equatable {
    let name: String?
}

// MARK: - 季详情线格式(Decodable)

/// 季详情响应(§7)。只解 `episodes`,必填(理由同 `TMDBSearchResponse.results`)。
struct TMDBSeasonResponse: Decodable, Sendable {
    let episodes: [TMDBEpisode]
}

/// 只有匹配键 `episode_number` 必填;`name` 可能是 `""`,`overview` / `still_path` / `air_date` 可能是 `null`(§7)。
struct TMDBEpisode: Decodable, Sendable, Equatable {
    let episodeNumber: Int
    let name: String?
    let overview: String?
    let stillPath: String?
    /// `YYYY-MM-DD`,可能为 `null` / 空串(未播出的集)
    let airDate: String?
    /// 分钟,可能为 `null`
    let runtime: Int?
    let voteAverage: Double?

    enum CodingKeys: String, CodingKey {
        case episodeNumber = "episode_number"
        case name
        case overview
        case stillPath = "still_path"
        case airDate = "air_date"
        case runtime
        case voteAverage = "vote_average"
    }

    /// nil → UI 降级成图标卡
    var stillURL: URL? { TMDBImage.stillURL(path: stillPath) }
}

// MARK: - 领域类型

/// 刮削命中项:只留展示要的字段,电影 / 剧两套字段名已归一。缺就是 nil,⛔ 不伪造。
/// `kind` 由调用的端点决定。
struct TMDBMatch: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable, CaseIterable {
        case movie
        case tv
    }

    let tmdbID: Int
    let kind: Kind
    /// 规格说必给但真实数据有 `null`;nil 时上层退回文件名解析出的标题,⛔ 不用空串冒充。
    let title: String?
    let year: Int?
    let overview: String?
    let posterPath: String?
    /// 横版背景图(§9)。搜索命中时也带,可为 nil
    let backdropPath: String?
    let voteAverage: Double?

    // MARK: 只有详情端点才有值(§9),搜索命中时为空;列表卡片拿不到,⛔ 不为此改搜索链路

    let genres: [String]
    let tagline: String?
    let status: String?
    let productionCompanies: [String]
    /// 电影侧恒空
    let networks: [String]
    /// `YYYY-MM-DD` 原文(首播 / 上映);未取到就是 nil,⛔ 不伪造。
    /// 与 `year` 分开:详情页「信息」区显示完整日期,元信息行只显示年。
    let firstAirDate: String?
    /// tv 完结日;电影侧恒 nil
    let lastAirDate: String?
    /// tv 全剧总集数 / 总季数(§9)。⚠️ 只是 TMDB 的记录,不代表用户网盘里存了多少。
    let numberOfEpisodes: Int?
    let numberOfSeasons: Int?
    /// tv 单集片长(分钟);空数组 = 没有
    let episodeRunTime: [Int]

    /// nil → UI 降级成图标卡
    var posterURL: URL? { TMDBImage.posterURL(path: posterPath) }

    /// 横版背景图(§9)。nil → hero 退回竖版海报放大模糊
    var backdropURL: URL? { TMDBImage.backdropURL(path: backdropPath) }

    /// 规格里 `status` 没有枚举定义,只映射规格示例出现过的值;其余原样显示英文,⛔ 不猜中文词。
    var statusText: String? {
        guard let status = nonEmptyString(status) else { return nil }
        switch status {
        case "Ended": return "已完结"      // 规格示例(tv)
        case "Released": return "已上映"   // 规格示例(movie)
        default: return status
        }
    }

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
        self.posterPath = nonEmptyString(result.posterPath)
        self.backdropPath = nonEmptyString(result.backdropPath)
        self.voteAverage = result.voteAverage
        self.genres = (result.genres ?? []).compactMap { nonEmptyString($0.name) }
        self.tagline = nonEmptyString(result.tagline)
        self.status = nonEmptyString(result.status)
        self.productionCompanies = (result.productionCompanies ?? [])
            .compactMap { nonEmptyString($0.name) }
        self.networks = (result.networks ?? []).compactMap { nonEmptyString($0.name) }
        self.firstAirDate = nonEmptyString(result.firstAirDate ?? result.releaseDate)
        self.lastAirDate = nonEmptyString(result.lastAirDate)
        self.numberOfEpisodes = result.numberOfEpisodes
        self.numberOfSeasons = result.numberOfSeasons
        self.episodeRunTime = result.episodeRunTime ?? []
    }

    /// `YYYY-MM-DD` 取前 4 位;不足 4 位或非数字为 nil。
    static func year(fromDate date: String?) -> Int? {
        guard let date = nonEmptyString(date), date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }
}

/// TMDB 偶尔给 `""` 而不是 `null`(§7),空串当 nil。
func nonEmptyString(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

// MARK: - 演职员(`docs/TMDB_API.md` §10)

/// `cast[]` / `crew[]` 同形不同填法:电影(及剧 `/credits`)给单个 `character` / `job`,
/// 剧 `aggregate_credits` 给 `roles[]` / `jobs[]`(§10)。两种形状都收进这一个类型。
/// 除 `id` 外都可能缺;`name` 缺了是空串,由上层滤掉,⛔ 不伪造。
struct TMDBPerson: Sendable, Equatable, Identifiable, Decodable {
    let id: Int
    let name: String
    /// 演员的角色名 / 剧组的职务名;取 `character`、`job`,或 aggregate 的 `roles[0]` / `jobs[0]`。
    let role: String?
    /// 只有剧组给
    let department: String?
    let profilePath: String?
    /// `cast[]` 的主要程度,0 起;剧组没有 → 0
    let order: Int
    /// 剧 `aggregate_credits` 的参演 / 参与总集数;电影 `/credits` 没有 → nil
    let totalEpisodeCount: Int?

    /// nil → UI 降级成图标
    var profileURL: URL? { TMDBImage.profileURL(path: profilePath) }

    var hasProfile: Bool { profilePath != nil }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case character
        case job
        case roles
        case jobs
        case department
        case order
        case profilePath = "profile_path"
        case totalEpisodeCount = "total_episode_count"
    }

    /// `roles[]` / `jobs[]` 元素:只取 `character` / `job`,忽略 `credit_id` / `episode_count`。
    private struct Role: Decodable {
        let character: String?
        let job: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        let character = try container.decodeIfPresent(String.self, forKey: .character)
        let job = try container.decodeIfPresent(String.self, forKey: .job)
        let roles = try container.decodeIfPresent([Role].self, forKey: .roles) ?? []
        let jobs = try container.decodeIfPresent([Role].self, forKey: .jobs) ?? []
        // 单个字段优先(电影 / 剧 credits),aggregate 取首项;⛔ 一人多角色不摊成多张卡
        self.role = nonEmptyString(character)
            ?? nonEmptyString(job)
            ?? roles.compactMap({ nonEmptyString($0.character) }).first
            ?? jobs.compactMap({ nonEmptyString($0.job) }).first
        self.department = nonEmptyString(
            try container.decodeIfPresent(String.self, forKey: .department))
        self.profilePath = nonEmptyString(
            try container.decodeIfPresent(String.self, forKey: .profilePath))
        self.order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        self.totalEpisodeCount = try container.decodeIfPresent(
            Int.self, forKey: .totalEpisodeCount)
    }

    /// 测试用;线格式本身只走 `init(from:)`。
    init(
        id: Int,
        name: String,
        role: String? = nil,
        department: String? = nil,
        profilePath: String? = nil,
        order: Int = 0,
        totalEpisodeCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.department = department
        self.profilePath = profilePath
        self.order = order
        self.totalEpisodeCount = totalEpisodeCount
    }
}

/// 演职员查询结果(§10)。
struct TMDBCredits: Sendable, Equatable {
    /// 已按 `order` 升序
    let cast: [TMDBPerson]
    /// 各职务混在一起,按 `job` 取用
    let crew: [TMDBPerson]

    /// 空数组 = UI 那一行整块不显示
    func names(withJob job: String) -> [String] {
        crew.filter { $0.role == job }.map(\.name).filter { !$0.isEmpty }
    }
}

/// 演职员线格式(§10)。两个数组都可选:缺一个不该让整条解失败。
struct TMDBCreditsResponse: Decodable, Sendable {
    let cast: [TMDBPerson]?
    let crew: [TMDBPerson]?
}

/// 详情页的剧级扩展信息:详情端点(§9)+ 演职员(§10)。
/// ⛔ 不并进列表刮削(`BaiduPanMetadataScraper.enrich`):每条要多发两次请求,一屏三十个目录就多六十次。
struct TMDBSeriesProfile: Sendable, Equatable {
    let match: TMDBMatch
    /// 按 `order` 升序
    let cast: [TMDBPerson]
    let crew: [TMDBPerson]

    /// 同 `TMDBCredits.names(withJob:)`
    func crewNames(withJob job: String) -> [String] {
        crew.filter { $0.role == job }.map(\.name).filter { !$0.isEmpty }
    }
}

// MARK: - 图片集合(§12)

/// `/images` 响应元素的领域类型。⛔ 只留展示要的字段,缺就是 nil。
struct TMDBImageAsset: Sendable, Equatable, Identifiable {
    /// `file_path` 自带版本语义,可直接作 id 与缓存 key
    let filePath: String
    let width: Int?
    let height: Int?

    var id: String { filePath }
}

/// `/images` 各端点的领域结果:没有那一类就是空数组(⛔ 不用假数据占位)。
struct TMDBImageSet: Sendable, Equatable {
    var backdrops: [TMDBImageAsset] = []
    var posters: [TMDBImageAsset] = []
    var logos: [TMDBImageAsset] = []
    var stills: [TMDBImageAsset] = []

    var isEmpty: Bool {
        backdrops.isEmpty && posters.isEmpty && logos.isEmpty && stills.isEmpty
    }
}

/// `/images` 线格式(§12)。四类数组都可能缺 / 为空;`file_path` 之外一律可选。
struct TMDBImagesResponse: Decodable, Sendable {
    let backdrops: [TMDBImageAssetLine]?
    let posters: [TMDBImageAssetLine]?
    let logos: [TMDBImageAssetLine]?
    let stills: [TMDBImageAssetLine]?
}

/// `file_path` 必填(没有路径的图没法展示);其余可选。
struct TMDBImageAssetLine: Decodable, Sendable {
    let filePath: String
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case width
        case height
    }
}

extension TMDBImagesResponse {
    var asImageSet: TMDBImageSet {
        TMDBImageSet(
            backdrops: Self.assets(backdrops),
            posters: Self.assets(posters),
            logos: Self.assets(logos),
            stills: Self.assets(stills)
        )
    }

    private static func assets(_ lines: [TMDBImageAssetLine]?) -> [TMDBImageAsset] {
        (lines ?? [])
            .filter { !$0.filePath.isEmpty }
            .map { TMDBImageAsset(filePath: $0.filePath, width: $0.width, height: $0.height) }
    }
}

// MARK: - 图片地址

/// TMDB 图片地址:`https://image.tmdb.org/t/p/{size}/{path}`(§4)。档位写死,
/// ⛔ 不为一个常量先问 `/3/configuration`。
enum TMDBImage {
    static let host = "image.tmdb.org"
    /// 列表卡片够用,又不拉原图
    static let posterSize = "w500"
    /// 剧照是 16:9 横图(§8),与卡片宽度同量级
    static let stillSize = "w300"
    /// 头像卡片约 75pt 宽(§11)
    static let profileSize = "w185"
    /// 背景图用 `/3/configuration` 给的 backdrop 档位(§12)
    static let backdropSize = "w1280"
    /// 海报墙(§12)
    static let galleryPosterSize = "w500"
    /// Logo 墙(§12)
    static let logoSize = "w300"

    /// `path` 形如 `/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg`;为空时返回 nil。
    static func posterURL(path: String?, size: String = posterSize) -> URL? {
        url(path: path, size: size)
    }

    static func backdropURL(path: String?, size: String = backdropSize) -> URL? {
        url(path: path, size: size)
    }

    static func stillURL(path: String?, size: String = stillSize) -> URL? {
        url(path: path, size: size)
    }

    static func profileURL(path: String?, size: String = profileSize) -> URL? {
        url(path: path, size: size)
    }

    private static func url(path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        // `path` 可能不带前导斜杠,统一去掉再拼,免得拼成 `/t/p/w500pB8...jpg`
        components.path = "/t/p/\(size)/" + path.drop(while: { $0 == "/" })
        return components.url
    }
}