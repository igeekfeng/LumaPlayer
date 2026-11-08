import XCTest
@testable import LumaPlayer

/// 剧集详情页的主按钮:进页面就在,点下去才取「该播哪一集」(`MediaDetailViewModel.playSeries`)。
/// ⛔ 不为定位另画加载态 —— 定位回来的只是按钮上的续播位置。
final class DetailPlaybackResolveTests: XCTestCase {
    private static let userID = "USER-1"
    private static let token = "FAKE_TOKEN_0123456789"
    private static let seriesID = "00000000-0000-0000-0000-000000000200"

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

    @MainActor
    func testPlaySeriesResolvesWhenFocusedEpisodeIsNotLoadedYet() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_resumable_episode_synthetic.json")),
            path: "/emby/Shows/NextUp"
        )
        let (viewModel, server) = try await makeViewModel()

        // 进页面时定位还没回来:按钮照样在、照样能点
        XCTAssertNil(viewModel.focusedEpisode)
        var played: EmbyItem?
        viewModel.playSeries(try series(), server: server) { played = $0 }

        XCTAssertTrue(viewModel.isResolvingPlayback, "点了才转圈,不是页面加载态")
        try await waitUntil("定位完成") { played != nil }
        XCTAssertEqual(played?.id, "00000000-0000-0000-0000-000000000202")
        XCTAssertEqual(viewModel.focusedEpisode?.id, played?.id, "播的这一集同步成定位集")
        XCTAssertNil(viewModel.playbackError)
        try await waitUntil("转圈结束") { !viewModel.isResolvingPlayback }
    }

    /// 定位已经落定(通常进页面那趟就完成了):直接播,不再多发一趟。
    @MainActor
    func testPlaySeriesReusesResolvedEpisodeWithoutNetwork() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("items_resumable_episode_synthetic.json")),
            path: "/emby/Shows/NextUp"
        )
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_episodes_synthetic.json")),
            path: "/emby/Shows/\(Self.seriesID)/Episodes"
        )
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_seasons_synthetic.json")),
            path: "/emby/Shows/\(Self.seriesID)/Seasons"
        )
        let (viewModel, server) = try await makeViewModel()

        var first: EmbyItem?
        viewModel.playSeries(try series(), server: server) { first = $0 }
        try await waitUntil("首次定位完成") { first != nil }
        let requestsAfterFirst = MockEmbyURLProtocol.recordedRequests().count

        var second: EmbyItem?
        viewModel.playSeries(try series(), server: server) { second = $0 }

        XCTAssertEqual(second?.id, first?.id, "已经定位到就直接播")
        XCTAssertEqual(
            MockEmbyURLProtocol.recordedRequests().count, requestsAfterFirst,
            "定位结果在手上时 ⛔ 再问服务端一遍")
    }

    /// 定位不到就照实提示,⛔ 不退回去随便播一集。
    @MainActor
    func testPlaySeriesReportsFailureInsteadOfPlayingSomethingElse() async throws {
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Shows/NextUp")
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Users/\(Self.userID)/Items")
        let (viewModel, server) = try await makeViewModel()

        var played: EmbyItem?
        viewModel.playSeries(try series(), server: server) { played = $0 }

        try await waitUntil("定位失败") { viewModel.playbackError != nil }
        XCTAssertNil(played, "定位失败不能起播,也不能随便挑一集")
        XCTAssertNil(viewModel.focusedEpisode)
        try await waitUntil("转圈结束") { !viewModel.isResolvingPlayback }
    }

    /// 换条目(或点「重试」)时上一页的定位态不能留在新页面上。
    @MainActor
    func testLoadResetsPlaybackState() async throws {
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Shows/NextUp")
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Users/\(Self.userID)/Items")
        let (viewModel, server) = try await makeViewModel()
        viewModel.playSeries(try series(), server: server) { _ in }
        try await waitUntil("拿到错误") { viewModel.playbackError != nil }

        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("item_movie_detail_synthetic.json")),
            path: "/emby/Users/\(Self.userID)/Items/OTHER"
        )
        viewModel.load(item: try movie("OTHER"), server: server)

        XCTAssertNil(viewModel.playbackError, "换页面要清掉上一页的播放提示")
        XCTAssertFalse(viewModel.isResolvingPlayback)
    }

    // MARK: - 辅助

    private func series() throws -> EmbyItem {
        try JSONDecoder().decode(
            EmbyItem.self,
            from: Data(#"{"Id":"\#(Self.seriesID)","Name":"测试剧集","Type":"Series"}"#.utf8)
        )
    }

    private func movie(_ id: String) throws -> EmbyItem {
        try JSONDecoder().decode(
            EmbyItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie"}"#.utf8)
        )
    }

    private func makeProfile() -> ServerProfile {
        ServerProfile(
            displayName: "emby.test",
            baseURL: testURL("https://emby.test"),
            apiPathPrefix: "/emby",
            userID: Self.userID,
            username: "testuser",
            deviceID: "DEVICE-UUID-1"
        )
    }

    @MainActor
    private func makeViewModel() async throws -> (MediaDetailViewModel, ServerProfile) {
        let profile = makeProfile()
        try await credentials.saveToken(Self.token, forServer: profile.id)
        let registry = try ServerRegistry(profiles: [], credentials: credentials)
        let container = AppContainer(registry: registry, credentials: credentials, session: session)
        return (MediaDetailViewModel(container: container), profile)
    }

    @MainActor
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "等待超时:\(what)")
    }
}
