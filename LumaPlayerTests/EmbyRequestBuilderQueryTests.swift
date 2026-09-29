import XCTest
@testable import LumaPlayer

/// 浏览类端点的 URL 与查询串构造
/// (API_CONTRACT.md 3.2、3.3;参数名一律出自这两节的参数表)。
///
/// 纯构造测试,不发网络请求。
final class EmbyRequestBuilderQueryTests: XCTestCase {
    private func makeBuilder() -> EmbyRequestBuilder {
        EmbyRequestBuilder(
            baseURL: testURL("https://emby.test"),
            apiPathPrefix: "/emby",
            deviceID: "DEVICE-UUID-1",
            deviceName: "Mac",
            appVersion: "1.2.3"
        )
    }

    private func components(
        for endpoint: EmbyEndpoint,
        token: String = "FAKE_TOKEN_0123456789"
    ) throws -> URLComponents {
        let request = try makeBuilder().makeRequest(
            for: endpoint,
            accessToken: token,
            userID: "USER-1"
        )
        return try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
    }

    private func queryValue(_ components: URLComponents, _ name: String) -> String? {
        components.queryItems?.first { $0.name == name }?.value
    }

    // MARK: - 列表 / 分页 / 搜索

    func testItemsQueryBuildsPagingParameters() throws {
        var query = EmbyItemsQuery()
        query.parentID = "VIEW-1"
        query.recursive = true
        query.includeItemTypes = ["Movie", "Series"]
        query.sortBy = ["SortName"]
        query.sortOrder = ["Ascending"]
        query.startIndex = 60
        query.limit = 60

        let components = try components(for: .items(userID: "USER-1", query: query))
        XCTAssertEqual(components.path, "/emby/Users/USER-1/Items")
        XCTAssertEqual(queryValue(components, "ParentId"), "VIEW-1")
        XCTAssertEqual(queryValue(components, "Recursive"), "true")
        XCTAssertEqual(queryValue(components, "IncludeItemTypes"), "Movie,Series")
        XCTAssertEqual(queryValue(components, "SortBy"), "SortName")
        XCTAssertEqual(queryValue(components, "SortOrder"), "Ascending")
        XCTAssertEqual(queryValue(components, "StartIndex"), "60")
        XCTAssertEqual(queryValue(components, "Limit"), "60")
    }

    func testItemsQueryOmitsUnsetParameters() throws {
        let components = try components(for: .items(userID: "USER-1", query: EmbyItemsQuery()))
        XCTAssertNil(components.queryItems, "没给的字段不许拼进 URL —— 服务端默认值会因此被改掉")
    }

    func testSearchTermIsEncodedInQuery() throws {
        var query = EmbyItemsQuery()
        query.searchTerm = "星球大战 4"
        query.recursive = true
        query.limit = 20

        let components = try components(for: .items(userID: "USER-1", query: query))
        XCTAssertEqual(queryValue(components, "SearchTerm"), "星球大战 4")
        XCTAssertTrue(try XCTUnwrap(components.url).absoluteString.contains("SearchTerm="),
                      "中文关键词必须被百分号编码后仍能取回原值")
    }

    func testResumeAndLatestUseTheirOwnPaths() throws {
        let resume = try components(for: .resume(userID: "USER-1", query: EmbyItemsQuery()))
        XCTAssertEqual(resume.path, "/emby/Users/USER-1/Items/Resume")

        var latest = EmbyLatestQuery()
        latest.limit = 20
        let latestComponents = try components(for: .latest(userID: "USER-1", query: latest))
        XCTAssertEqual(latestComponents.path, "/emby/Users/USER-1/Items/Latest")
        XCTAssertEqual(queryValue(latestComponents, "Limit"), "20")
        XCTAssertNil(queryValue(latestComponents, "StartIndex"),
                     "Latest 端点没有 StartIndex(官方 OpenAPI 核实)")
    }

    // MARK: - 剧集:季与分集

    func testSeasonsCarriesUserID() throws {
        let components = try components(for: .seasons(seriesID: "SERIES-1", userID: "USER-1"))
        XCTAssertEqual(components.path, "/emby/Shows/SERIES-1/Seasons")
        XCTAssertEqual(queryValue(components, "UserId"), "USER-1")
    }

    func testEpisodesCarriesSeasonID() throws {
        var query = EmbyEpisodesQuery()
        query.userID = "USER-1"
        query.seasonID = "SEASON-1"
        let components = try components(for: .episodes(seriesID: "SERIES-1", query: query))
        XCTAssertEqual(components.path, "/emby/Shows/SERIES-1/Episodes")
        XCTAssertEqual(queryValue(components, "SeasonId"), "SEASON-1")
        XCTAssertEqual(queryValue(components, "UserId"), "USER-1")
    }

    // MARK: - 图片(API_CONTRACT.md 3.3)

    func testImageRequestCarriesMaxWidthAndTag() throws {
        var query = EmbyImageQuery()
        query.maxWidth = 300
        query.tag = "TAG-1"
        let components = try components(for: .image(itemID: "ITEM-1", type: .primary, query: query))
        XCTAssertEqual(components.path, "/emby/Items/ITEM-1/Images/Primary")
        XCTAssertEqual(queryValue(components, "MaxWidth"), "300")
        XCTAssertEqual(queryValue(components, "Tag"), "TAG-1")
    }

    func testImageRequestCarriesAuthHeadersUntilVerified() throws {
        // 「图片是否需要认证头」未核实(docs/KNOWN_ISSUES.md Q12) → 一律带上(多带无害)
        let request = try makeBuilder().makeRequest(
            for: .image(itemID: "ITEM-1", type: .backdrop, query: EmbyImageQuery(maxWidth: 1360)),
            accessToken: "FAKE_TOKEN_0123456789",
            userID: "USER-1"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "FAKE_TOKEN_0123456789")
    }

    func testDetailEndpointHasNoQuery() throws {
        let components = try components(for: .item(userID: "USER-1", itemID: "ITEM-1"))
        XCTAssertEqual(components.path, "/emby/Users/USER-1/Items/ITEM-1")
        XCTAssertNil(components.queryItems)
    }
}
