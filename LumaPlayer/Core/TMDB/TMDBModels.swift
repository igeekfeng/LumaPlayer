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

/// 只有匹配键 `episode_number` 必填;`name` 可能是 `""`,`overview` / `still_path` 可能是 `null`(§7)。
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
    let voteAverage: Double?

    // MARK: 只有详情端点才有值(§9),搜索命中时为空;列表卡片拿不到,⛔ 不为此改搜索链路

    let genres: [String]
    let tagline: String?
    let status: String?
    let productionCompanies: [String]
    /// 电影侧恒空
    let networks: [String]

    /// nil → UI 降级成图标卡
    var posterURL: URL? { TMDBImage.posterURL(path: posterPath) }

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
        self.voteAverage = result.voteAverage
        self.genres = (result.genres ?? []).compactMap { nonEmptyString($0.name) }
        self.tagline = nonEmptyString(result.tagline)
        self.status = nonEmptyString(result.status)
        self.productionCompanies = (result.productionCompanies ?? [])
            .compactMap { nonEmptyString($0.name) }
        self.networks = (result.networks ?? []).compactMap { nonEmptyString($0.name) }
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

/// `cast[]` / `crew[]` 同形不同填法(演员给 `character`,剧组给 `job` + `department`),一个类型收两边。
/// 除 `id` 外都可能缺;`name` 缺了是空串,由上层滤掉,⛔ 不伪造。
struct TMDBPerson: Sendable, Equatable, Identifiable, Decodable {
    let id: Int
    let name: String
    /// 演员:角色名;剧组:职务(`Director` / `Writer` / …)
    let role: String?
    /// 只有剧组给
    let department: String?
    let profilePath: String?
    /// `cast[]` 的主要程度,0 起;剧组没有 → 0
    let order: Int

    /// nil → UI 降级成图标
    var profileURL: URL? { TMDBImage.profileURL(path: profilePath) }

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

    /// 与 Emby 详情页 `DetailPeopleRow` 同一上限
    static let maxCastShown = 30

    /// 同 `TMDBCredits.names(withJob:)`
    func crewNames(withJob job: String) -> [String] {
        crew.filter { $0.role == job }.map(\.name).filter { !$0.isEmpty }
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

    /// `path` 形如 `/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg`;为空时返回 nil。
    static func posterURL(path: String?, size: String = posterSize) -> URL? {
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