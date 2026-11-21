import Foundation

/// 豆瓣榜单。⚠️ **未公开接口**,事实来源是 `docs/DISCOVERY.md` §3.4 的实测记录。
///
/// 用的是豆瓣移动端网页自己打的 `rexxar` JSON 接口,不是抓 HTML:
/// `GET https://m.douban.com/rexxar/api/v2/subject_collection/{id}/items?start=&count=`
///
/// 三条实测出来的硬约束:
/// 1. **必须带 `Referer`**,指向同一个 collection 页;不带直接 400。
/// 2. `count` 上限 50(传 100 只回 50 条),本项目一页 20。
/// 3. 图床 `img3.doubanio.com` 有防盗链:裸请求回 418 + 14 字节占位,
///    带任一豆瓣站点的 `Referer` 才给真图(`DoubanImageHeaders`)。
struct DoubanDiscoverProvider: DiscoverProvider {
    let kind: DiscoverSourceKind = .douban

    private let session: URLSession
    /// 当天缓存。nil = 不缓存(单测里默认关,避免用例之间串数据)。
    private let cache: DoubanDiscoverCache?

    init(session: URLSession, cache: DoubanDiscoverCache? = nil) {
        self.session = session
        self.cache = cache
    }

    // MARK: - 榜单清单

    /// 只放**实测过、有稳定总量**的几组。豆瓣还有几十个 collection,但没验过的不往里写 ——
    /// 预置一堆大概率不通的榜单,和预置一堆死链搜索源是同一个错误。
    static let builtInBoards: [DiscoverBoard] = [
        DiscoverBoard(source: .douban, reference: "tv_hot", title: "热门剧集"),
        DiscoverBoard(source: .douban, reference: "movie_hot", title: "热门电影"),
        DiscoverBoard(source: .douban, reference: "movie_showing", title: "正在上映"),
        DiscoverBoard(source: .douban, reference: "tv_domestic", title: "国产剧"),
        DiscoverBoard(source: .douban, reference: "tv_american", title: "美剧"),
        DiscoverBoard(source: .douban, reference: "tv_animation", title: "动画"),
        DiscoverBoard(source: .douban, reference: "movie_top250", title: "豆瓣 Top 250"),
    ]

    var boards: [DiscoverBoard] { Self.builtInBoards }

    /// 豆瓣不需要凭据,也没有「未配置」这个状态。⛔ 不返回 `nil` 之外的任何东西冒充不可用:
    /// 真连不上时由 `load` 抛 `transport`,归到那一组的失败里。
    func availability() async -> DiscoverUnavailable? { nil }

    // MARK: - 取数

    /// 一页条数。豆瓣上限 50,取 20 够铺满一屏货架又不至于一次要太多。
    static let pageSize = 20

    func load(_ board: DiscoverBoard, page: Int) async throws -> DiscoverPage {
        guard board.source == .douban else {
            throw DiscoverError.unsupportedBoard(board.id)
        }
        let start = max(0, page) * Self.pageSize
        let url = try Self.itemsURL(collection: board.reference, start: start, count: Self.pageSize)

        // 同一个接口同一天只请求一次:剧集进度按天更新,当天重复打接口既没新数据又招风控
        let data: Data
        if let cached = await cache?.body(for: url) {
            data = cached
        } else {
            let fetched = try await fetch(url, collection: board.reference)
            await cache?.store(body: fetched, for: url)
            data = fetched
        }

        let decoded: DoubanCollectionResponse
        do {
            decoded = try JSONDecoder().decode(DoubanCollectionResponse.self, from: data)
        } catch {
            throw DiscoverError.decoding("subject_collection:\(Self.describe(error))")
        }
        let items = decoded.subjectCollectionItems.compactMap(\.discoverTitle)
        // 以 `start + 本页条数 < total` 判还有没有下一页。⛔ 不用「本页装满没」推断:
        // 末页本来就不满,而「条数 == count 但已经到底」的情况豆瓣会出现。
        return DiscoverPage(items: items, hasMore: start + Self.pageSize < decoded.total)
    }

    /// 真发一次请求并校验响应。缓存只包在它外面,错误处理不分叉。
    private func fetch(_ url: URL, collection: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.referer(for: collection), forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            // URLSession 取消抛的是 `URLError.cancelled`,不折成取消就会当成「连接失败」报出来
            guard error.code != .cancelled else { throw CancellationError() }
            throw DiscoverError.transport(URLErrorDescription.userText(error))
        } catch {
            // ⛔ 不用 `String(describing:)`:`URLError` 的 userInfo 带完整 URL
            let nsError = error as NSError
            throw DiscoverError.transport(
                SecretRedactor.redacted("\(nsError.domain) \(nsError.code):\(nsError.localizedDescription)"))
        }

        guard let http = response as? HTTPURLResponse else {
            throw DiscoverError.transport("响应不是 HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DiscoverError.http(statusCode: http.statusCode, message: nil)
        }
        return data
    }

    /// 单组超时。比 TMDB 的默认值短:这是未公开接口,卡住时早点把失败交给用户。
    static let timeout: TimeInterval = 12

    // MARK: - 端点

    static func itemsURL(collection: String, start: Int, count: Int) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "m.douban.com"
        components.path = "/rexxar/api/v2/subject_collection/\(collection)/items"
        components.queryItems = [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "count", value: String(count)),
        ]
        guard let url = components.url else {
            throw DiscoverError.transport("接口地址构造失败(\(collection))")
        }
        return url
    }

    /// `Referer` 必须指向同一个 collection 页,否则 400。
    static func referer(for collection: String) -> String {
        "https://m.douban.com/subject_collection/\(collection)"
    }

    private static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        switch decoding {
        case .keyNotFound(let key, _):
            return "缺少字段 \(key.stringValue)"
        case .typeMismatch(let type, let context):
            return "字段 \(context.codingPath.map(\.stringValue).joined(separator: ".")) 类型不是 \(type)"
        case .valueNotFound(let type, let context):
            return "字段 \(context.codingPath.map(\.stringValue).joined(separator: ".")) 为 null(期望 \(type))"
        case .dataCorrupted(let context):
            return "响应不是合法 JSON(\(context.debugDescription))"
        @unknown default:
            return "无法解析"
        }
    }
}

// MARK: - 线格式

/// `{start, count, total, subject_collection_items: [...]}`。只解用得到的字段。
struct DoubanCollectionResponse: Decodable, Sendable {
    let subjectCollectionItems: [DoubanCollectionItem]
    /// 这组榜单的总条数(全部分页加起来)。缺了就按「没有下一页」处理。
    let total: Int

    enum CodingKeys: String, CodingKey {
        case subjectCollectionItems = "subject_collection_items"
        case total
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 形状不对时给空数组而不是抛错:豆瓣这个接口偶尔回 `{}`,不该让整组变红
        subjectCollectionItems =
            try container.decodeIfPresent([DoubanCollectionItem].self, forKey: .subjectCollectionItems)
            ?? []
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
    }
}

/// 一条条目。⚠️ **形状不统一**:`movie_hot` 给 `cover` + `info`,Top 250 给 `pic` + `card_subtitle`,
/// 正在上映的还可能没有 `rating`。除 `id` 外一律可选,缺了就降级,⛔ 不伪造。
struct DoubanCollectionItem: Decodable, Sendable {
    let id: String
    let title: String?
    let type: String?
    let year: String?
    let cardSubtitle: String?
    let info: String?
    /// 剧集更新进度。⚠️ 没有长度上限,映射到 `DiscoverTitle` 时截断(见 `episodesInfoLine`)。
    let episodesInfo: String?
    let cover: DoubanCover?
    let pic: DoubanPic?
    let rating: DoubanRating?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case type
        case year
        case cardSubtitle = "card_subtitle"
        case info
        case episodesInfo = "episodes_info"
        case cover
        case pic
        case rating
    }

    /// `id` 是豆瓣 subject id,数字串。⛔ 认不出的直接丢(没有 id 就没法拼缓存 key 与详情地址)。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        year = try container.decodeIfPresent(String.self, forKey: .year)
        cardSubtitle = try container.decodeIfPresent(String.self, forKey: .cardSubtitle)
        info = try container.decodeIfPresent(String.self, forKey: .info)
        episodesInfo = try container.decodeIfPresent(String.self, forKey: .episodesInfo)
        cover = try container.decodeIfPresent(DoubanCover.self, forKey: .cover)
        pic = try container.decodeIfPresent(DoubanPic.self, forKey: .pic)
        rating = try container.decodeIfPresent(DoubanRating.self, forKey: .rating)
    }

    var discoverTitle: DiscoverTitle? {
        guard let title = nonEmptyString(title) else { return nil }
        return DiscoverTitle(
            id: "douban:\(id)",
            title: title,
            year: Self.year(from: year) ?? Self.year(fromCardSubtitle: cardSubtitle),
            rating: rating?.value,
            overview: nonEmptyString(info) ?? nonEmptyString(cardSubtitle),
            cardSubtitle: nonEmptyString(cardSubtitle),
            episodesInfo: nonEmptyString(episodesInfo),
            poster: poster)
    }

    /// 海报:`pic.large` / `pic.normal` 优先,退 `cover.url`。两套字段在不同 collection 里各出现一次。
    private var poster: DiscoverTitle.Poster? {
        let raw = nonEmptyString(pic?.large) ?? nonEmptyString(pic?.normal) ?? nonEmptyString(cover?.url)
        guard let raw, let url = URL(string: raw) else { return nil }
        return DiscoverTitle.Poster(url: url, headers: DoubanImageHeaders.headers)
    }

    private static func year(from raw: String?) -> Int? {
        guard let raw = nonEmptyString(raw), raw.count >= 4 else { return nil }
        return Int(raw.prefix(4))
    }

    /// Top 250 那批没有 `year` 字段,只有 `card_subtitle` 开头的 `1994 / 美国 / …`。
    private static func year(fromCardSubtitle subtitle: String?) -> Int? {
        guard let subtitle = nonEmptyString(subtitle) else { return nil }
        let head = subtitle.prefix(4)
        return Int(head)
    }
}

/// `cover: {url, width, height, shape}`
struct DoubanCover: Decodable, Sendable {
    let url: String?
}

/// `pic: {large, normal}`
struct DoubanPic: Decodable, Sendable {
    let large: String?
    let normal: String?
}

/// `rating: {value, count, max}`。正在上映的片子整块是 `null`。
struct DoubanRating: Decodable, Sendable {
    let value: Double?
}
