import XCTest
@testable import LumaPlayer

/// 豆瓣榜单 provider(`docs/DISCOVERY.md` §3.4)。
/// ⛔ 零真实网络:全部走 `MockEmbyURLProtocol`。
final class DoubanDiscoverTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
    }

    override func tearDown() {
        MockEmbyURLProtocol.reset()
        super.tearDown()
    }

    private func makeProvider() -> DoubanDiscoverProvider {
        DoubanDiscoverProvider(session: MockEmbyURLProtocol.makeSession())
    }

    // MARK: - 端点

    func testItemsURL() throws {
        let url = try DoubanDiscoverProvider.itemsURL(collection: "tv_hot", start: 0, count: 20)
        XCTAssertEqual(url.host(), "m.douban.com")
        XCTAssertEqual(url.path, "/rexxar/api/v2/subject_collection/tv_hot/items")
        XCTAssertEqual(url.query, "start=0&count=20")
    }

    /// `Referer` 必须指向同一个 collection 页:不带直接 400。
    func testRefererPointsAtSameCollection() {
        XCTAssertEqual(
            DoubanDiscoverProvider.referer(for: "movie_top250"),
            "https://m.douban.com/subject_collection/movie_top250")
    }

    func testRequestCarriesReferer() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"subject_collection_items": []}"#),
            host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/tv_hot/items")
        _ = try await makeProvider().load(
            DiscoverBoard(source: .douban, reference: "tv_hot", title: "热门剧集"), page: 0)

        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/items"))
        XCTAssertEqual(request.header("Referer"), DoubanDiscoverProvider.referer(for: "tv_hot"))
    }

    // MARK: - 解码

    /// `movie_hot` 形状:`cover` + `info`,有 `year` 与 `rating`。
    func testDecodesCoverShape() async throws {
        let json = """
        {"subject_collection_items": [
          {"id": "36847425", "title": "可能的爱", "type": "movie", "year": "2026",
           "info": "韩国 / 剧情 爱情",
           "rating": {"value": 8.6, "count": 70647, "max": 10},
           "cover": {"url": "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p1.jpg",
                     "width": 2025, "height": 3000}}
        ]}
        """
        MockEmbyURLProtocol.stub(
            .json(json), host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/movie_hot/items")
        let titles = try await makeProvider().load(
            DiscoverBoard(source: .douban, reference: "movie_hot", title: "热门电影"), page: 0).items

        let title = try XCTUnwrap(titles.first)
        XCTAssertEqual(title.id, "douban:36847425")
        XCTAssertEqual(title.title, "可能的爱")
        XCTAssertEqual(title.year, 2026)
        XCTAssertEqual(title.rating, 8.6)
        XCTAssertEqual(title.subtitle, "2026 · 8.6 分")
        XCTAssertEqual(title.searchKeyword, "可能的爱")
        XCTAssertEqual(
            title.poster?.url.absoluteString,
            "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p1.jpg")
        // 图床防盗链:不带 Referer 回 418
        XCTAssertEqual(title.poster?.headers, DoubanImageHeaders.headers)
    }

    /// Top 250 形状:`pic` + `card_subtitle`,**没有** `year` / `cover` / `info`。
    func testDecodesPicShapeWithoutYear() async throws {
        let json = """
        {"subject_collection_items": [
          {"id": "1292052", "title": "肖申克的救赎", "type": "movie",
           "card_subtitle": "1994 / 美国 / 剧情 犯罪",
           "rating": {"count": 3366700, "max": 10, "star_count": 5.0, "value": 9.7},
           "pic": {"large": "https://img3.doubanio.com/l.jpg",
                   "normal": "https://img3.doubanio.com/n.jpg"}}
        ]}
        """
        MockEmbyURLProtocol.stub(
            .json(json), host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/movie_top250/items")
        let titles = try await makeProvider().load(
            DiscoverBoard(source: .douban, reference: "movie_top250", title: "豆瓣 Top 250"), page: 0).items

        let title = try XCTUnwrap(titles.first)
        // 年份从 `card_subtitle` 的前 4 位来
        XCTAssertEqual(title.year, 1994)
        // 有 `large` 就不退 `normal`
        XCTAssertEqual(title.poster?.url.absoluteString, "https://img3.doubanio.com/l.jpg")
    }

    /// 正在上映的片子整块 `rating` 是 `null`:卡片不该有评分段,⛔ 不补 0 分。
    func testMissingRatingOmitsScore() async throws {
        let json = """
        {"subject_collection_items": [
          {"id": "36915988", "title": "饥饿游戏：收获日出", "type": "movie", "year": "2026",
           "info": "美国 / 动作", "rating": null,
           "cover": {"url": "https://img3.doubanio.com/p.jpg"}}
        ]}
        """
        MockEmbyURLProtocol.stub(
            .json(json), host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/movie_showing/items")
        let titles = try await makeProvider().load(
            DiscoverBoard(source: .douban, reference: "movie_showing", title: "正在上映"), page: 0).items

        let title = try XCTUnwrap(titles.first)
        XCTAssertNil(title.rating)
        XCTAssertEqual(title.subtitle, "2026")
    }

    /// 没有标题的条目丢掉:卡片没标题等于不可用。
    func testDropsItemsWithoutTitle() async throws {
        let json = """
        {"subject_collection_items": [
          {"id": "1", "title": "有标题"},
          {"id": "2"}
        ]}
        """
        MockEmbyURLProtocol.stub(
            .json(json), host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/tv_hot/items")
        let titles = try await makeProvider().load(
            DiscoverBoard(source: .douban, reference: "tv_hot", title: "热门剧集"), page: 0).items
        XCTAssertEqual(titles.map(\.title), ["有标题"])
    }

    /// 剧集榜单给 `card_subtitle` + `episodes_info`,两者都要进页面模型(卡片上展示)。
    func testDecodesCardSubtitleAndEpisodesInfo() async throws {
        let json = """
        {"subject_collection_items": [
          {"id": "36689621", "title": "时差一万里", "type": "tv", "year": "2026",
           "card_subtitle": "2026 / 中国大陆 / 剧情 爱情 / 猫的树 / 杨超越 董思成",
           "episodes_info": "更新至12集",
           "rating": {"value": 7.2, "count": 100, "max": 10},
           "pic": {"large": "https://img3.doubanio.com/l.jpg"}}
        ]}
        """
        MockEmbyURLProtocol.stub(
            .json(json), host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/tv_hot/items")
        let page = try await makeProvider().load(
            DiscoverBoard(source: .douban, reference: "tv_hot", title: "热门剧集"), page: 0)
        let title = try XCTUnwrap(page.items.first)

        XCTAssertEqual(title.cardSubtitle, "2026 / 中国大陆 / 剧情 爱情 / 猫的树 / 杨超越 董思成")
        XCTAssertEqual(title.episodesInfo, "更新至12集")
        XCTAssertEqual(title.episodesInfoLine, "更新至12集")
    }

    /// 电影榜单没有 `episodes_info` / `card_subtitle`:给 nil,⛔ 不拿 `info` 冒充。
    func testMissingCardSubtitleAndEpisodesInfoAreNil() async throws {
        let json = """
        {"subject_collection_items": [
          {"id": "1", "title": "可能的爱", "type": "movie", "year": "2026",
           "info": "韩国 / 剧情 爱情"}
        ]}
        """
        MockEmbyURLProtocol.stub(
            .json(json), host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/movie_hot/items")
        let page = try await makeProvider().load(
            DiscoverBoard(source: .douban, reference: "movie_hot", title: "热门电影"), page: 0)
        let title = try XCTUnwrap(page.items.first)
        XCTAssertNil(title.cardSubtitle)
        XCTAssertNil(title.episodesInfo)
        XCTAssertNil(title.episodesInfoLine)
    }

    // MARK: - 当天缓存

    /// 同一个接口同一天只请求一次:第二次走缓存,不再发请求。
    func testSecondLoadSameDayHitsCache() async throws {
        let cache = DoubanDiscoverCache(fileURL: .temporaryDiscoverCacheFile())
        MockEmbyURLProtocol.stub(
            .json(#"{"total": 209, "subject_collection_items": [{"id": "1", "title": "x"}]}"#),
            host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/tv_hot/items")
        let provider = DoubanDiscoverProvider(session: MockEmbyURLProtocol.makeSession(), cache: cache)
        let board = DiscoverBoard(source: .douban, reference: "tv_hot", title: "热门剧集")

        _ = try await provider.load(board, page: 0)
        let requestsAfterFirst = MockEmbyURLProtocol.recordedRequests()
            .filter { $0.url.path.hasSuffix("/items") }.count
        _ = try await provider.load(board, page: 0)
        let requestsAfterSecond = MockEmbyURLProtocol.recordedRequests()
            .filter { $0.url.path.hasSuffix("/items") }.count

        XCTAssertEqual(requestsAfterFirst, 1)
        XCTAssertEqual(requestsAfterSecond, 1, "同一天第二次加载应当命中缓存")
    }

    /// 换一天就重新请求:缓存按自然日失效,不是按 TTL。
    func testCacheExpiresNextDay() async throws {
        let fileURL = URL.temporaryDiscoverCacheFile()
        let firstDay = Date(timeIntervalSince1970: 1_700_000_000)
        let nextDay = firstDay.addingTimeInterval(24 * 3600)
        let url = try DoubanDiscoverProvider.itemsURL(collection: "tv_hot", start: 0, count: 20)
        let body = Data(#"{"subject_collection_items": []}"#.utf8)

        let sameDay = DoubanDiscoverCache(fileURL: fileURL, now: { firstDay })
        await sameDay.store(body: body, for: url)
        let hit = await DoubanDiscoverCache(fileURL: fileURL, now: { firstDay.addingTimeInterval(3600) })
            .body(for: url)
        XCTAssertEqual(hit, body, "同一天内换实例(重启 App)也要命中")

        let expired = await DoubanDiscoverCache(fileURL: fileURL, now: { nextDay }).body(for: url)
        XCTAssertNil(expired, "第二天必须重新请求")
    }

    /// 不同页是不同的 URL,各自缓存:翻页不会被第一页的缓存串掉。
    func testCacheKeyedByPage() async throws {
        let fileURL = URL.temporaryDiscoverCacheFile()
        let cache = DoubanDiscoverCache(fileURL: fileURL)
        let first = try DoubanDiscoverProvider.itemsURL(collection: "tv_hot", start: 0, count: 20)
        let second = try DoubanDiscoverProvider.itemsURL(collection: "tv_hot", start: 20, count: 20)
        await cache.store(body: Data("first".utf8), for: first)

        let cachedFirst = await cache.body(for: first)
        let cachedSecond = await cache.body(for: second)
        XCTAssertEqual(cachedFirst, Data("first".utf8))
        XCTAssertNil(cachedSecond)
    }

    // MARK: - 分页

    /// `page` 换算成 `start = page * 20`。
    func testSecondPageRequestsNextStart() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"total": 209, "subject_collection_items": [{"id": "1", "title": "第二条"}]}"#),
            host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/tv_hot/items")
        _ = try await makeProvider().load(
            DiscoverBoard(source: .douban, reference: "tv_hot", title: "热门剧集"), page: 1)

        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/items"))
        let query = try XCTUnwrap(request.url.query)
        XCTAssertTrue(query.contains("start=20"), "第二页应当从第 20 条起:\(query)")
        XCTAssertTrue(query.contains("count=20"))
    }

    /// 以 `start + 本页条数 < total` 判还有没有下一页。
    func testHasMoreFollowsTotal() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"total": 209, "subject_collection_items": [{"id": "1", "title": "x"}]}"#),
            host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/tv_hot/items")
        let page = try await makeProvider().load(
            DiscoverBoard(source: .douban, reference: "tv_hot", title: "热门剧集"), page: 0)
        XCTAssertTrue(page.hasMore, "209 条、每页 20,第一页后面还有")
    }

    /// 末页:start=200 + 20 不小于 209,⛔ 不再给「加载更多」。
    func testLastPageHasNoMore() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"total": 209, "subject_collection_items": [{"id": "1", "title": "x"}]}"#),
            host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/tv_hot/items")
        let page = try await makeProvider().load(
            DiscoverBoard(source: .douban, reference: "tv_hot", title: "热门剧集"), page: 10)
        XCTAssertFalse(page.hasMore, "第 10 页(start=200)已经到底")
    }

    /// 缺 `total` 时按「没有下一页」处理,⛔ 不无限翻。
    func testMissingTotalMeansNoMore() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"subject_collection_items": [{"id": "1", "title": "x"}]}"#),
            host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/tv_hot/items")
        let page = try await makeProvider().load(
            DiscoverBoard(source: .douban, reference: "tv_hot", title: "热门剧集"), page: 0)
        XCTAssertFalse(page.hasMore)
    }

    /// 形状不对(空对象)时给空数组,⛔ 不让整组变红。
    func testMissingItemsKeyYieldsEmpty() async throws {
        MockEmbyURLProtocol.stub(
            .json("{}"), host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/tv_hot/items")
        let titles = try await makeProvider().load(
            DiscoverBoard(source: .douban, reference: "tv_hot", title: "热门剧集"), page: 0).items
        XCTAssertTrue(titles.isEmpty)
    }

    // MARK: - 失败

    /// 403 / 418 是豆瓣风控挡下来的典型码,错误文案要说清是反爬而不是用户网络的问题。
    func testForbiddenMentionsAntiScraping() async throws {
        MockEmbyURLProtocol.stub(
            .status(418), host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/tv_hot/items")
        do {
            _ = try await makeProvider().load(
                DiscoverBoard(source: .douban, reference: "tv_hot", title: "热门剧集"), page: 0)
            XCTFail("418 应当抛错")
        } catch let error as DiscoverError {
            XCTAssertEqual(error, .http(statusCode: 418, message: nil))
            XCTAssertTrue(error.userMessage.contains("风控"))
        }
    }

    func testTransportFailureIsReported() async throws {
        MockEmbyURLProtocol.stub(
            .failure(.notConnectedToInternet), host: "m.douban.com",
            path: "/rexxar/api/v2/subject_collection/tv_hot/items")
        do {
            _ = try await makeProvider().load(
                DiscoverBoard(source: .douban, reference: "tv_hot", title: "热门剧集"), page: 0)
            XCTFail("网络失败应当抛错")
        } catch let error as DiscoverError {
            XCTAssertEqual(error.userMessage, "连接失败:本机没有网络连接")
        }
    }

    /// 榜单配错来源是**配置错误**,要抛出去,⛔ 不静默返回空数组。
    func testWrongSourceThrowsUnsupportedBoard() async throws {
        do {
            _ = try await makeProvider().load(
                DiscoverBoard(source: .tmdb, reference: "trending", title: "本周热门"), page: 0)
            XCTFail("来源对不上应当抛错")
        } catch let error as DiscoverError {
            XCTAssertEqual(error, .unsupportedBoard("tmdb.trending"))
        }
    }

    // MARK: - 榜单清单

    func testBuiltInBoardsAreDoubanAndUnique() {
        let boards = DoubanDiscoverProvider.builtInBoards
        XCTAssertFalse(boards.isEmpty)
        XCTAssertTrue(boards.allSatisfy { $0.source == .douban })
        XCTAssertEqual(Set(boards.map(\.id)).count, boards.count, "榜单 id 必须唯一")
        XCTAssertTrue(boards.contains { $0.reference == "tv_hot" })
    }

    func testDoubanNeedsNoCredential() async {
        let reason = await makeProvider().availability()
        XCTAssertNil(reason)
    }
}

/// 页面模型:`DiscoverTitle` 的展示规则。
final class DiscoverTitleTests: XCTestCase {

    private func makeTitle(
        year: Int?, rating: Double?, poster: DiscoverTitle.Poster? = nil,
        cardSubtitle: String? = nil, episodesInfo: String? = nil
    ) -> DiscoverTitle {
        DiscoverTitle(
            id: "douban:1", title: "示例", year: year, rating: rating,
            overview: nil, cardSubtitle: cardSubtitle, episodesInfo: episodesInfo, poster: poster)
    }

    func testSubtitleJoinsYearAndRating() {
        XCTAssertEqual(makeTitle(year: 2026, rating: 8.6).subtitle, "2026 · 8.6 分")
    }

    func testSubtitleOmitsMissingParts() {
        XCTAssertEqual(makeTitle(year: 2026, rating: nil).subtitle, "2026")
        XCTAssertEqual(makeTitle(year: nil, rating: 9.1).subtitle, "9.1 分")
        XCTAssertEqual(makeTitle(year: nil, rating: nil).subtitle, "")
        // 0 分等于「还没人评」,不该画成「0.0 分」
        XCTAssertEqual(makeTitle(year: 2026, rating: 0).subtitle, "2026")
    }

    func testSearchKeywordIsBareTitle() {
        XCTAssertEqual(makeTitle(year: 2026, rating: 8.6).searchKeyword, "示例")
    }

    /// 短进度原样显示。
    func testEpisodesInfoLineKeepsShortText() {
        XCTAssertEqual(makeTitle(year: 2026, rating: 8.6, episodesInfo: "更新至12集").episodesInfoLine, "更新至12集")
        XCTAssertEqual(makeTitle(year: 2026, rating: 8.6, episodesInfo: "24集全").episodesInfoLine, "24集全")
    }

    /// 长进度按字数截断并加省略号:卡片只有一行位置。
    func testEpisodesInfoLineTruncatesLongText() throws {
        let long = String(repeating: "更新至", count: 20)
        let line = try XCTUnwrap(makeTitle(year: 2026, rating: 8.6, episodesInfo: long).episodesInfoLine)
        XCTAssertEqual(line.count, DiscoverTitle.episodesInfoMaxLength + 1, "截断后加一个省略号")
        XCTAssertTrue(line.hasSuffix("…"))
        // 原值保留:`.help` 里要给全文
        XCTAssertEqual(makeTitle(year: 2026, rating: 8.6, episodesInfo: long).episodesInfo, long)
    }

    /// 空串 / 纯空白当作没有,⛔ 不留一行空文本占高度。
    func testEpisodesInfoLineDropsBlank() {
        XCTAssertNil(makeTitle(year: 2026, rating: 8.6, episodesInfo: "").episodesInfoLine)
        XCTAssertNil(makeTitle(year: 2026, rating: 8.6, episodesInfo: "  \n ").episodesInfoLine)
        XCTAssertNil(makeTitle(year: 2026, rating: 8.6).episodesInfoLine)
    }

    /// 图片描述符要带上 provider 给的请求头(豆瓣图床防盗链)。
    func testPosterDescriptorCarriesHeaders() throws {
        let poster = DiscoverTitle.Poster(
            url: try XCTUnwrap(URL(string: "https://img3.doubanio.com/p.jpg")),
            headers: DoubanImageHeaders.headers)
        let descriptor = try XCTUnwrap(makeTitle(year: 2026, rating: 8.6, poster: poster).posterDescriptor)
        guard case .remote(let url, let headers) = descriptor.origin else {
            return XCTFail("应当是 remote")
        }
        XCTAssertEqual(url.absoluteString, "https://img3.doubanio.com/p.jpg")
        XCTAssertEqual(headers, ["Referer": "https://movie.douban.com/"])
        // 缓存 key 含条目 id:换一页不会串图
        XCTAssertEqual(descriptor.cacheKey, "douban:1-poster")
    }

    func testNoPosterYieldsNoDescriptor() {
        XCTAssertNil(makeTitle(year: 2026, rating: 8.6, poster: nil).posterDescriptor)
    }
}

/// TMDB provider 的归一(`docs/DISCOVERY.md` §3.1 / §3.2)。
final class TMDBDiscoverProviderTests: XCTestCase {

    private static func match(
        id: Int = 1399, kind: TMDBMatch.Kind = .tv, title: String? = "权力的游戏",
        year: Int? = 2011, rating: Double? = 8.4, posterPath: String? = "/p.jpg"
    ) -> TMDBMatch {
        TMDBMatch(
            result: TMDBResult(
                tmdbID: id, title: kind == .movie ? title : nil,
                releaseDate: kind == .movie ? "2011-01-01" : nil,
                name: kind == .tv ? title : nil,
                firstAirDate: kind == .tv ? "2011-04-17" : nil,
                posterPath: posterPath, voteAverage: rating),
            kind: kind)
    }

    func testTitleFromMatch() throws {
        let title = try XCTUnwrap(TMDBDiscoverProvider.title(from: Self.match()))
        XCTAssertEqual(title.id, "tmdb:tv:1399")
        XCTAssertEqual(title.title, "权力的游戏")
        XCTAssertEqual(title.year, 2011)
        XCTAssertEqual(title.rating, 8.4)
        XCTAssertEqual(title.subtitle, "2011 · 8.4 分")
        // TMDB 图床没有防盗链,⛔ 不带 Referer
        XCTAssertEqual(title.poster?.headers, [:])
    }

    func testMovieAndTVIdsDoNotCollide() throws {
        let movie = try XCTUnwrap(
            TMDBDiscoverProvider.title(from: Self.match(id: 550, kind: .movie, title: "搏击俱乐部")))
        let tv = try XCTUnwrap(
            TMDBDiscoverProvider.title(from: Self.match(id: 550, kind: .tv, title: "某剧")))
        XCTAssertNotEqual(movie.id, tv.id, "影 / 剧是两个 id 空间,缓存 key 不能撞")
    }

    func testDropsMatchWithoutTitle() {
        XCTAssertNil(TMDBDiscoverProvider.title(from: Self.match(title: nil)))
    }

    /// TMDB 的 `page` 是 1 起,榜单层用 0 起:第一页要发 `page=1`。
    func testTMDBPageIsOneBased() async throws {
        let storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        let store = CredentialStore(storage: storage)
        try await store.saveTMDBReadAccessToken("fake-token")
        defer { Task { try? await storage.removeAll() } }

        MockEmbyURLProtocol.stub(
            .json(#"{"page": 1, "total_pages": 5, "total_results": 100, "results": []}"#),
            host: "api.themoviedb.org",
            path: "/3/discover/movie")
        let provider = TMDBDiscoverProvider(
            client: TMDBClient(session: MockEmbyURLProtocol.makeSession()),
            credentials: store)
        _ = try await provider.load(
            DiscoverBoard(source: .tmdb, reference: "movieHot", title: "热门电影"), page: 0)

        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/discover/movie"))
        XCTAssertTrue(
            try XCTUnwrap(request.url.query).contains("page=1"),
            "第 0 页要发 page=1")
    }

    func testBuiltInBoardsAreTMDB() {
        let boards = TMDBDiscoverProvider.builtInBoards
        XCTAssertTrue(boards.allSatisfy { $0.source == .tmdb })
        XCTAssertEqual(Set(boards.map(\.id)).count, boards.count)
    }

    /// 没配 token 时是「不可用」而不是空榜单,且 UI 该给「去填 token」。
    func testAvailabilityWithoutToken() async throws {
        let store = CredentialStore(storage: CredentialFileStore(fileURL: .temporaryCredentialsFile()))
        let provider = TMDBDiscoverProvider(
            client: TMDBClient(session: MockEmbyURLProtocol.makeSession()),
            credentials: store)
        let available = await provider.availability()
        let reason = try XCTUnwrap(available)
        XCTAssertEqual(reason.source, .tmdb)
        XCTAssertTrue(reason.needsToken)
        XCTAssertTrue(reason.message.contains("Token"))
    }

    /// 没有 token 就去拉榜单是配置错误,⛔ 不静默返回空。
    func testLoadWithoutTokenThrows() async throws {
        let store = CredentialStore(storage: CredentialFileStore(fileURL: .temporaryCredentialsFile()))
        let provider = TMDBDiscoverProvider(
            client: TMDBClient(session: MockEmbyURLProtocol.makeSession()),
            credentials: store)
        do {
            _ = try await provider.load(
                DiscoverBoard(source: .tmdb, reference: "trending", title: "本周热门"), page: 0)
            XCTFail("没有 token 应当抛错")
        } catch let error as DiscoverError {
            XCTAssertEqual(error, .unsupportedBoard("tmdb.trending"))
        }
    }
}
