import XCTest
@testable import LumaPlayer

/// ⛔ 零真实网络:全部走 `MockEmbyURLProtocol`。真实 TMDB 行为待真机验证,见 `docs/KNOWN_ISSUES.md`「TMDB 在线刮削」。
final class BaiduPanMetadataScraperTests: XCTestCase {

    private let host = "api.themoviedb.org"
    private let sourceID = UUID(uuidString: "1E1F1A2B-0000-4000-8000-00000000ABCD")!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
    }

    override func tearDown() {
        MockEmbyURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - 命中判定(纯函数)

    /// 同名翻拍片靠年份区分,⛔ 不退而求其次(宁可没有封面)。
    func testYearMustMatchExactly() {
        let matches = [
            Self.match(id: 1, title: "Dune", year: 1984),
            Self.match(id: 2, title: "Dune", year: 2021),
        ]
        XCTAssertEqual(Self.select(matches, title: "Dune", year: 2021)?.tmdbID, 2)
        XCTAssertNil(Self.select(matches, title: "Dune", year: 2024))
    }

    /// 大小写 / 空格 / 标点不算差别。
    func testExactTitleWinsWhenYearUnknown() {
        let matches = [
            Self.match(id: 1, title: "Fight Club 斗阵俱乐部", year: 1999),
            Self.match(id: 2, title: "FightClub", year: nil),
        ]
        XCTAssertEqual(
            Self.select(matches, title: "fight club", year: nil)?.tmdbID, 2)
    }

    func testSingleResultIsAcceptedOnlyWhenAlone() {
        let single = [Self.match(id: 7, title: "某部片", year: nil)]
        XCTAssertEqual(Self.select(single, title: "Another Name", year: nil)?.tmdbID, 7)
        let many = [Self.match(id: 7, title: "A", year: nil), Self.match(id: 8, title: "B", year: nil)]
        XCTAssertNil(Self.select(many, title: "Another Name", year: nil))
    }

    // MARK: - 谁会被刮

    /// 退回文件名的(标题是 `video`)也不问。
    func testOnlyParsedVideoItemsAreScraped() {
        XCTAssertTrue(BaiduPanMetadataScraper.isScrapable(
            item(title: "Fight Club", year: 1999, kind: .movie, origin: .filename)))
        XCTAssertTrue(BaiduPanMetadataScraper.isScrapable(
            item(title: "权力的游戏", year: nil, kind: .episode, origin: .filename)))

        XCTAssertFalse(BaiduPanMetadataScraper.isScrapable(
            item(title: "video", year: nil, kind: .video, origin: .none)),
            "退回文件名的标题不能拿去搜,搜回来的是别的片子")
        XCTAssertFalse(BaiduPanMetadataScraper.isScrapable(
            item(title: "music", year: 2001, kind: .audio, origin: .filename)))
        XCTAssertFalse(BaiduPanMetadataScraper.isScrapable(
            item(title: "Movies", year: nil, kind: .folder, origin: .filename)))
    }

    /// 目录名在「目录名是剧名」的存法里是最可靠的剧名来源。
    func testFolderCardsAreScrapedByDirectoryName() {
        XCTAssertTrue(BaiduPanMetadataScraper.isScrapableFolder(
            item(title: "琅琊榜", year: nil, kind: .folder, origin: .none)))
        XCTAssertFalse(BaiduPanMetadataScraper.isScrapableFolder(
            item(title: "", year: nil, kind: .folder, origin: .none)))
        XCTAssertFalse(BaiduPanMetadataScraper.isScrapableFolder(
            item(title: "Fight Club", year: 1999, kind: .movie, origin: .filename)))
    }

    // MARK: - 端到端:补封面

    func testMovieGetsPosterDescriptor() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.movieJSON), host: host, path: "/3/search/movie")

        let items = [item(title: "Fight Club", year: 1999, kind: .movie, origin: .filename)]
        let enriched = await Self.makeScraper(credentials).enrich(items)

        let item = try XCTUnwrap(enriched.first)
        let poster = try XCTUnwrap(item.poster, "命中海报却没补上")
        guard case .remote(let url, let headers) = poster.origin else {
            return XCTFail("期望 .remote,实际 \(poster.origin)")
        }
        XCTAssertEqual(
            url.absoluteString,
            "https://image.tmdb.org/t/p/w500/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg")
        XCTAssertTrue(headers.isEmpty, "TMDB 图床是公开 CDN,不该带认证头")
        XCTAssertEqual(poster.ownerID, sourceID, "缓存分区必须挂在来源上(删来源要能整片清掉)")
        XCTAssertEqual(
            poster.cacheKey,
            ImageDescriptor.tmdbPosterKey(
                sourceID: sourceID,
                posterPath: "/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg",
                size: TMDBImage.posterSize))
        XCTAssertTrue(poster.isDiskCacheable, "cacheKey 含 poster_path,自带版本段,可进磁盘缓存")
        let query = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/movie")?.url.query)
        XCTAssertTrue(query.contains("year=1999"), "实际:\(query)")
    }

    /// 复用文件名解析的季集,不另写解析器。
    func testEpisodeGoesToTVEndpointThenSeasonDetails() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")
        MockEmbyURLProtocol.stub(.json(Self.movieJSON), host: host, path: "/3/search/movie")
        MockEmbyURLProtocol.stub(.json(Self.seasonJSON), host: host, path: "/3/tv/1399/season/1")

        let items = [item(
            title: "Game of Thrones", year: nil, kind: .episode, origin: .filename,
            episodeNumber: 1)]
        _ = await Self.makeScraper(credentials).enrich(items)

        XCTAssertNotNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/tv"))
        XCTAssertNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/movie"),
                     "剧集不该去问电影端点")
        XCTAssertNotNil(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/tv/1399/season/1"),
            "剧集必须再钻一次季详情,否则每集拿到的都是剧级海报")
    }

    /// 分集要自己的剧照 / 集名 / 简介而非剧级海报;同一组只发一次搜索 + 一次季详情。
    func testEpisodesGetTheirOwnStillsAndTitles() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")
        MockEmbyURLProtocol.stub(.json(Self.seasonJSON), host: host, path: "/3/tv/1399/season/1")

        let items = [
            item(title: "Game of Thrones", year: nil, kind: .episode, origin: .filename,
                 episodeNumber: 1),
            item(title: "Game of Thrones", year: nil, kind: .episode, origin: .filename,
                 episodeNumber: 2, fsID: 43),
        ]
        let enriched = await Self.makeScraper(credentials).enrich(items)

        let first = try XCTUnwrap(enriched.first)
        XCTAssertEqual(first.episodeTitle, "凛冬将至")
        XCTAssertEqual(first.overview, "第一集简介。")
        XCTAssertEqual(first.poster?.cacheKey, ImageDescriptor.tmdbPosterKey(
            sourceID: sourceID, posterPath: "/still1.jpg", size: TMDBImage.stillSize))

        // 空串 / null 不冒充集名;简介退到剧级。
        let second = enriched[1]
        XCTAssertNil(second.episodeTitle)
        XCTAssertEqual(second.overview, "一部剧。")
        XCTAssertEqual(second.poster?.cacheKey, ImageDescriptor.tmdbPosterKey(
            sourceID: sourceID, posterPath: "/still2.jpg", size: TMDBImage.stillSize))
        XCTAssertNotEqual(first.poster?.cacheKey, second.poster?.cacheKey,
                          "每集封面必须是分集剧照,不能是同一张剧级海报")

        XCTAssertEqual(MockEmbyURLProtocol.recordedRequests().count, 2,
                       "同一组只该发一次搜索 + 一次季详情")
    }

    /// ⛔ 不拿剧级海报充数;剧级简介 / 年份照补。
    func testEpisodeMissingFromSeasonKeepsNoPoster() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")
        MockEmbyURLProtocol.stub(.json(Self.seasonJSON), host: host, path: "/3/tv/1399/season/1")

        let items = [item(
            title: "Game of Thrones", year: nil, kind: .episode, origin: .filename,
            episodeNumber: 3)]
        let enriched = await Self.makeScraper(credentials).enrich(items)

        XCTAssertNil(enriched.first?.poster)
        XCTAssertEqual(enriched.first?.year, 2011)
        XCTAssertEqual(enriched.first?.overview, "一部剧。")
    }

    /// 有多季的剧判错季就会配错剧照。
    func testEpisodeUsesParsedSeasonNumber() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")
        MockEmbyURLProtocol.stub(.json(Self.seasonJSON), host: host, path: "/3/tv/1399/season/13")

        let items = [item(
            title: "Game of Thrones", year: nil, kind: .episode, origin: .filename,
            episodeNumber: 1, seasonNumber: 13)]
        _ = await Self.makeScraper(credentials).enrich(items)

        XCTAssertNotNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/tv/1399/season/13"))
        XCTAssertNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/tv/1399/season/1"))
    }

    // MARK: - 端到端:目录卡片(剧集)

    /// 目录要的是剧,不钻季详情。
    func testFolderCardGetsSeriesPoster() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")

        let items = [item(title: "Game of Thrones", year: nil, kind: .folder, origin: .none)]
        let enriched = await Self.makeScraper(credentials).enrich(items)

        let folder = try XCTUnwrap(enriched.first)
        XCTAssertEqual(folder.year, 2011)
        XCTAssertEqual(folder.overview, "一部剧。")
        XCTAssertEqual(folder.poster?.cacheKey, ImageDescriptor.tmdbPosterKey(
            sourceID: sourceID,
            posterPath: "/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg",
            size: TMDBImage.posterSize))
        XCTAssertNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/season/1"),
                     "目录卡片不该去拉季详情")
    }

    /// 目录卡片比单条文件严:唯一结果但标题对不上也不认,否则叫《Movies》的目录会套上别的剧的海报。
    func testFolderCardIgnoresNonExactTitleMatch() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(
            .json(#"{"results":[{"id":7,"name":"Something Else","poster_path":"/x.jpg"}]}"#),
            host: host, path: "/3/search/tv")

        let items = [item(title: "Movies", year: nil, kind: .folder, origin: .none)]
        let enriched = await Self.makeScraper(credentials).enrich(items)

        XCTAssertNil(enriched.first?.poster)
    }

    func testLocalCoverIsNotOverwritten() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.movieJSON), host: host, path: "/3/search/movie")

        let localKey = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42, modifiedAt: nil, maxWidth: 400)
        let withLocal = item(
            title: "Fight Club", year: 1999, kind: .movie, origin: .filename
        ).withPoster(.remote(
            ownerID: sourceID,
            url: URL(string: "https://pan.baidu.test/x.jpg")!,
            headers: ["User-Agent": BaiduPanUserAgent.download],
            cacheKey: localKey))

        let enriched = await Self.makeScraper(credentials).enrich([withLocal])
        XCTAssertEqual(enriched.first?.poster?.cacheKey, localKey)
    }

    func testYearMismatchLeavesItemUntouched() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.movieJSON), host: host, path: "/3/search/movie")

        let items = [item(title: "Fight Club", year: 2024, kind: .movie, origin: .filename)]
        let enriched = await Self.makeScraper(credentials).enrich(items)

        XCTAssertNil(enriched.first?.poster)
        XCTAssertEqual(enriched.first?.year, 2024, "本地解析出的年份不动")
    }

    // MARK: - 端到端:显式 TMDB id(`{tmdbid-N}`)

    /// 目录名里的标签归一化后对不上任何标题,所以 ⛔ 不按标题搜。
    func testFolderWithExplicitIDQueriesByID() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.tvDetailsJSON), host: host, path: "/3/tv/63926")

        let items = [item(
            title: "一拳超人 (2015)", year: nil, kind: .folder, origin: .none, tmdbID: 63926)]
        let enriched = await Self.makeScraper(credentials).enrich(items)

        let folder = try XCTUnwrap(enriched.first)
        XCTAssertEqual(folder.overview, "一部剧。")
        XCTAssertEqual(folder.year, 2011)
        XCTAssertEqual(folder.poster?.cacheKey, ImageDescriptor.tmdbPosterKey(
            sourceID: sourceID,
            posterPath: "/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg",
            size: TMDBImage.posterSize))
        XCTAssertNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/tv"),
                     "有显式 id 就不该再按标题搜")
    }

    /// 标签本身不区分影 / 剧,剧端点 404 就退电影。
    func testExplicitIDFallsBackToMovieWhenNotASeries() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(
            .json(#"{"status_code":34,"status_message":"not found","success":false}"#,
                  statusCode: 404),
            host: host, path: "/3/tv/550")
        MockEmbyURLProtocol.stub(.json(Self.movieDetailsJSON), host: host, path: "/3/movie/550")

        let items = [item(
            title: "Fight Club (1999)", year: nil, kind: .folder, origin: .none, tmdbID: 550)]
        let enriched = await Self.makeScraper(credentials).enrich(items)

        XCTAssertEqual(enriched.first?.poster?.cacheKey, ImageDescriptor.tmdbPosterKey(
            sourceID: sourceID,
            posterPath: "/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg",
            size: TMDBImage.posterSize))
    }

    func testEpisodeWithExplicitIDSkipsSearch() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.tvDetailsJSON), host: host, path: "/3/tv/1399")
        MockEmbyURLProtocol.stub(.json(Self.seasonJSON), host: host, path: "/3/tv/1399/season/1")

        let items = [item(
            title: "Game of Thrones", year: nil, kind: .episode, origin: .filename,
            episodeNumber: 1, seasonNumber: 1, tmdbID: 1399)]
        let enriched = await Self.makeScraper(credentials).enrich(items)

        XCTAssertEqual(enriched.first?.episodeTitle, "凛冬将至")
        XCTAssertNotNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/tv/1399/season/1"))
        XCTAssertNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/tv"),
                     "有显式 id 就不该再按标题搜")
    }

    // MARK: - 失败处置

    /// 没填 token = 没开刮削:不发请求,也不算失败。
    func testMissingTokenSendsNoRequest() async throws {
        let scraper = Self.makeScraper(credentials)
        let items = [item(title: "Fight Club", year: 1999, kind: .movie, origin: .filename)]
        let enriched = await scraper.enrich(items)

        XCTAssertEqual(enriched, items)
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty, "不该发请求")
        let failure = await scraper.lastFailureDescription
        XCTAssertNil(failure, "没配置不是失败")
    }

    /// ⛔ 不静默吞错。
    func testUnauthorizedKeepsItemsAndReportsFailure() async throws {
        await save(token: "BAD_TOKEN")
        MockEmbyURLProtocol.stub(
            .json(#"{"status_code":7,"status_message":"Invalid API key","success":false}"#,
                  statusCode: 401),
            host: host, path: "/3/search/movie")

        let scraper = Self.makeScraper(credentials)
        let items = [item(title: "Fight Club", year: 1999, kind: .movie, origin: .filename)]
        let enriched = await scraper.enrich(items)

        XCTAssertEqual(enriched, items)
        let failure = await scraper.lastFailureDescription
        XCTAssertTrue(failure?.contains("token") ?? false, "实际:\(failure ?? "nil")")
    }

    /// 刮削是附加信息,⛔ 不该让浏览出错。
    func testTransportFailureIsNotThrown() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(
            .failure(.cannotConnectToHost), host: host, path: "/3/search/movie")

        let scraper = Self.makeScraper(credentials)
        let items = [item(title: "Fight Club", year: 1999, kind: .movie, origin: .filename)]
        let enriched = await scraper.enrich(items)

        XCTAssertEqual(enriched, items)
        let failure = await scraper.lastFailureDescription
        XCTAssertTrue(failure?.contains("TMDB") ?? false, "实际:\(failure ?? "nil")")
    }

    // MARK: - 缓存

    /// 含「查过但没命中」。
    func testRepeatedDirectoryDoesNotRequery() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.movieJSON), host: host, path: "/3/search/movie")
        MockEmbyURLProtocol.stub(.json(#"{"results":[]}"#), host: host, path: "/3/search/tv")

        let scraper = Self.makeScraper(credentials)
        let items = [
            item(title: "Fight Club", year: 1999, kind: .movie, origin: .filename),
            item(title: "Some Show", year: nil, kind: .episode, origin: .filename),
        ]
        _ = await scraper.enrich(items)
        let afterFirst = MockEmbyURLProtocol.recordedRequests().count
        XCTAssertEqual(afterFirst, 2)

        _ = await scraper.enrich(items)
        XCTAssertEqual(MockEmbyURLProtocol.recordedRequests().count, afterFirst, "第二次不该再发请求")
    }

    // MARK: - 详情页的剧级扩展信息 + 演职员(`seriesProfile`)

    func testSeriesProfileWithoutTokenIsSilent() async {
        let scraper = Self.makeScraper(credentials)

        let profile = await scraper.seriesProfile(
            tmdbID: 1399, title: "权力的游戏", year: 2011)

        XCTAssertNil(profile)
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    /// 给了权威 id 还去搜既慢又可能搜错。
    func testSeriesProfileWithExplicitIDSkipsSearch() async throws {
        await save(token: "T")
        MockEmbyURLProtocol.stub(.json(Self.tvDetailsJSON), host: host, path: "/3/tv/1399")
        MockEmbyURLProtocol.stub(.json(Self.creditsJSON), host: host, path: "/3/tv/1399/credits")
        let scraper = Self.makeScraper(credentials)

        let profile = await scraper.seriesProfile(tmdbID: 1399, title: "不该被用到", year: nil)

        let match = try XCTUnwrap(profile?.match)
        XCTAssertEqual(match.tmdbID, 1399)
        XCTAssertEqual(match.kind, .tv)
        XCTAssertEqual(match.genres, ["剧情", "奇幻"])
        XCTAssertEqual(match.statusText, "已完结")
        XCTAssertEqual(match.productionCompanies, ["HBO"])
        XCTAssertEqual(match.networks, ["HBO"])
        XCTAssertEqual(profile?.cast.map(\.name), ["Emilia Clarke", "Peter Dinklage"])
        XCTAssertEqual(profile?.crewNames(withJob: "Director"), ["David Nutter"])
        XCTAssertEqual(
            MockEmbyURLProtocol.recordedRequests().map(\.url.path).sorted(),
            ["/3/tv/1399", "/3/tv/1399/credits"],
            "有 id 时只该发这两条")
    }

    /// 必须用新的刮削器:上一个用例已缓存 `/3/tv/1399`,复用就看不到「搜完再按 id 取」的完整请求序列。
    func testSeriesProfileFallsBackToTitleSearch() async throws {
        await save(token: "T")
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")
        MockEmbyURLProtocol.stub(.json(Self.tvDetailsJSON), host: host, path: "/3/tv/1399")
        MockEmbyURLProtocol.stub(.json(Self.creditsJSON), host: host, path: "/3/tv/1399/credits")
        let scraper = Self.makeScraper(credentials)

        let profile = await scraper.seriesProfile(tmdbID: nil, title: "权力的游戏", year: 2011)

        XCTAssertEqual(profile?.match.tmdbID, 1399)
        XCTAssertEqual(profile?.cast.count, 2)
        XCTAssertEqual(
            MockEmbyURLProtocol.recordedRequests().map(\.url.path).sorted(),
            ["/3/search/tv", "/3/tv/1399", "/3/tv/1399/credits"])
    }

    func testSeriesProfileIsCached() async throws {
        await save(token: "T")
        MockEmbyURLProtocol.stub(.json(Self.tvDetailsJSON), host: host, path: "/3/tv/1399")
        MockEmbyURLProtocol.stub(.json(Self.creditsJSON), host: host, path: "/3/tv/1399/credits")
        let scraper = Self.makeScraper(credentials)

        _ = await scraper.seriesProfile(tmdbID: 1399, title: "", year: nil)
        let afterFirst = MockEmbyURLProtocol.recordedRequests().count

        let second = await scraper.seriesProfile(tmdbID: 1399, title: "", year: nil)

        XCTAssertNotNil(second, "缓存命中也要交出结果")
        XCTAssertEqual(
            MockEmbyURLProtocol.recordedRequests().count, afterFirst, "第二次不该再发请求")
    }

    /// 「剧集列表」入口封面来自目录卡片(`enrich`),「继续观看」入口来自 `seriesProfile`,两者的 `ImageDescriptor` 必须相等。
    func testSeriesProfilePosterMatchesDirectoryCard() async throws {
        await save(token: "T")
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")
        MockEmbyURLProtocol.stub(.json(Self.tvDetailsJSON), host: host, path: "/3/tv/1399")
        MockEmbyURLProtocol.stub(.json(Self.creditsJSON), host: host, path: "/3/tv/1399/credits")
        let scraper = Self.makeScraper(credentials)

        let cards = await scraper.enrich([
            item(title: "Game of Thrones", year: nil, kind: .folder, origin: .none)
        ])
        let cardPoster = try XCTUnwrap(cards.first?.poster, "目录卡片没拿到剧集海报")

        let loaded = await scraper.seriesProfile(tmdbID: 1399, title: "Game of Thrones", year: nil)
        let profile = try XCTUnwrap(loaded)
        let detailPoster = try XCTUnwrap(
            BaiduPanMetadataScraper.posterDescriptor(for: profile.match, sourceID: sourceID),
            "剧级信息里没有海报")

        XCTAssertEqual(detailPoster, cardPoster, "两条入口必须是同一张剧集海报(同一条缓存)")
        XCTAssertTrue(detailPoster.isDiskCacheable)
    }

    /// 拿空标题去搜只会端回无关的剧。
    func testSeriesProfileWithoutAnyIdentitySendsNothing() async {
        await save(token: "T")
        let scraper = Self.makeScraper(credentials)

        let profile = await scraper.seriesProfile(tmdbID: nil, title: "", year: nil)

        XCTAssertNil(profile)
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    func testSeriesProfileFallsBackToMovieWhenTVNotFound() async throws {
        await save(token: "T")
        MockEmbyURLProtocol.stub(.json(Self.notFoundJSON, statusCode: 404),
                                 host: host, path: "/3/tv/550")
        MockEmbyURLProtocol.stub(.json(Self.movieDetailsJSON), host: host, path: "/3/movie/550")
        MockEmbyURLProtocol.stub(.json(Self.creditsJSON), host: host, path: "/3/movie/550/credits")
        let scraper = Self.makeScraper(credentials)

        let profile = await scraper.seriesProfile(tmdbID: 550, title: "", year: nil)

        XCTAssertEqual(profile?.match.kind, .movie)
        XCTAssertEqual(profile?.match.title, "Fight Club")
        XCTAssertEqual(profile?.match.statusText, "已上映")
        XCTAssertEqual(
            MockEmbyURLProtocol.recordedRequests().map(\.url.path).sorted(),
            ["/3/movie/550", "/3/movie/550/credits", "/3/tv/550"],
            "影 / 剧两个 id 空间各自编号,要分别试")
    }

    func testSeriesProfileGivesUpWhenNeitherEndpointHasTheID() async {
        await save(token: "T")
        MockEmbyURLProtocol.stub(.json(Self.notFoundJSON, statusCode: 404),
                                 host: host, path: "/3/tv/999999")
        MockEmbyURLProtocol.stub(.json(Self.notFoundJSON, statusCode: 404),
                                 host: host, path: "/3/movie/999999")
        let scraper = Self.makeScraper(credentials)

        let profile = await scraper.seriesProfile(tmdbID: 999999, title: "", year: nil)

        XCTAssertNil(profile)
        XCTAssertFalse(
            MockEmbyURLProtocol.recordedRequests().map(\.url.path)
                .contains("/3/tv/999999/credits"),
            "详情拿不到就不该再去问演职员")
    }

    // MARK: - 辅助

    private func save(token: String) async {
        try? await credentials.saveTMDBReadAccessToken(token)
    }

    private static func makeScraper(_ credentials: CredentialStore) -> BaiduPanMetadataScraper {
        BaiduPanMetadataScraper(
            credentials: credentials,
            client: TMDBClient(session: MockEmbyURLProtocol.makeSession()))
    }

    private static func select(_ matches: [TMDBMatch], title: String, year: Int?) -> TMDBMatch? {
        BaiduPanMetadataScraper.selectMatch(matches, title: title, year: year)
    }

    private static func match(id: Int, title: String, year: Int?) -> TMDBMatch {
        TMDBMatch(result: TMDBResult(
            tmdbID: id,
            title: title,
            originalTitle: nil,
            releaseDate: year.map { "\($0)-01-01" },
            name: nil,
            originalName: nil,
            firstAirDate: nil,
            overview: nil,
            posterPath: nil,
            voteAverage: nil,
            // 详情端点独有字段(`docs/TMDB_API.md` §9),搜索结果形状里一律为 nil
            genres: nil,
            tagline: nil,
            status: nil,
            productionCompanies: nil,
            networks: nil
        ), kind: .movie)
    }

    private func item(
        title: String,
        year: Int?,
        kind: SourceItemKind,
        origin: MetadataOrigin,
        episodeNumber: Int? = nil,
        seasonNumber: Int? = nil,
        tmdbID: Int? = nil,
        fsID: UInt64 = 42
    ) -> SourceItem {
        // `enrich` 按 fsID 并回结果,同一批里的条目须各自不同
        SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: fsID),
            title: title,
            kind: kind,
            overview: nil,
            year: year,
            tmdbID: tmdbID,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            episodeTitle: nil,
            durationSeconds: nil,
            poster: nil,
            metadataOrigin: origin
        )
    }

    private static let movieJSON = #"""
    {"page":1,"results":[{"adult":false,"id":550,"original_language":"en",
    "original_title":"Fight Club","overview":"一部电影。",
    "popularity":73.433,"poster_path":"/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg",
    "release_date":"1999-10-15","title":"Fight Club","video":false,
    "vote_average":8.433,"vote_count":26279}],"total_pages":1,"total_results":1}
    """#

    private static let tvJSON = #"""
    {"page":1,"results":[{"adult":false,"id":1399,"origin_country":["US"],
    "original_language":"en","original_name":"Game of Thrones","overview":"一部剧。",
    "popularity":369.594,"poster_path":"/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg",
    "first_air_date":"2011-04-17","name":"Game of Thrones",
    "vote_average":8.4,"vote_count":21000}],"total_pages":1,"total_results":1}
    """#

    /// 顶层就是条目本身,没有 `results` 包装;`genres` 等详情独有字段(`docs/TMDB_API.md` §9)供详情页那一行用。
    private static let tvDetailsJSON = #"""
    {"adult":false,"id":1399,"origin_country":["US"],"original_language":"en",
    "original_name":"Game of Thrones","overview":"一部剧。",
    "poster_path":"/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg","first_air_date":"2011-04-17",
    "name":"Game of Thrones","vote_average":8.4,"vote_count":21000,
    "genres":[{"id":18,"name":"剧情"},{"id":10765,"name":"奇幻"}],
    "tagline":"凛冬将至。","status":"Ended",
    "production_companies":[{"id":3268,"name":"HBO","logo_path":"/x.png","origin_country":"US"}],
    "networks":[{"id":49,"name":"HBO","logo_path":"/y.png","origin_country":"US"}]}
    """#

    private static let movieDetailsJSON = #"""
    {"adult":false,"id":550,"original_language":"en","original_title":"Fight Club",
    "overview":"一部电影。","poster_path":"/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg",
    "release_date":"1999-10-15","title":"Fight Club","video":false,
    "vote_average":8.433,"vote_count":26279,
    "genres":[{"id":18,"name":"剧情"}],"tagline":"标语。","status":"Released",
    "production_companies":[{"id":508,"name":"20th Century Fox","logo_path":"/f.png",
    "origin_country":"US"}]}
    """#

    /// 第 3 位演员 `name` 为空串(覆盖过滤路径);导演 `profile_path` 为 null(覆盖退成图标)。
    private static let creditsJSON = #"""
    {"id":1399,"cast":[{"id":1223786,"name":"Emilia Clarke",
    "profile_path":"/daenerys.jpg","character":"Daenerys Targaryen","order":0},
    {"id":22970,"name":"Peter Dinklage","profile_path":"/tyrion.jpg",
    "character":"Tyrion Lannister","order":1},
    {"id":99999,"name":"","profile_path":null,"character":"","order":2}],
    "crew":[{"id":9813,"name":"David Nutter","profile_path":null,
    "department":"Directing","job":"Director"}]}
    """#

    /// `status_code: 34` = 资源不存在。
    private static let notFoundJSON = #"""
    {"status_code":34,"status_message":"The resource you requested could not be found.",
    "success":false}
    """#

    /// 第 2 集 `name` 空串、`overview` 为 null,验证「空串不当集名」的降级。
    private static let seasonJSON = #"""
    {"_id":"5256c8b219c2956ff6047cd8","air_date":"2011-04-17","id":3624,
    "name":"Season 1","overview":"第一季。","poster_path":"/zwaj4egrhnXOBIit1tyb4Sbt3KP.jpg",
    "season_number":1,"episodes":[{"air_date":"2011-04-17","episode_number":1,
    "id":63056,"name":"凛冬将至","overview":"第一集简介。","production_code":"",
    "season_number":1,"still_path":"/still1.jpg","vote_average":7.8,"vote_count":200},
    {"air_date":"2011-04-24","episode_number":2,"id":63057,"name":"",
    "overview":null,"production_code":"","season_number":1,"still_path":"/still2.jpg",
    "vote_average":7.9,"vote_count":210}]}
    """#
}