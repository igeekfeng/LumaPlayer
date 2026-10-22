import XCTest
@testable import LumaPlayer

/// `EmbyItem` 的 fixture 解码(API_CONTRACT.md 8.1 的可选性原则)。
/// 字段名取自官方 OpenAPI 的 BaseItemDto / UserItemDataDto;fixture 都是 `_synthetic` 构造数据(Q12)。
final class EmbyItemDecodingTests: XCTestCase {
    private let decoder = ResponseDecoder()

    private func decodeItems(_ fixture: String) throws -> EmbyItemsResponse<EmbyItem> {
        try decoder.decode(
            EmbyItemsResponse<EmbyItem>.self,
            from: try FixtureLoader.data(fixture),
            endpointName: "Users/{UserId}/Items"
        )
    }

    private func decodeItem(_ fixture: String) throws -> EmbyItem {
        try decoder.decode(
            EmbyItem.self,
            from: try FixtureLoader.data(fixture),
            endpointName: "Users/{UserId}/Items/{Id}"
        )
    }

    // MARK: - 正常解码

    func testMoviePageDecodesWithProgress() throws {
        let page = try decodeItems("items_movies_page1_synthetic.json")
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.totalRecordCount, 4)
        XCTAssertEqual(page.items[0].name, "测试电影一")
        XCTAssertEqual(page.items[0].kind, .movie)
        XCTAssertEqual(page.items[0].productionYear, 2019)
        // 进度 = 位置 / 时长:13500000000 / 54000000000 = 0.25
        XCTAssertEqual(page.items[0].progressFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(page.items[0].primaryImageTagValue, "TAG-PRIMARY-1")
        XCTAssertNil(page.items[1].progressFraction, "没看过的位置是 0 → 不画进度条")
    }

    func testEpisodesDecodeNumbersAndKinds() throws {
        let page = try decodeItems("shows_episodes_synthetic.json")
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.items[0].kind, .episode)
        XCTAssertEqual(page.items[0].indexNumber, 1)
        XCTAssertEqual(page.items[0].parentIndexNumber, 1)
        XCTAssertEqual(page.items[0].seriesName, "测试剧集")
        // 第三集没有集号:不崩、不猜
        XCTAssertNil(page.items[2].indexNumber)
        XCTAssertNil(page.items[2].overview)
    }

    func testSeasonsDecodeSeriesId() throws {
        let page = try decodeItems("shows_seasons_synthetic.json")
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].kind, .season)
        XCTAssertEqual(page.items[0].seriesID, "00000000-0000-0000-0000-000000000200")
        XCTAssertNil(page.items[1].imageTags, "第二季没有图片 tag → 不请求图片")
    }

    func testResumeDecodesMixedTypes() throws {
        let page = try decodeItems("items_resume_synthetic.json")
        XCTAssertEqual(page.items.map(\.kind), [.movie, .episode])
    }

    // MARK: - 8.1:可选字段缺失不崩、必填缺失报错

    func testItemWithOnlyRequiredFieldsDecodes() throws {
        let item = try decodeItem("item_minimal_synthetic.json")
        XCTAssertEqual(item.id, "00000000-0000-0000-0000-000000000199")
        XCTAssertEqual(item.name, "只有必填字段的项目")
        XCTAssertNil(item.type)
        XCTAssertNil(item.overview)
        XCTAssertNil(item.userData)
        XCTAssertNil(item.runTimeTicks)
        XCTAssertEqual(item.kind, .other, "Type 缺失不得猜成电影")
        XCTAssertNil(item.primaryImageTagValue)
    }

    func testMissingNameIsDecodingError() throws {
        // Name 在 8.1 的必填表里:缺失即视为响应损坏
        XCTAssertThrowsError(try decodeItem("item_missing_name_synthetic.json"))
    }

    func testUnknownFieldsAreIgnored() throws {
        // 未知字段不得导致解码失败(8.1)
        let json = Data(#"{"Id":"X","Name":"带未知字段","SomethingNew":{"a":1}}"#.utf8)
        let item = try decoder.decode(EmbyItem.self, from: json, endpointName: "Users/{UserId}/Items")
        XCTAssertEqual(item.name, "带未知字段")
    }

    // MARK: - 图片 tag(API_CONTRACT.md 3.3)

    func testPrimaryTagFallsBackToImageTags() throws {
        // 4.1.1.0 OpenAPI 只有 ImageTags 没有 PrimaryImageTag;两个都解,取到哪个都算有图(Q13)
        let json = Data(#"{"Id":"X","Name":"图","PrimaryImageTag":"DIRECT-TAG"}"#.utf8)
        let item = try decoder.decode(EmbyItem.self, from: json, endpointName: "Users/{UserId}/Items")
        XCTAssertEqual(item.primaryImageTagValue, "DIRECT-TAG")
    }

    func testBackdropFallsBackToParent() throws {
        let json = Data(
            """
            {"Id":"X","Name":"继承背景","ParentBackdropItemId":"PARENT-1","ParentBackdropImageTags":["PARENT-TAG"]}
            """.utf8
        )
        let item = try decoder.decode(EmbyItem.self, from: json, endpointName: "Users/{UserId}/Items")
        let source = try XCTUnwrap(item.backdropSource)
        XCTAssertEqual(source.itemID, "PARENT-1")
        XCTAssertEqual(source.tag, "PARENT-TAG")
    }

    func testNoBackdropMeansNoImageRequest() throws {
        let item = try decodeItem("item_minimal_synthetic.json")
        XCTAssertNil(item.backdropSource)
        XCTAssertNil(item.primaryImageTagValue)
    }
}
