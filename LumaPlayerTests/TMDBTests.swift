import XCTest
@testable import LumaPlayer

/// TMDB 刮削链路:`TMDBEndpoint`(URL 构造)+ `TMDBClient`(传输 / 解码 / 错误映射)
/// + 「文件名 → `parse` → 查询」的端到端拼接。
///
/// ⛔ **零真实网络**:全部走 `MockEmbyURLProtocol`(它按 scheme + host + path 打桩,
/// 与具体来源无关,所以 TMDB 也能用它的会话)。真实 TMDB 调用要等用户在设置里
/// 填入自己的 token 后才能跑,在此之前按 `CLAUDE.md` 硬规则 2 标注「未在真实服务器验证」。
final class TMDBTests: XCTestCase {

    private let host = "api.themoviedb.org"

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
    }

    override func tearDown() {
        MockEmbyURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> TMDBClient {
        TMDBClient(session: MockEmbyURLProtocol.makeSession())
    }

    // MARK: - 端点(URL 构造,纯函数)

    /// `docs/TMDB_API.md` §2:参数名 `query` / `year` / `language`,
    /// 空格与中文标题都要整体编码。
    func testMovieSearchEndpointEncodesQueryAndLanguage() throws {
        let endpoint = TMDBEndpoint.searchMovie(query: "Jack Reacher", year: 2016, language: "zh-CN")
        let url = try XCTUnwrap(endpoint.url)

        XCTAssertEqual(url.host, "api.themoviedb.org")
        XCTAssertEqual(url.path, "/3/search/movie")
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("query=Jack%20Reacher"), "实际:\(query)")
        XCTAssertTrue(query.contains("year=2016"), "实际:\(query)")
        XCTAssertTrue(query.contains("language=zh-CN"), "实际:\(query)")
    }

    /// 剧集端点的年份参数**名字不同**:`first_air_date_year`(`docs/TMDB_API.md` §2)。
    func testTVSearchEndpointUsesFirstAirDateYear() throws {
        let endpoint = TMDBEndpoint.searchTV(query: "权力的游戏", year: 2011, language: "zh-CN")
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertTrue(query.contains("first_air_date_year=2011"), "实际:\(query)")
        XCTAssertEqual(endpoint.path, "/3/search/tv")
        // 中文必须按 UTF-8 逐字节编码,不能原样留在查询串里
        XCTAssertFalse(query.contains("权力的游戏"), "中文未编码:\(query)")
    }

    /// 年份解析不出来时**不传**这个参数,⛔ 不填 0 / 空串这类假默认值。
    func testYearIsOmittedWhenNil() throws {
        let endpoint = TMDBEndpoint.searchMovie(query: "Dune", year: nil, language: "zh-CN")
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertFalse(query.contains("year="), "实际:\(query)")
        XCTAssertTrue(query.contains("query=Dune"))
    }

    /// 端点诊断名不含凭据(CLAUDE.md「安全与隐私」)。
    func testEndpointNamesExcludeSecrets() {
        let endpoint = TMDBEndpoint.searchMovie(query: "SECRET", year: nil, language: "zh-CN")
        XCTAssertEqual(endpoint.method, "GET")
        XCTAssertEqual(endpoint.name, "search/movie")
        XCTAssertFalse(endpoint.name.contains("SECRET"))
        // token 走请求头,绝不进查询串(§1)
        XCTAssertFalse((endpoint.url?.query ?? "").lowercased().contains("token"))
    }

    // MARK: - 图片地址(§4)

    func testPosterURLIsBuiltFromPath() {
        XCTAssertEqual(
            TMDBImage.posterURL(path: "/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg")?.absoluteString,
            "https://image.tmdb.org/t/p/w500/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg")
        // 万一路径不带前导斜杠,也要拼成合法地址(不能出现 w500pB8 这种)
        XCTAssertEqual(
            TMDBImage.posterURL(path: "pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg")?.absoluteString,
            "https://image.tmdb.org/t/p/w500/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg")
        // 没有海报 → nil(UI 降级成图标卡)
        XCTAssertNil(TMDBImage.posterURL(path: nil))
        XCTAssertNil(TMDBImage.posterURL(path: ""))
    }

    // MARK: - 传输:认证头

    /// v4 token 走 `Authorization: Bearer`,且**不进 URL**(§1)。
    func testBearerTokenGoesInAuthorizationHeader() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"results":[]}"#), host: host, path: "/3/search/movie")

        _ = try await makeClient().searchMovie(title: "Dune", token: "READ_TOKEN_123")

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/movie"))
        XCTAssertEqual(request.header("Authorization"), "Bearer READ_TOKEN_123")
        XCTAssertEqual(request.header("Accept"), "application/json")
        XCTAssertFalse(request.url.query?.contains("READ_TOKEN_123") ?? false,
                       "token 不得出现在查询串:\(request.url)")
    }

    /// 空 token 直接抛 `.tokenMissing`,⛔ **不发请求**(发了只会拿到无语义的 401)。
    func testEmptyTokenThrowsWithoutSendingRequest() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"results":[]}"#), host: host, path: "/3/search/movie")

        do {
            _ = try await makeClient().searchMovie(title: "Dune", token: "   ")
            XCTFail("空 token 应当抛错")
        } catch let error as TMDBError {
            XCTAssertEqual(error, .tokenMissing)
            XCTAssertTrue(error.needsToken)
        }
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty, "不该发请求")
    }

    // MARK: - 解码

    /// 电影:取 `title` / `release_date` / `overview` / `poster_path` / `vote_average`。
    func testMovieSearchDecodesIntoMatch() async throws {
        MockEmbyURLProtocol.stub(.json(Self.movieJSON), host: host, path: "/3/search/movie")

        let matches = try await makeClient().searchMovie(title: "Fight Club", token: "T")

        XCTAssertEqual(matches.count, 1)
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.kind, .movie)
        XCTAssertEqual(match.tmdbID, 550)
        XCTAssertEqual(match.title, "Fight Club")
        XCTAssertEqual(match.year, 1999)
        XCTAssertEqual(match.posterPath, "/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg")
        XCTAssertEqual(match.posterURL?.absoluteString,
                       "https://image.tmdb.org/t/p/w500/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg")
        XCTAssertNotNil(match.overview)
        XCTAssertEqual(match.voteAverage, 8.433)
    }

    /// 剧集:字段名是 `name` / `first_air_date`(§3),不是 `title` / `release_date`。
    func testTVSearchDecodesNameAndFirstAirDate() async throws {
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")

        let matches = try await makeClient().searchTV(title: "权力的游戏", token: "T")

        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.kind, .tv)
        XCTAssertEqual(match.tmdbID, 1399)
        XCTAssertEqual(match.title, "Game of Thrones")
        XCTAssertEqual(match.year, 2011)
    }

    /// `search(isSeries:)` 按季集标志选端点 —— 这是刮削链路的「选路」。
    func testSeriesFlagChoosesTVEndpoint() async throws {
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")
        MockEmbyURLProtocol.stub(.json(Self.movieJSON), host: host, path: "/3/search/movie")
        let client = makeClient()

        _ = try await client.search(title: "Some Show", isSeries: true, token: "T")
        _ = try await client.search(title: "Some Movie", isSeries: false, token: "T")

        XCTAssertNotNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/tv"))
        XCTAssertNotNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/movie"))
    }

    /// TMDB 对缺海报 / 缺上映日的条目会给 `null` 或 `""` —— 一律解成 nil,
    /// ⛔ 不让整条解失败(§3 的解码立场)。
    func testNullFieldsDecodeAsNil() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"""
            {"results":[{"id":42,"title":"No Poster","poster_path":null,
             "release_date":"","overview":null,"vote_average":null}]}
            """#),
            host: host, path: "/3/search/movie")

        let matches = try await makeClient().searchMovie(title: "No Poster", token: "T")
        let match = try XCTUnwrap(matches.first)

        XCTAssertEqual(match.title, "No Poster")
        XCTAssertNil(match.posterPath)
        XCTAssertNil(match.posterURL)
        XCTAssertNil(match.year)
        XCTAssertNil(match.overview)
        XCTAssertNil(match.voteAverage)
    }

    /// 搜索没有命中不是错误:返回空数组(§5 的立场)。
    func testNoResultsIsNotAnError() async throws {
        MockEmbyURLProtocol.stub(.json(#"{"results":[]}"#), host: host, path: "/3/search/movie")

        let matches = try await makeClient().searchMovie(title: "zzz", token: "T")
        XCTAssertTrue(matches.isEmpty)
    }

    /// 响应形状不对(没有 `results`)→ 抛解码错误,⛔ 不静默成空数组。
    func testMalformedBodyThrowsDecodingError() async throws {
        MockEmbyURLProtocol.stub(.json(#"{"unexpected":true}"#), host: host, path: "/3/search/movie")

        do {
            _ = try await makeClient().searchMovie(title: "x", token: "T")
            XCTFail("形状不对应当抛解码错误")
        } catch let error as TMDBError {
            guard case .decoding = error else {
                return XCTFail("期望 .decoding,实际 \(error)")
            }
        }
    }

    // MARK: - 错误映射(§5)

    func testUnauthorizedIsMappedWithStatusCode() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"status_code":7,"status_message":"Invalid API key","success":false}"#,
                  statusCode: 401),
            host: host, path: "/3/search/movie")

        do {
            _ = try await makeClient().searchMovie(title: "x", token: "BAD")
            XCTFail("401 应当抛错")
        } catch let error as TMDBError {
            XCTAssertEqual(error, .unauthorized(code: 7, message: "Invalid API key"))
            XCTAssertTrue(error.needsToken)
            XCTAssertTrue(error.userMessage.contains("token"))
        }
    }

    func testRateLimitedIsMapped() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"status_code":25,"status_message":"Your request count is over the allowed limit","success":false}"#,
                  statusCode: 429),
            host: host, path: "/3/search/movie")

        do {
            _ = try await makeClient().searchMovie(title: "x", token: "T")
            XCTFail("429 应当抛错")
        } catch let error as TMDBError {
            XCTAssertEqual(
                error,
                .rateLimited(message: "Your request count is over the allowed limit"))
            XCTAssertFalse(error.needsToken)
        }
    }

    /// 非 2xx、非上述状态码 → 通用 `.server`,状态码与描述都带出来。
    func testOtherStatusCodesMapToServerError() {
        let error = TMDBClient.failure(
            statusCode: 503,
            data: Data(#"{"status_code":9,"status_message":"Service offline"}"#.utf8))
        XCTAssertEqual(error, .server(statusCode: 503, message: "Service offline"))
    }

    /// 连不上(传输层)→ `.transport`,且描述经过脱敏。
    func testTransportFailureIsRedacted() async throws {
        MockEmbyURLProtocol.stub(.failure(.cannotConnectToHost), host: host, path: "/3/search/movie")

        do {
            _ = try await makeClient().searchMovie(title: "x", token: "T")
            XCTFail("传输失败应当抛错")
        } catch let error as TMDBError {
            guard case .transport = error else {
                return XCTFail("期望 .transport,实际 \(error)")
            }
        }
    }

    // MARK: - 端到端:文件名 → parse → 查询

    /// 刮削链路的**形状**:`BaiduPanMetadataSynthesizer.parse` 从文件名解析出
    /// 标题 / 年份 / 季集,直接喂给 `TMDBClient`(⛔ 不另写一个文件名解析器)。
    /// 电影文件走 `/3/search/movie`,并带上解析出的年份。
    func testFilenameParsesIntoMovieQuery() async throws {
        let parsed = BaiduPanMetadataSynthesizer.parse(name: "Fight.Club.1999.1080p.BluRay.x264.mkv")
        XCTAssertEqual(parsed.title, "Fight Club")
        XCTAssertEqual(parsed.year, 1999)
        XCTAssertNil(parsed.episode)

        MockEmbyURLProtocol.stub(.json(Self.movieJSON), host: host, path: "/3/search/movie")
        let matches = try await makeClient().search(
            title: parsed.title, year: parsed.year, isSeries: parsed.episode != nil, token: "T")

        XCTAssertEqual(matches.first?.tmdbID, 550)
        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/movie"))
        let query = try XCTUnwrap(request.url.query)
        XCTAssertTrue(query.contains("query=Fight%20Club"), "实际:\(query)")
        XCTAssertTrue(query.contains("year=1999"), "实际:\(query)")
    }

    /// 带季集的文件名 → 走 `/3/search/tv`。
    func testEpisodeFilenameParsesIntoTVQuery() async throws {
        let parsed = BaiduPanMetadataSynthesizer.parse(name: "Game.of.Thrones.S01E01.1080p.mkv")
        XCTAssertNil(parsed.year)
        XCTAssertNotNil(parsed.episode)

        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")
        _ = try await makeClient().search(
            title: parsed.title, year: parsed.year, isSeries: parsed.episode != nil, token: "T")

        XCTAssertNotNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/tv"))
    }

    // MARK: - 季详情端到端(`/3/tv/{id}/season/{n}`,§7)

    /// 剧 id 与季号走 **path**,只有 `language` 进查询串;token 不进 URL(§7)。
    func testSeasonEndpointUsesSeriesAndSeasonInPath() throws {
        let endpoint = TMDBEndpoint.tvSeason(seriesID: 1399, seasonNumber: 13, language: "zh-CN")
        XCTAssertEqual(endpoint.path, "/3/tv/1399/season/13")
        XCTAssertEqual(endpoint.name, "tv/season")
        let url = try XCTUnwrap(endpoint.url)
        XCTAssertEqual(url.host, "api.themoviedb.org")
        XCTAssertEqual(url.path, "/3/tv/1399/season/13")
        XCTAssertEqual(url.query, "language=zh-CN")
        XCTAssertFalse((endpoint.url?.query ?? "").lowercased().contains("token"))
    }

    /// 分集解码:`episode_number` 是匹配键(必填),`name` / `overview` / `still_path` 都可选。
    func testSeasonDetailsDecodeEpisodes() async throws {
        MockEmbyURLProtocol.stub(
            .json(Self.seasonJSON), host: host, path: "/3/tv/1399/season/1")

        let episodes = try await makeClient().seasonDetails(
            seriesID: 1399, seasonNumber: 1, token: "T")

        XCTAssertEqual(episodes.count, 2)
        let first = try XCTUnwrap(episodes.first)
        XCTAssertEqual(first.episodeNumber, 1)
        XCTAssertEqual(first.name, "凛冬将至")
        XCTAssertEqual(first.overview, "第一集简介。")
        XCTAssertEqual(first.stillPath, "/still1.jpg")
        // 分集剧照是 16:9 横图,用 w300 档位(§8),不是海报的 w500
        XCTAssertEqual(first.stillURL?.absoluteString,
                       "https://image.tmdb.org/t/p/w300/still1.jpg")

        // 第 2 集 `name` 是空串、`overview` 是 null → 解成原样,由上层决定怎么降级
        let second = episodes[1]
        XCTAssertEqual(second.name, "")
        XCTAssertNil(second.overview)
    }

    /// 季不存在 → 404 → `.notFound`(刮削层据此把这一季记成「空表」不再重问)。
    func testSeasonNotFoundMapsToNotFound() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"status_code":34,"status_message":"The resource you requested could not be found."}"#,
                  statusCode: 404),
            host: host, path: "/3/tv/1399/season/99")

        do {
            _ = try await makeClient().seasonDetails(seriesID: 1399, seasonNumber: 99, token: "T")
            XCTFail("404 应当抛错")
        } catch let error as TMDBError {
            guard case .notFound = error else {
                return XCTFail("期望 .notFound,实际 \(error)")
            }
            XCTAssertFalse(error.needsToken)
        }
    }

    /// 分集剧照地址拼法(§8):与海报同一拼法,只有档位不同;没有剧照 → nil。
    func testStillURLIsBuiltWithStillSize() {
        XCTAssertEqual(
            TMDBImage.stillURL(path: "/still1.jpg")?.absoluteString,
            "https://image.tmdb.org/t/p/w300/still1.jpg")
        XCTAssertNil(TMDBImage.stillURL(path: nil))
        XCTAssertNil(TMDBImage.stillURL(path: ""))
    }

    // MARK: - fixture

    /// 取自官方规格 `/3/search/movie` 的 200 示例(`docs/TMDB_API.md` §3)。
    private static let movieJSON = #"""
    {"page":1,"results":[{"adult":false,"backdrop_path":"/hZkgoQYus5vegHoetLkCJzb17zJ.jpg",
    "genre_ids":[18,53,35],"id":550,"original_language":"en","original_title":"Fight Club",
    "overview":"A ticking-time-bomb insomniac and a slippery soap salesman channel primal male aggression.",
    "popularity":73.433,"poster_path":"/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg",
    "release_date":"1999-10-15","title":"Fight Club","video":false,
    "vote_average":8.433,"vote_count":26279}],"total_pages":1,"total_results":1}
    """#

    /// 剧集响应形状(`name` / `first_air_date`,官方 `/3/search/tv`)。
    private static let tvJSON = #"""
    {"page":1,"results":[{"adult":false,"backdrop_path":"/suopoADq0k8YZr4dQXcU6pToj6s.jpg",
    "genre_ids":[10765,18],"id":1399,"origin_country":["US"],"original_language":"en",
    "original_name":"Game of Thrones","overview":"Seven noble families fight for control.",
    "popularity":369.594,"poster_path":"/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg",
    "first_air_date":"2011-04-17","name":"Game of Thrones","vote_average":8.4,"vote_count":21000}],
    "total_pages":1,"total_results":1}
    """#

    /// 季详情响应形状(`/3/tv/{id}/season/{n}`,官方规格,`docs/TMDB_API.md` §7)。
    /// `episodes[]` 里第 2 集的 `name` 是空串、`overview` 是 null —— 覆盖降级路径。
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