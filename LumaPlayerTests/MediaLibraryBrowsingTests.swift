import XCTest
@testable import LumaPlayer

/// `ServerConnection` 的浏览方法:列表 / Resume / Latest / 详情 / 季 / 分集 / 图片
/// (端点与参数见 API_CONTRACT.md 3.2、3.3)。
///
/// 全部走 `MockEmbyURLProtocol`,**零真实网络依赖**。
final class MediaLibraryBrowsingTests: XCTestCase {
    private static let userID = "USER-1"
    private static let token = "FAKE_TOKEN_0123456789"

    private var session: URLSession!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() async throws {
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
        session = nil
    }

    // MARK: - 列表

    func testItemsSendsAuthHeadersAndPaging() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_movies_page1_synthetic.json")),
            path: "/emby/Users/\(Self.userID)/Items"
        )
        let connection = try await makeConnection()

        var query = EmbyItemsQuery()
        query.startIndex = 0
        query.limit = 60
        let page = try await connection.items(query)

        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.totalRecordCount, 4)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/Items"))
        XCTAssertEqual(request.header("X-Emby-Token"), Self.token)
        XCTAssertTrue(request.header("Authorization")?.contains("UserId=\"\(Self.userID)\"") == true)
    }

    func testSearchSendsSearchTerm() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_search_synthetic.json")),
            path: "/emby/Users/\(Self.userID)/Items"
        )
        let connection = try await makeConnection()

        var query = EmbyItemsQuery()
        query.searchTerm = "测试"
        query.recursive = true
        let page = try await connection.items(query)

        XCTAssertEqual(page.items.count, 2)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/Items"))
        XCTAssertEqual(queryValue(request.url, "SearchTerm"), "测试")
    }

    // MARK: - Resume / Latest

    /// ⚠️ `/Items/Resume` **必须带 `MediaTypes=Video` + `Recursive=true`**:本地
    /// Emby 4.9.5.0 不带时恒返回 0 条,继续观看会变成永远空白。这是 Emby Web
    /// 自己查继续观看的写法。实测见 `docs/DECISIONS/emby-resume-items-endpoint.md`。
    func testResumeUsesResumeEndpointWithMediaTypes() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_resume_synthetic.json")),
            path: "/emby/Users/\(Self.userID)/Items/Resume"
        )
        let connection = try await makeConnection()

        let page = try await connection.resume(limit: 20)

        XCTAssertEqual(page.items.count, 2)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "Items/Resume"))
        XCTAssertEqual(queryValue(request.url, "Recursive"), "true")
        XCTAssertEqual(queryValue(request.url, "MediaTypes"), "Video")
        XCTAssertEqual(queryValue(request.url, "Limit"), "20")
    }

    func testLatestUsesLatestEndpoint() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_latest_synthetic.json")),
            path: "/emby/Users/\(Self.userID)/Items/Latest"
        )
        let connection = try await makeConnection()

        var query = EmbyLatestQuery()
        query.limit = 20
        let items = try await connection.latest(query: query)

        XCTAssertEqual(items.count, 2)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "Items/Latest"))
        XCTAssertEqual(queryValue(request.url, "Limit"), "20")
    }

    // MARK: - 详情 / 季 / 分集

    func testItemDetailUsesSingleItemEndpoint() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("item_movie_detail_synthetic.json")),
            path: "/emby/Users/\(Self.userID)/Items/ITEM-1"
        )
        let connection = try await makeConnection()

        let item = try await connection.item(id: "ITEM-1")

        // 列表接口字段更少:Overview 只有单项接口会给(API_CONTRACT.md 3.2)
        XCTAssertNotNil(item.overview)
        XCTAssertEqual(item.name, "测试电影一")
    }

    func testSeasonsUsesShowsSeasons() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_seasons_synthetic.json")),
            path: "/emby/Shows/SERIES-1/Seasons"
        )
        let connection = try await makeConnection()

        let seasons = try await connection.seasons(seriesID: "SERIES-1")

        XCTAssertEqual(seasons.count, 2)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/Seasons"))
        XCTAssertEqual(queryValue(request.url, "UserId"), Self.userID)
    }

    func testEpisodesUsesShowsEpisodesWithSeasonID() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_episodes_synthetic.json")),
            path: "/emby/Shows/SERIES-1/Episodes"
        )
        let connection = try await makeConnection()

        let episodes = try await connection.episodes(seriesID: "SERIES-1", seasonID: "SEASON-1")

        XCTAssertEqual(episodes.count, 3)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/Episodes"))
        XCTAssertEqual(queryValue(request.url, "SeasonId"), "SEASON-1")
    }

    // MARK: - 续播定位(剧集页要定位到该播的那一集)

    func testResumableEpisodeAsksServerToDecide() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_resumable_episode_synthetic.json")),
            path: "/emby/Users/\(Self.userID)/Items"
        )
        let connection = try await makeConnection()

        let episode = try await connection.resumableEpisode(seriesID: "SERIES-1")

        // 「算不算可续播」交给服务端判定,客户端不复制 MinResumePct 等规则
        XCTAssertEqual(episode?.id, "00000000-0000-0000-0000-000000000202")
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/Items"))
        XCTAssertEqual(queryValue(request.url, "ParentId"), "SERIES-1")
        XCTAssertEqual(queryValue(request.url, "Recursive"), "true")
        XCTAssertEqual(queryValue(request.url, "IncludeItemTypes"), "Episode")
        XCTAssertEqual(queryValue(request.url, "Filters"), "IsResumable")
        XCTAssertEqual(queryValue(request.url, "SortBy"), "DatePlayed")
        XCTAssertEqual(queryValue(request.url, "SortOrder"), "Descending")
        XCTAssertEqual(queryValue(request.url, "Limit"), "1")
        // 列表接口默认不给 Overview(3.2),定位到集后要显示简介
        XCTAssertEqual(queryValue(request.url, "Fields"), "Overview")
    }

    // MARK: - NextUp(剧集页定位「接着看哪一集」,Q25)

    /// ⚠️ 路径是 `/Shows/NextUp`,`SeriesId` 是**查询参数** —— 不是 `/Shows/{Id}/NextUp`。
    /// 官方 OpenAPI 4.1.1.0 核实 2026-09-23。
    func testNextUpUsesShowsNextUpWithSeriesIDQuery() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_resumable_episode_synthetic.json")),
            path: "/emby/Shows/NextUp"
        )
        let connection = try await makeConnection()

        let episode = try await connection.nextUpEpisode(seriesID: "SERIES-1")

        XCTAssertEqual(episode?.id, "00000000-0000-0000-0000-000000000202")
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "Shows/NextUp"))
        XCTAssertEqual(queryValue(request.url, "UserId"), Self.userID)
        XCTAssertEqual(queryValue(request.url, "SeriesId"), "SERIES-1")
        XCTAssertEqual(queryValue(request.url, "Limit"), "1")
        XCTAssertEqual(queryValue(request.url, "Fields"), "Overview")
    }

    /// 定位顺序是 NextUp → 可续播:两条都有结果时取 NextUp 的。
    func testFocusEpisodePrefersNextUpOverResumable() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_resumable_episode_synthetic.json")),
            path: "/emby/Shows/NextUp"
        )
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_resume_synthetic.json")),
            path: "/emby/Users/\(Self.userID)/Items"
        )
        let connection = try await makeConnection()

        let episode = try await connection.focusEpisode(seriesID: "SERIES-1")

        // 两个 fixture 的首条 Id 不同,取到 202 说明用的是 NextUp 的结果
        XCTAssertEqual(episode?.id, "00000000-0000-0000-0000-000000000202")
    }

    /// NextUp 没有结果(老版本可能没有这个端点)时退回「可续播」那条路。
    func testFocusEpisodeFallsBackToResumableWhenNextUpIsEmpty() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_empty_synthetic.json")),
            path: "/emby/Shows/NextUp"
        )
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_resumable_episode_synthetic.json")),
            path: "/emby/Users/\(Self.userID)/Items"
        )
        let connection = try await makeConnection()

        let episode = try await connection.focusEpisode(seriesID: "SERIES-1")

        XCTAssertEqual(episode?.id, "00000000-0000-0000-0000-000000000202")
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/Items"))
        XCTAssertEqual(queryValue(request.url, "Filters"), "IsResumable")
    }

    func testResumableEpisodeReturnsNilWhenNothingResumable() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_empty_synthetic.json")),
            path: "/emby/Users/\(Self.userID)/Items"
        )
        let connection = try await makeConnection()

        let episode = try await connection.resumableEpisode(seriesID: "SERIES-1")

        XCTAssertNil(episode, "没有可续播的集时返回 nil,由调用方回退到第一集")
    }

    // MARK: - 图片(API_CONTRACT.md 3.3)

    func testImageRequestCarriesAuthAndMaxWidth() async throws {
        MockEmbyURLProtocol.stub(
            MockEmbyURLProtocol.Stub(
                outcome: .response(statusCode: 200, body: Data([0x89, 0x50, 0x4E, 0x47]))
            ),
            path: "/emby/Items/ITEM-1/Images/Primary"
        )
        let connection = try await makeConnection()

        let data = try await connection.imageData(
            itemID: "ITEM-1",
            type: .primary,
            tag: "TAG-1",
            maxWidth: 300
        )

        XCTAssertEqual(data.count, 4)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "Images/Primary"))
        // 图片是否需要认证头尚未核实(docs/KNOWN_ISSUES.md Q12):核实前一律带上
        XCTAssertEqual(request.header("X-Emby-Token"), Self.token)
        XCTAssertEqual(queryValue(request.url, "MaxWidth"), "300")
        XCTAssertEqual(queryValue(request.url, "Tag"), "TAG-1")
    }

    func testImageRequiresToken() async throws {
        let profile = ServerProfile(
            displayName: "emby.test",
            baseURL: testURL("https://emby.test"),
            apiPathPrefix: "/emby",
            userID: Self.userID,
            deviceID: "DEVICE-UUID-1"
        )
        let connection = ServerConnection(profile: profile, credentials: credentials, session: session)

        do {
            _ = try await connection.imageData(itemID: "ITEM-1", type: .primary, tag: nil, maxWidth: 300)
            XCTFail("没有 token 时应抛 unauthorized")
        } catch let error as EmbyAPIError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    // MARK: - 401 只影响这一台

    func testUnauthorizedDuringBrowsingClearsOnlyThisToken() async throws {
        MockEmbyURLProtocol.stub(.status(401), path: "/emby/Users/\(Self.userID)/Items")
        let connection = try await makeConnection()
        let profile = await connection.currentProfile()

        do {
            _ = try await connection.items(EmbyItemsQuery())
            XCTFail("401 应抛 unauthorized")
        } catch let error as EmbyAPIError {
            XCTAssertEqual(error, .unauthorized)
        }

        let token = try await credentials.token(forServer: profile.id)
        XCTAssertNil(token, "401 必须清掉这台服务器的 token(API_CONTRACT.md 2.5)")
    }

    // MARK: - 辅助

    private func makeConnection() async throws -> ServerConnection {
        let profile = ServerProfile(
            displayName: "emby.test",
            baseURL: testURL("https://emby.test"),
            apiPathPrefix: "/emby",
            userID: Self.userID,
            username: "testuser",
            deviceID: "DEVICE-UUID-1"
        )
        try await credentials.saveToken(Self.token, forServer: profile.id)
        return ServerConnection(profile: profile, credentials: credentials, session: session)
    }

    private func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }
}
