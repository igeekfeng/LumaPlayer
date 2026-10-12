import XCTest
@testable import LumaPlayer

/// 在线刮削层:`BaiduPanMetadataScraper`(挑命中项 / 补封面 / 失败处置 / 缓存)。
///
/// ⛔ **零真实网络**:全部走 `MockEmbyURLProtocol`(按 scheme + host + path 打桩)。
/// ⚠️ 真实 TMDB 调用(链接、图床可达性、429 阈值)仍需用户自己的 token 在真机上验,
/// 见 `docs/KNOWN_ISSUES.md`「TMDB 在线刮削」一节。
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

    /// 年份解析出来了就**只认年份一致**的那条 —— 同名翻拍片靠它区分,
    /// 让步一步就会配错片(宁可没有封面)。
    func testYearMustMatchExactly() {
        let matches = [
            Self.match(id: 1, title: "Dune", year: 1984),
            Self.match(id: 2, title: "Dune", year: 2021),
        ]
        XCTAssertEqual(Self.select(matches, title: "Dune", year: 2021)?.tmdbID, 2)
        // 没有同年份的 → 不认(⛔ 不退而求其次挑 1984 那部)
        XCTAssertNil(Self.select(matches, title: "Dune", year: 2024))
    }

    /// 没有年份:先认「归一化后标题完全一致」的(大小写 / 空格 / 标点不算差别)。
    func testExactTitleWinsWhenYearUnknown() {
        let matches = [
            Self.match(id: 1, title: "Fight Club 斗阵俱乐部", year: 1999),
            Self.match(id: 2, title: "FightClub", year: nil),
        ]
        XCTAssertEqual(
            Self.select(matches, title: "fight club", year: nil)?.tmdbID, 2)
    }

    /// 没有年份、标题也对不上:只有**唯一一个结果**时才认,多条就放弃。
    func testSingleResultIsAcceptedOnlyWhenAlone() {
        let single = [Self.match(id: 7, title: "某部片", year: nil)]
        XCTAssertEqual(Self.select(single, title: "Another Name", year: nil)?.tmdbID, 7)
        let many = [Self.match(id: 7, title: "A", year: nil), Self.match(id: 8, title: "B", year: nil)]
        XCTAssertNil(Self.select(many, title: "Another Name", year: nil))
    }

    // MARK: - 谁会被刮

    /// 文件名解析出来 (`.filename`) 的电影 / 剧才问 TMDB;
    /// 目录、图片、音频,以及**退回文件名**的那种(标题是 `video`)一律不问。
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

    /// 目录卡片走**另一条**判据:它的标题就是目录名,反而是「目录名是剧名」
    /// 这种存法里最可靠的剧名来源(`isScrapableFolder`)。
    func testFolderCardsAreScrapedByDirectoryName() {
        XCTAssertTrue(BaiduPanMetadataScraper.isScrapableFolder(
            item(title: "琅琊榜", year: nil, kind: .folder, origin: .none)))
        XCTAssertFalse(BaiduPanMetadataScraper.isScrapableFolder(
            item(title: "", year: nil, kind: .folder, origin: .none)))
        XCTAssertFalse(BaiduPanMetadataScraper.isScrapableFolder(
            item(title: "Fight Club", year: 1999, kind: .movie, origin: .filename)))
    }

    // MARK: - 端到端:补封面

    /// 电影 → `/3/search/movie`,封面折成 `.remote` + `poster_path` 当版本段的 cacheKey。
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
        // 查询串带上解析出的年份(§2)
        let query = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/movie")?.url.query)
        XCTAssertTrue(query.contains("year=1999"), "实际:\(query)")
    }

    /// 带季集的条目 → `/3/search/tv`(不另写一个文件名解析器),
    /// 再钻一次季详情拿分集。
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

    /// ★ 分集拿到的是**自己的剧照 / 集名 / 单集简介**,不是剧级海报。
    /// 同一组只发**一次**搜索 + **一次**季详情 —— 不按条目数放大请求。
    func testEpisodesGetTheirOwnStillsAndTitles() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")
        MockEmbyURLProtocol.stub(.json(Self.seasonJSON), host: host, path: "/3/tv/1399/season/1")

        let items = [
            item(title: "Game of Thrones", year: nil, kind: .episode, origin: .filename,
                 episodeNumber: 1),
            item(title: "Game of Thrones", year: nil, kind: .episode, origin: .filename,
                 episodeNumber: 2),
        ]
        let enriched = await Self.makeScraper(credentials).enrich(items)

        let first = try XCTUnwrap(enriched.first)
        XCTAssertEqual(first.episodeTitle, "凛冬将至")
        XCTAssertEqual(first.overview, "第一集简介。")
        XCTAssertEqual(first.poster?.cacheKey, ImageDescriptor.tmdbPosterKey(
            sourceID: sourceID, posterPath: "/still1.jpg", size: TMDBImage.stillSize))

        // 第二集的 `name` 是空串、`overview` 是 null → 不用空串冒充集名;
        // 简介退到剧级(剧的简介对这一集也成立)
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

    /// 季详情里**没有这一集**(这一季只有 2 集,文件是第 3 集)→ 不给封面,
    /// ⛔ 也不拿剧级海报充数;剧级简介 / 年份照补。
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

    /// 季号解析出来了就用它(有 13 季的剧判错季就会配错剧照)。
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

    /// 目录卡片按**剧**查,拿到剧级海报 / 简介 / 首播年 —— 不再是一片空封面。
    /// ⚠️ 目录不钻季详情(目录卡片要的是剧,不是某一集)。
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

    /// ⛔ 目录卡片比单条文件更严:搜索只回一条、但标题对不上时**不认**
    /// (单条文件才允许「唯一结果就认」)。否则一个叫《Movies》的目录会套上别的剧的海报。
    func testFolderCardIgnoresNonExactTitleMatch() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(
            .json(#"{"results":[{"id":7,"name":"Something Else","poster_path":"/x.jpg"}]}"#),
            host: host, path: "/3/search/tv")

        let items = [item(title: "Movies", year: nil, kind: .folder, origin: .none)]
        let enriched = await Self.makeScraper(credentials).enrich(items)

        XCTAssertNil(enriched.first?.poster)
    }

    /// 用户自己放在网盘目录里的图优先 —— ⛔ 不被 TMDB 的海报盖掉。
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

    /// 年份对不上 → 什么都不补(⛔ 不端一张别的片子的封面来充数)。
    func testYearMismatchLeavesItemUntouched() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.movieJSON), host: host, path: "/3/search/movie")

        let items = [item(title: "Fight Club", year: 2024, kind: .movie, origin: .filename)]
        let enriched = await Self.makeScraper(credentials).enrich(items)

        XCTAssertNil(enriched.first?.poster)
        XCTAssertEqual(enriched.first?.year, 2024, "本地解析出的年份不动")
    }

    // MARK: - 失败处置

    /// 没填 token = 用户没开刮削:一个请求都不发,也不报失败。
    func testMissingTokenSendsNoRequest() async throws {
        let scraper = Self.makeScraper(credentials)
        let items = [item(title: "Fight Club", year: 1999, kind: .movie, origin: .filename)]
        let enriched = await scraper.enrich(items)

        XCTAssertEqual(enriched, items)
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty, "不该发请求")
        let failure = await scraper.lastFailureDescription
        XCTAssertNil(failure, "没配置不是失败")
    }

    /// token 被拒(401)→ 条目原样返回 + 如实留下失败原因(⛔ 不静默吞错)。
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

    /// 连不上 → 也只是一句提示,不抛错(刮削是附加信息,⛔ 不该让浏览变错)。
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

    /// 同一个「标题 + 年份 + 是不是剧」只问一次(含「查过但没命中」)。
    func testRepeatedDirectoryDoesNotRequery() async throws {
        await save(token: "READ_TOKEN")
        MockEmbyURLProtocol.stub(.json(Self.movieJSON), host: host, path: "/3/search/movie")
        MockEmbyURLProtocol.stub(.json(#"{"results":[]}"#), host: host, path: "/3/search/tv")

        let scraper = Self.makeScraper(credentials)
        let items = [
            item(title: "Fight Club", year: 1999, kind: .movie, origin: .filename),
            // 没命中的那条也要记住「查过了」,否则每次进目录都白烧一轮请求
            item(title: "Some Show", year: nil, kind: .episode, origin: .filename),
        ]
        _ = await scraper.enrich(items)
        let afterFirst = MockEmbyURLProtocol.recordedRequests().count
        XCTAssertEqual(afterFirst, 2)

        _ = await scraper.enrich(items)
        XCTAssertEqual(MockEmbyURLProtocol.recordedRequests().count, afterFirst, "第二次不该再发请求")
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
            voteAverage: nil
        ), kind: .movie)
    }

    /// 一条可播的媒体文件条目(投影,不含播放所需信息)。
    private func item(
        title: String,
        year: Int?,
        kind: SourceItemKind,
        origin: MetadataOrigin,
        episodeNumber: Int? = nil,
        seasonNumber: Int? = nil
    ) -> SourceItem {
        SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: 42),
            title: title,
            kind: kind,
            overview: nil,
            year: year,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            episodeTitle: nil,
            durationSeconds: nil,
            poster: nil,
            metadataOrigin: origin
        )
    }

    /// 官方规格 `/3/search/movie` 200 示例(`docs/TMDB_API.md` §3)
    private static let movieJSON = #"""
    {"page":1,"results":[{"adult":false,"id":550,"original_language":"en",
    "original_title":"Fight Club","overview":"一部电影。",
    "popularity":73.433,"poster_path":"/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg",
    "release_date":"1999-10-15","title":"Fight Club","video":false,
    "vote_average":8.433,"vote_count":26279}],"total_pages":1,"total_results":1}
    """#

    /// `/3/search/tv` 200 示例(字段名 `name` / `first_air_date`)
    private static let tvJSON = #"""
    {"page":1,"results":[{"adult":false,"id":1399,"origin_country":["US"],
    "original_language":"en","original_name":"Game of Thrones","overview":"一部剧。",
    "popularity":369.594,"poster_path":"/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg",
    "first_air_date":"2011-04-17","name":"Game of Thrones",
    "vote_average":8.4,"vote_count":21000}],"total_pages":1,"total_results":1}
    """#

    /// `/3/tv/1399/season/1` 200 示例(`docs/TMDB_API.md` §7):
    /// 第 1 集有集名 / 单集简介 / 剧照;第 2 集的 `name` 是空串、`overview` 是 null
    /// —— 用来验证「空串不当集名」的降级。
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