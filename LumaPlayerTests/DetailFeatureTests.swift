import XCTest
@testable import LumaPlayer

/// 详情页:已看 / 收藏写入、相似推荐、字段解码与文案(API_CONTRACT.md 3.2、3.4、5.5、5.6)。
final class DetailFeatureTests: XCTestCase {
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

    // MARK: - 端点构造

    func testSetPlayedAndFavoriteUsePostToSetAndDeleteToClear() {
        let on = EmbyEndpoint.setPlayed(userID: "U", itemID: "I", played: true)
        let off = EmbyEndpoint.setPlayed(userID: "U", itemID: "I", played: false)
        XCTAssertEqual(on.method, "POST")
        XCTAssertEqual(off.method, "DELETE")
        XCTAssertEqual(on.path, "/Users/U/PlayedItems/I")
        XCTAssertEqual(off.path, on.path, "同一路径,只用方法区分(API_CONTRACT.md 5.5)")

        let favOn = EmbyEndpoint.setFavorite(userID: "U", itemID: "I", favorite: true)
        let favOff = EmbyEndpoint.setFavorite(userID: "U", itemID: "I", favorite: false)
        XCTAssertEqual(favOn.method, "POST")
        XCTAssertEqual(favOff.method, "DELETE")
        XCTAssertEqual(favOn.path, "/Users/U/FavoriteItems/I")
        XCTAssertNil(favOn.body, "5.6 没有请求体")
        XCTAssertTrue(favOn.requiresAuth)
    }

    func testSimilarCarriesUserIDAndLimit() {
        let endpoint = EmbyEndpoint.similar(itemID: "I", query: EmbySimilarQuery(userID: "U", limit: 12))
        XCTAssertEqual(endpoint.method, "GET")
        XCTAssertEqual(endpoint.path, "/Items/I/Similar")
        XCTAssertEqual(endpoint.queryItems, [EmbyQueryItem("UserId", "U"), EmbyQueryItem("Limit", "12")])
    }

    // MARK: - 连接层

    func testSetFavoriteSendsPostAndReturnsServerUserData() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("userdata_favorite_on_synthetic.json")),
            path: "/emby/Users/\(Self.userID)/FavoriteItems/ITEM-1"
        )
        let connection = try await makeConnection()

        let userData = try await connection.setFavorite(itemID: "ITEM-1", favorite: true)

        XCTAssertEqual(userData.isFavorite, true)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/FavoriteItems/ITEM-1"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.header("X-Emby-Token"), Self.token)
    }

    func testMarkUnplayedSendsDelete() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false}"#),
            path: "/emby/Users/\(Self.userID)/PlayedItems/ITEM-1"
        )
        let connection = try await makeConnection()

        let userData = try await connection.setPlayed(itemID: "ITEM-1", played: false)

        XCTAssertEqual(userData.played, false)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/PlayedItems/ITEM-1"))
        XCTAssertEqual(request.method, "DELETE")
    }

    func testSimilarDecodesQueryResult() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_movies_page1_synthetic.json")),
            path: "/emby/Items/ITEM-1/Similar"
        )
        let connection = try await makeConnection()

        let items = try await connection.similar(itemID: "ITEM-1", limit: 12)

        XCTAssertEqual(items.count, 2)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/Similar"))
        XCTAssertEqual(queryValue(request.url, "UserId"), Self.userID)
        XCTAssertEqual(queryValue(request.url, "Limit"), "12")
    }

    func testEpisodesAskForOverview() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_episodes_synthetic.json")),
            path: "/emby/Shows/SERIES-1/Episodes"
        )
        let connection = try await makeConnection()

        _ = try await connection.episodes(seriesID: "SERIES-1", seasonID: "SEASON-1")

        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/Episodes"))
        // Overview:分集行显示简介,列表接口默认不给;ProviderIds:弹幕匹配靠 Tmdb 走降级层(`DANMAKU.md` §3)
        XCTAssertEqual(
            queryValue(request.url, "Fields"), "Overview,ProviderIds",
            "分集行要显示简介,列表接口默认不给;弹幕匹配还要 ProviderIds")
    }

    // MARK: - 解码

    func testFullDetailDecodesPeopleStudiosAndStreams() throws {
        let item = try JSONDecoder().decode(
            EmbyItem.self,
            from: try FixtureLoader.data("item_movie_full_detail_synthetic.json")
        )
        XCTAssertEqual(item.people?.map(\.name), ["演员甲", "导演乙"])
        XCTAssertEqual(item.people?.first?.role, "角色甲")
        XCTAssertNil(item.people?.last?.primaryImageTag, "没有头像 tag 就是 nil,不请求图片")
        // Studios[].Id 在 4.1.1.0 里是 int64:只解 Name,不能让整项失败
        XCTAssertEqual(item.studios?.map(\.name), ["测试制片厂"])
        XCTAssertEqual(item.taglines, ["一句用于 fixture 的宣传语"])
        XCTAssertEqual(item.mediaStreams?.first?.displayTitle, "1080p H264")
        XCTAssertEqual(item.mediaStreams?.first?.height, 1080)
        XCTAssertEqual(item.mediaStreams?[1].channels, 2)
    }

    func testMinimalItemLeavesNewFieldsNil() throws {
        let item = try JSONDecoder().decode(
            EmbyItem.self,
            from: Data(#"{"Id":"X","Name":"Y"}"#.utf8)
        )
        XCTAssertNil(item.people)
        XCTAssertNil(item.studios)
        XCTAssertNil(item.mediaStreams)
        XCTAssertFalse(item.isPlayed)
        XCTAssertFalse(item.isFavorite)
    }

    // MARK: - 图片来源

    func testLandscapeImagePrefersEpisodeScreenshotThenParentBackdrop() throws {
        let episode = try decode(#"{"Id":"E","Name":"E","Type":"Episode","ImageTags":{"Primary":"P"},"ParentBackdropItemId":"S","ParentBackdropImageTags":["B"]}"#)
        XCTAssertEqual(episode.landscapeImage?.type, .primary)
        XCTAssertEqual(episode.landscapeImage?.itemID, "E")

        let noShot = try decode(#"{"Id":"E","Name":"E","Type":"Episode","ParentBackdropItemId":"S","ParentBackdropImageTags":["B"]}"#)
        XCTAssertEqual(noShot.landscapeImage?.type, .backdrop)
        XCTAssertEqual(noShot.landscapeImage?.itemID, "S")

        let movie = try decode(#"{"Id":"M","Name":"M","Type":"Movie","ImageTags":{"Primary":"P","Thumb":"T"}}"#)
        XCTAssertEqual(movie.landscapeImage?.type, .thumb, "电影的 Primary 是竖版海报,不能当横版用")

        let bare = try decode(#"{"Id":"M","Name":"M","Type":"Movie","ImageTags":{"Primary":"P"}}"#)
        XCTAssertNil(bare.landscapeImage, "没有任何横版 tag 就不请求")
    }

    /// 真实服务器的 `/Users/{UserId}/Items/Resume` 里电影常常只有 `ImageTags.Primary`(`BackdropImageTags` 为空),
    /// 只认横版 tag 的话「继续观看」的电影永远是占位图(分集的 `Primary` 本身是 16:9 剧照)。
    func testCoverImageFallsBackToOwnPoster() throws {
        let movie = try decode(#"{"Id":"M","Name":"M","Type":"Movie","ImageTags":{"Primary":"P"}}"#)
        XCTAssertNil(movie.landscapeImage, "横版图的语义不变:没有横版 tag 就是 nil")
        XCTAssertEqual(movie.coverImage?.type, .primary, "封面退回竖版海报")
        XCTAssertEqual(movie.coverImage?.itemID, "M")
        XCTAssertEqual(movie.coverImage?.tag, "P")
        XCTAssertNil(movie.coverImageFallback, "首选已经是海报,没有第二级可退")

        let withThumb = try decode(#"{"Id":"M","Name":"M","Type":"Movie","ImageTags":{"Primary":"P","Thumb":"T"}}"#)
        XCTAssertEqual(withThumb.coverImage?.type, .thumb, "有横版图时优先横版")
        XCTAssertEqual(withThumb.coverImageFallback?.type, .primary, "横版图有可能是服务端取不到的假 tag,退路是海报")
        XCTAssertEqual(withThumb.coverImageFallback?.tag, "P")

        let withBackdrop = try decode(#"{"Id":"M","Name":"M","Type":"Movie","ImageTags":{"Primary":"P"},"BackdropImageTags":["B"]}"#)
        XCTAssertEqual(withBackdrop.coverImage?.type, .backdrop)
        XCTAssertEqual(withBackdrop.coverImage?.tag, "B")
        XCTAssertEqual(withBackdrop.coverImageFallback?.tag, "P")

        let episode = try decode(#"{"Id":"E","Name":"E","Type":"Episode","ImageTags":{"Primary":"EP"}}"#)
        XCTAssertEqual(episode.coverImage?.type, .primary, "分集的 Primary 就是剧照,不受影响")
        XCTAssertEqual(episode.coverImage?.tag, "EP")
        XCTAssertNil(episode.coverImageFallback)

        let noImage = try decode(#"{"Id":"M","Name":"M","Type":"Movie"}"#)
        XCTAssertNil(noImage.coverImage, "连海报都没有:不请求、不编 tag,由 UI 决定显示占位图")
        XCTAssertNil(noImage.coverImageFallback)
    }

    func testLogoFallsBackToParent() throws {
        let own = try decode(#"{"Id":"M","Name":"M","ImageTags":{"Logo":"L"}}"#)
        XCTAssertEqual(own.logoSource?.itemID, "M")
        let parent = try decode(#"{"Id":"E","Name":"E","ParentLogoItemId":"S","ParentLogoImageTag":"L"}"#)
        XCTAssertEqual(parent.logoSource?.itemID, "S")
    }

    // MARK: - 文案

    func testRuntimeText() {
        XCTAssertNil(MediaFormat.runtime(ticks: nil))
        XCTAssertNil(MediaFormat.runtime(ticks: 0))
        XCTAssertEqual(MediaFormat.runtime(ticks: TickConverter.ticks(fromSeconds: 45 * 60)), "45 分钟")
        XCTAssertEqual(MediaFormat.runtime(ticks: TickConverter.ticks(fromSeconds: 102 * 60)), "1 小时 42 分钟")
        XCTAssertEqual(MediaFormat.runtime(ticks: TickConverter.ticks(fromSeconds: 120 * 60)), "2 小时")
        XCTAssertEqual(MediaFormat.runtime(ticks: TickConverter.ticks(fromSeconds: 20)), "1 分钟", "不足 1 分钟不显示 0 分钟")
    }

    func testRemainingOnlyWhenPartiallyWatched() throws {
        let half = try decode(#"{"Id":"M","Name":"M","RunTimeTicks":36000000000,"UserData":{"PlaybackPositionTicks":18000000000}}"#)
        XCTAssertEqual(MediaFormat.remaining(for: half), "30 分钟")
        let fresh = try decode(#"{"Id":"M","Name":"M","RunTimeTicks":36000000000}"#)
        XCTAssertNil(MediaFormat.remaining(for: fresh))
    }

    func testPremiereDateTakesDayAndDropsPlaceholder() {
        XCTAssertEqual(MediaFormat.date("2021-06-18T00:00:00.0000000Z"), "2021-06-18")
        XCTAssertNil(MediaFormat.date("0001-01-01T00:00:00.0000000Z"))
        XCTAssertNil(MediaFormat.date(nil))
    }

    func testRatingKeepsOneDecimal() {
        XCTAssertEqual(MediaFormat.rating(8.123), "8.1")
        XCTAssertNil(MediaFormat.rating(nil))
        XCTAssertNil(MediaFormat.rating(0))
    }

    func testItemDecodesMediaSourcesAndLabelsThem() throws {
        let item = try decode("""
        {"Id":"1","Name":"M","MediaSources":[
          {"Id":"A","Name":"1080p","Container":"mkv","Size":8000000000,
           "MediaStreams":[{"Index":0,"Type":"Video","DisplayTitle":"1080p H264"}]},
          {"Id":"B","Container":"mp4"}]}
        """)

        let sources = try XCTUnwrap(item.mediaSources)
        XCTAssertEqual(sources.map(\.id), ["A", "B"])
        XCTAssertTrue(sources[0].versionLabel.hasPrefix("1080p · 1080p H264 · "))
        XCTAssertEqual(sources[1].versionLabel, "MP4")
    }

    func testPlaybackRequestCarriesPreferredSource() throws {
        let item = try decode(#"{"Id":"1","Name":"M"}"#)
        let server = ServerProfile(
            displayName: "emby.test", baseURL: testURL("https://emby.test"), apiPathPrefix: "/emby",
            userID: "u", username: "n", deviceID: "d")

        XCTAssertNil(PlaybackRequest(server: server, item: item).preferredMediaSourceID)
        XCTAssertEqual(
            PlaybackRequest(server: server, item: item, preferredMediaSourceID: "B").preferredMediaSourceID,
            "B")
    }

    // MARK: - 辅助

    private func decode(_ json: String) throws -> EmbyItem {
        try JSONDecoder().decode(EmbyItem.self, from: Data(json.utf8))
    }

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
