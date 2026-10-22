import XCTest
@testable import LumaPlayer

/// TMDB 刮削链路:端点构造、`TMDBClient` 传输 / 解码 / 错误映射,以及「文件名 → `parse` → 查询」的拼接。
/// ⛔ 零真实网络:全部走 `MockEmbyURLProtocol`(按 scheme + host + path 打桩,与来源无关)。
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

    /// 空格与中文标题都要整体编码(`docs/TMDB_API.md` §2)。
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

    /// 剧集的年份参数名不同:`first_air_date_year`(§2)。
    func testTVSearchEndpointUsesFirstAirDateYear() throws {
        let endpoint = TMDBEndpoint.searchTV(query: "权力的游戏", year: 2011, language: "zh-CN")
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertTrue(query.contains("first_air_date_year=2011"), "实际:\(query)")
        XCTAssertEqual(endpoint.path, "/3/search/tv")
        XCTAssertFalse(query.contains("权力的游戏"), "中文未编码:\(query)")
    }

    /// 年份缺失时不传参数,⛔ 不填 0 / 空串。
    func testYearIsOmittedWhenNil() throws {
        let endpoint = TMDBEndpoint.searchMovie(query: "Dune", year: nil, language: "zh-CN")
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertFalse(query.contains("year="), "实际:\(query)")
        XCTAssertTrue(query.contains("query=Dune"))
    }

    func testEndpointNamesExcludeSecrets() {
        let endpoint = TMDBEndpoint.searchMovie(query: "SECRET", year: nil, language: "zh-CN")
        XCTAssertEqual(endpoint.method, "GET")
        XCTAssertEqual(endpoint.name, "search/movie")
        XCTAssertFalse(endpoint.name.contains("SECRET"))
        // token 走请求头,不进查询串(§1)
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
        XCTAssertNil(TMDBImage.posterURL(path: nil))
        XCTAssertNil(TMDBImage.posterURL(path: ""))
    }

    // MARK: - 传输:认证头

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

    /// 空 token 不发请求(发了只会拿到无语义的 401)。
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

    /// 剧集字段名是 `name` / `first_air_date`(§3)。
    func testTVSearchDecodesNameAndFirstAirDate() async throws {
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")

        let matches = try await makeClient().searchTV(title: "权力的游戏", token: "T")

        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.kind, .tv)
        XCTAssertEqual(match.tmdbID, 1399)
        XCTAssertEqual(match.title, "Game of Thrones")
        XCTAssertEqual(match.year, 2011)
    }

    func testSeriesFlagChoosesTVEndpoint() async throws {
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")
        MockEmbyURLProtocol.stub(.json(Self.movieJSON), host: host, path: "/3/search/movie")
        let client = makeClient()

        _ = try await client.search(title: "Some Show", isSeries: true, token: "T")
        _ = try await client.search(title: "Some Movie", isSeries: false, token: "T")

        XCTAssertNotNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/tv"))
        XCTAssertNotNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/3/search/movie"))
    }

    /// TMDB 缺字段时给 `null` 或 `""`,一律解成 nil,⛔ 不让整条解失败。
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

    func testNoResultsIsNotAnError() async throws {
        MockEmbyURLProtocol.stub(.json(#"{"results":[]}"#), host: host, path: "/3/search/movie")

        let matches = try await makeClient().searchMovie(title: "zzz", token: "T")
        XCTAssertTrue(matches.isEmpty)
    }

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

    func testOtherStatusCodesMapToServerError() {
        let error = TMDBClient.failure(
            statusCode: 503,
            data: Data(#"{"status_code":9,"status_message":"Service offline"}"#.utf8))
        XCTAssertEqual(error, .server(statusCode: 503, message: "Service offline"))
    }

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

    /// 文件名解析复用 `BaiduPanMetadataSynthesizer.parse`,⛔ 不另写解析器。
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

    /// `episode_number` 是匹配键(必填),其余字段可选。
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
        XCTAssertEqual(first.stillURL?.absoluteString,
                       "https://image.tmdb.org/t/p/w300/still1.jpg")

        // 第 2 集空 `name` / null `overview` 原样解出,降级由上层决定
        let second = episodes[1]
        XCTAssertEqual(second.name, "")
        XCTAssertNil(second.overview)
    }

    /// 刮削层据 `.notFound` 把这一季记成空表、不再重问。
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

    func testStillURLIsBuiltWithStillSize() {
        XCTAssertEqual(
            TMDBImage.stillURL(path: "/still1.jpg")?.absoluteString,
            "https://image.tmdb.org/t/p/w300/still1.jpg")
        XCTAssertNil(TMDBImage.stillURL(path: nil))
        XCTAssertNil(TMDBImage.stillURL(path: ""))
    }

    // MARK: - 按 id 直取 + 详情端点字段(§9)

    func testDetailsEndpointUsesIDInPath() throws {
        let series = TMDBEndpoint.tvDetails(id: 1399, language: "zh-CN")
        XCTAssertEqual(series.path, "/3/tv/1399")
        XCTAssertEqual(series.name, "tv/details")
        XCTAssertEqual(series.url?.query, "language=zh-CN")

        let movie = TMDBEndpoint.movieDetails(id: 550, language: "zh-CN")
        XCTAssertEqual(movie.path, "/3/movie/550")
        XCTAssertEqual(movie.name, "movie/details")
    }

    /// 这些字段只有详情端点给,是详情页「类型」那一行的唯一来源。
    func testDetailsDecodeExtendedFields() async throws {
        MockEmbyURLProtocol.stub(.json(Self.detailsJSON), host: host, path: "/3/tv/1399")

        let match = try await makeClient().details(id: 1399, isSeries: true, token: "T")

        XCTAssertEqual(match.kind, .tv)
        XCTAssertEqual(match.genres, ["剧情", "奇幻"])
        XCTAssertEqual(match.tagline, "凛冬将至。")
        XCTAssertEqual(match.status, "Ended")
        XCTAssertEqual(match.statusText, "已完结")
        XCTAssertEqual(match.productionCompanies, ["HBO"])
        XCTAssertEqual(match.networks, ["HBO"])
    }

    /// 搜索响应没有详情字段 → 一律为空,⛔ 不拿 `genre_ids` 编名字。
    func testSearchMatchHasNoExtendedFields() async throws {
        MockEmbyURLProtocol.stub(.json(Self.tvJSON), host: host, path: "/3/search/tv")

        let matches = try await makeClient().searchTV(title: "x", token: "T")
        let match = try XCTUnwrap(matches.first)

        XCTAssertTrue(match.genres.isEmpty)
        XCTAssertTrue(match.productionCompanies.isEmpty)
        XCTAssertTrue(match.networks.isEmpty)
        XCTAssertNil(match.tagline)
        XCTAssertNil(match.status)
        XCTAssertNil(match.statusText)
    }

    /// `status` 没有枚举定义:只映射官方示例里的两个值,其余原样显示英文。
    func testStatusTextOnlyMapsKnownValues() {
        XCTAssertEqual(Self.match(status: "Ended").statusText, "已完结")
        XCTAssertEqual(Self.match(status: "Released").statusText, "已上映")
        XCTAssertEqual(Self.match(status: "Returning Series").statusText, "Returning Series")
        XCTAssertNil(Self.match(status: "").statusText)
        XCTAssertNil(Self.match(status: nil).statusText)
    }

    // MARK: - 演职员(§10)

    func testCreditsEndpointPaths() throws {
        XCTAssertEqual(
            TMDBEndpoint.tvCredits(id: 1399, language: "zh-CN").path, "/3/tv/1399/credits")
        XCTAssertEqual(
            TMDBEndpoint.tvCredits(id: 1399, language: "zh-CN").name, "tv/credits")
        XCTAssertEqual(
            TMDBEndpoint.movieCredits(id: 550, language: "zh-CN").path, "/3/movie/550/credits")
        XCTAssertEqual(
            TMDBEndpoint.movieCredits(id: 550, language: "zh-CN").name, "movie/credits")
        // credits 是整部作品的,路径里不该有 season
        XCTAssertFalse(TMDBEndpoint.tvCredits(id: 1399, language: "zh-CN").path.contains("season"))
    }

    func testCreditsDecodeCastAndCrew() async throws {
        MockEmbyURLProtocol.stub(
            .json(Self.creditsJSON), host: host, path: "/3/tv/1399/credits")

        let credits = try await makeClient().credits(id: 1399, isSeries: true, token: "T")

        XCTAssertEqual(credits.cast.count, 2)
        XCTAssertEqual(credits.cast.map(\.name), ["Emilia Clarke", "Peter Dinklage"])
        XCTAssertEqual(credits.cast.map(\.order), [0, 1])
        XCTAssertEqual(credits.cast.first?.role, "Daenerys Targaryen")
        XCTAssertEqual(credits.cast.first?.department, nil, "演员没有 department")

        XCTAssertEqual(credits.crew.map(\.name), ["David Nutter"])
        XCTAssertEqual(credits.crew.first?.role, "Director", "剧组的 role 取自 job")
        XCTAssertEqual(credits.crew.first?.department, "Directing")
    }

    /// 响应里的顺序不保证,只按 `order` 排,⛔ 不自己判断主次。
    func testCastIsSortedByOrder() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"""
            {"id":1,"cast":[
             {"id":3,"name":"C","character":"c","order":2},
             {"id":1,"name":"A","character":"a","order":0},
             {"id":2,"name":"B","character":"b","order":1}],"crew":[]}
            """#),
            host: host, path: "/3/movie/1/credits")

        let credits = try await makeClient().credits(id: 1, isSeries: false, token: "T")
        XCTAssertEqual(credits.cast.map(\.name), ["A", "B", "C"])
    }

    func testCreditsMissingArraysDecodeAsEmpty() async throws {
        MockEmbyURLProtocol.stub(.json(#"{"id":1}"#), host: host, path: "/3/movie/1/credits")

        let credits = try await makeClient().credits(id: 1, isSeries: false, token: "T")
        XCTAssertTrue(credits.cast.isEmpty)
        XCTAssertTrue(credits.crew.isEmpty)
    }

    func testPersonWithoutProfilePathHasNoAvatar() async throws {
        MockEmbyURLProtocol.stub(.json(Self.creditsJSON), host: host, path: "/3/tv/1399/credits")

        let credits = try await makeClient().credits(id: 1399, isSeries: true, token: "T")
        let daenerys = try XCTUnwrap(credits.cast.first)
        XCTAssertTrue(daenerys.hasProfile)
        XCTAssertEqual(daenerys.profileURL?.absoluteString,
                       "https://image.tmdb.org/t/p/w185/daenerys.jpg")

        let director = try XCTUnwrap(credits.crew.first)
        XCTAssertFalse(director.hasProfile)
        XCTAssertNil(director.profileURL)
    }

    func testProfileURLUsesProfileSize() {
        XCTAssertEqual(
            TMDBImage.profileURL(path: "/daenerys.jpg")?.absoluteString,
            "https://image.tmdb.org/t/p/w185/daenerys.jpg")
        XCTAssertEqual(TMDBImage.profileSize, "w185")
        XCTAssertNil(TMDBImage.profileURL(path: nil))
        XCTAssertNil(TMDBImage.profileURL(path: ""))
    }

    /// 没有对应职务就是空数组,详情页整行不显示。
    func testCrewNamesFilterByJob() throws {
        let credits = TMDBCredits(
            cast: [],
            crew: [
                try Self.person(id: 1, name: "A", job: "Director"),
                try Self.person(id: 2, name: "B", job: "Writer"),
                try Self.person(id: 3, name: "C", job: "Director"),
                try Self.person(id: 4, name: "", job: "Director"),
            ])
        XCTAssertEqual(credits.names(withJob: "Director"), ["A", "C"])
        XCTAssertEqual(credits.names(withJob: "Writer"), ["B"])
        XCTAssertTrue(credits.names(withJob: "Producer").isEmpty)

        let profile = TMDBSeriesProfile(match: Self.match(status: nil), cast: [], crew: credits.crew)
        XCTAssertEqual(profile.crewNames(withJob: "Director"), ["A", "C"])
        XCTAssertTrue(profile.crewNames(withJob: "Composer").isEmpty)
    }

    // MARK: - 辅助构造

    private static func person(id: Int, name: String, job: String) throws -> TMDBPerson {
        // `TMDBPerson` 只有解码构造器(自定义 `init(from:)` 抑制了逐成员构造器),⛔ 不为测试另开入口。
        let json = #"{"id":\#(id),"name":"\#(name)","job":"\#(job)","order":0}"#
        return try JSONDecoder().decode(TMDBPerson.self, from: Data(json.utf8))
    }

    private static func match(status: String?) -> TMDBMatch {
        TMDBMatch(result: TMDBResult(
            tmdbID: 1399, title: nil, originalTitle: nil, releaseDate: nil,
            name: "Game of Thrones", originalName: nil, firstAirDate: "2011-04-17",
            overview: nil, posterPath: nil, voteAverage: 8.4,
            genres: nil, tagline: nil, status: status,
            productionCompanies: nil, networks: nil
        ), kind: .tv)
    }

    // MARK: - fixture

    /// 官方规格 `/3/search/movie` 的 200 示例(§3)。
    private static let movieJSON = #"""
    {"page":1,"results":[{"adult":false,"backdrop_path":"/hZkgoQYus5vegHoetLkCJzb17zJ.jpg",
    "genre_ids":[18,53,35],"id":550,"original_language":"en","original_title":"Fight Club",
    "overview":"A ticking-time-bomb insomniac and a slippery soap salesman channel primal male aggression.",
    "popularity":73.433,"poster_path":"/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg",
    "release_date":"1999-10-15","title":"Fight Club","video":false,
    "vote_average":8.433,"vote_count":26279}],"total_pages":1,"total_results":1}
    """#

    /// 官方 `/3/search/tv` 响应形状。
    private static let tvJSON = #"""
    {"page":1,"results":[{"adult":false,"backdrop_path":"/suopoADq0k8YZr4dQXcU6pToj6s.jpg",
    "genre_ids":[10765,18],"id":1399,"origin_country":["US"],"original_language":"en",
    "original_name":"Game of Thrones","overview":"Seven noble families fight for control.",
    "popularity":369.594,"poster_path":"/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg",
    "first_air_date":"2011-04-17","name":"Game of Thrones","vote_average":8.4,"vote_count":21000}],
    "total_pages":1,"total_results":1}
    """#

    /// 季详情(§7)。第 2 集 `name` 空串、`overview` null,覆盖降级路径。
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

    /// 详情(§9):顶层就是条目,没有 `results` 包装。只放本项目读的字段。
    private static let detailsJSON = #"""
    {"adult":false,"backdrop_path":"/suopoADq0k8YZr4dQXcU6pToj6s.jpg","created_by":[],
    "episode_run_time":[60],"first_air_date":"2011-04-17","genres":[{"id":18,"name":"剧情"},
    {"id":10765,"name":"奇幻"}],"id":1399,
    "in_production":false,"languages":["en"],"last_air_date":"2019-05-19",
    "name":"Game of Thrones","networks":[{"id":49,"name":"HBO",
    "logo_path":"/tuomPhY2UtuPTqqFnKMVHvSb724.png","origin_country":"US"}],
    "number_of_episodes":73,"number_of_seasons":8,"origin_country":["US"],
    "original_language":"en","original_name":"Game of Thrones","overview":"七大家族争夺铁王座。",
    "poster_path":"/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg",
    "production_companies":[{"id":3268,"name":"HBO","logo_path":"/x.png","origin_country":"US"}],
    "status":"Ended","tagline":"凛冬将至。","vote_average":8.4,"vote_count":21000}
    """#

    /// 演职员(§10)。第 3 位演员名为空串(覆盖过滤),导演 `profile_path` 为 null(覆盖无头像)。
    private static let creditsJSON = #"""
    {"id":1399,"cast":[{"adult":false,"gender":1,"id":1223786,
    "known_for_department":"Acting","name":"Emilia Clarke","original_name":"Emilia Clarke",
    "popularity":55.0,"profile_path":"/daenerys.jpg","character":"Daenerys Targaryen",
    "credit_id":"c1","order":0},{"adult":false,"gender":2,"id":22970,
    "known_for_department":"Acting","name":"Peter Dinklage","original_name":"Peter Dinklage",
    "popularity":40.0,"profile_path":"/tyrion.jpg","character":"Tyrion Lannister",
    "credit_id":"c2","order":1},{"adult":false,"gender":2,"id":99999,
    "known_for_department":"Acting","name":"","original_name":"","popularity":0.1,
    "profile_path":null,"character":"","credit_id":"c3","order":2}],
    "crew":[{"adult":false,"gender":2,"id":9813,"known_for_department":"Directing",
    "name":"David Nutter","original_name":"David Nutter","popularity":3.0,
    "profile_path":null,"credit_id":"c4","department":"Directing","job":"Director"}]}
    """#
}