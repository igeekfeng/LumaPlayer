import XCTest
@testable import LumaPlayer

/// 批量标记已看 / 未看(API_CONTRACT.md 5.8):Emby 没有批量端点,逐条串行发 5.5,失败不中断、401 即停,一次作废缓存。
final class SeasonBatchPlayedTests: XCTestCase {
    private static let userID = "USER-1"
    private static let token = "FAKE_TOKEN_0123456789"

    private var session: URLSession!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var cacheDirectory: URL!
    private var responseCache: EmbyResponseCache!

    override func setUp() async throws {
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaPlayerBatchPlayedTests-\(UUID().uuidString)", isDirectory: true)
        responseCache = EmbyResponseCache(directory: cacheDirectory)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
        session = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        cacheDirectory = nil
        responseCache = nil
    }

    // MARK: - 只写需要改的集

    func testPendingIDsSkipEpisodesAlreadyInTargetState() throws {
        let episodes = try [
            episode("E1", played: true),
            episode("E2", played: false),
            episode("E3", played: nil),
        ]

        XCTAssertEqual(MediaDetailViewModel.pendingIDs(in: episodes, played: true), ["E2", "E3"],
                       "已看的不再发请求;UserData 缺失按未看算(与 isPlayed 同口径)")
        XCTAssertEqual(MediaDetailViewModel.pendingIDs(in: episodes, played: false), ["E1"])
        XCTAssertEqual(MediaDetailViewModel.pendingIDs(in: episodes, played: true).count, 2,
                       "目标状态全部满足时是空集,调用方据此禁用菜单项")
    }

    // MARK: - 连接层

    func testBatchSendsOneRequestPerItemAndReturnsWrittenUserData() async throws {
        stubPlayed(itemID: "E1")
        stubPlayed(itemID: "E2")
        let connection = try await makeConnection()

        let result = try await connection.setPlayed(itemIDs: ["E1", "E2"], played: true)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.written.keys.sorted(), ["E1", "E2"])
        XCTAssertNil(result.firstError)
        let posts = MockEmbyURLProtocol.recordedRequests()
            .filter { $0.url.path.contains("/PlayedItems/") }
        XCTAssertEqual(posts.count, 2, "Emby 没有批量端点:一集一条请求(5.8)")
        XCTAssertTrue(posts.allSatisfy { $0.method == "POST" })
    }

    func testBatchUnmarkUsesDeleteForEveryItem() async throws {
        stubPlayed(itemID: "E1")
        stubPlayed(itemID: "E2")
        let connection = try await makeConnection()

        let result = try await connection.setPlayed(itemIDs: ["E1", "E2"], played: false)

        XCTAssertTrue(result.isComplete)
        let requests = MockEmbyURLProtocol.recordedRequests().filter { $0.url.path.contains("/PlayedItems/") }
        XCTAssertEqual(requests.map(\.method), ["DELETE", "DELETE"], "未看走 DELETE(5.5)")
    }

    func testBatchKeepsGoingAfterOneFailureAndReportsIt() async throws {
        stubPlayed(itemID: "E1")
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Users/\(Self.userID)/PlayedItems/E2")
        stubPlayed(itemID: "E3")
        let connection = try await makeConnection()

        let result = try await connection.setPlayed(itemIDs: ["E1", "E2", "E3"], played: true)

        XCTAssertEqual(result.written.keys.sorted(), ["E1", "E3"], "一条失败不能中断后面的写入")
        XCTAssertEqual(result.failedItemIDs, ["E2"])
        XCTAssertEqual(result.firstError, .server(status: 500))
        XCTAssertFalse(result.isComplete)
    }

    func testBatchStopsAtUnauthorizedAndCountsTheRestAsFailed() async throws {
        stubPlayed(itemID: "E1")
        MockEmbyURLProtocol.stub(.status(401), path: "/emby/Users/\(Self.userID)/PlayedItems/E2")
        let connection = try await makeConnection()

        let result = try await connection.setPlayed(itemIDs: ["E1", "E2", "E3"], played: true)

        XCTAssertEqual(result.written.keys.sorted(), ["E1"])
        XCTAssertEqual(result.failedItemIDs, ["E2", "E3"], "401 之后不再发,但剩下的也要算失败(不谎报成功)")
        XCTAssertEqual(result.firstError, .unauthorized)
        let attempted = MockEmbyURLProtocol.recordedRequests().filter { $0.url.path.contains("/PlayedItems/") }
        XCTAssertEqual(attempted.count, 2, "401 之后不得继续打服务器")
    }

    func testBatchInvalidatesResponseCacheOnce() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("user_views_mixed_synthetic.json")),
            path: "/emby/Users/\(Self.userID)/Views"
        )
        stubPlayed(itemID: "E1")
        stubPlayed(itemID: "E2")
        let profile = makeProfile()
        try await credentials.saveToken(Self.token, forServer: profile.id)
        let connection = ServerConnection(
            profile: profile,
            credentials: credentials,
            session: session,
            responseCache: responseCache
        )
        _ = try await connection.userViews()

        _ = try await connection.setPlayed(itemIDs: ["E1", "E2"], played: true)

        let before = viewRequests().count
        _ = try await connection.userViews()
        XCTAssertEqual(viewRequests().count - before, 1, "批量写完缓存必须作废(重新走网络)")
    }

    func testEmptyBatchMakesNoRequest() async throws {
        let connection = try await makeConnection()

        let result = try await connection.setPlayed(itemIDs: [], played: true)

        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    // MARK: - ViewModel

    @MainActor
    func testViewModelBatchWritesAndReportsSuccess() async throws {
        stubPlayed(itemID: "E1")
        stubPlayed(itemID: "E2")
        let (viewModel, server) = try await makeViewModel()
        let episodes = try [episode("E1", played: false), episode("E2", played: false)]

        viewModel.markEpisodesPlayed(episodes, played: true, server: server)

        XCTAssertEqual(viewModel.batchProgress?.total, 2, "开始时就有进度,界面据此显示 N/M")
        try await waitUntil("批量标记结束") { viewModel.batchProgress == nil }
        XCTAssertEqual(viewModel.batchMessage, "已把 2 集标记为已看。")
    }

    @MainActor
    func testViewModelBatchReportsPartialFailure() async throws {
        stubPlayed(itemID: "E1")
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Users/\(Self.userID)/PlayedItems/E2")
        let (viewModel, server) = try await makeViewModel()
        let episodes = try [episode("E1", played: false), episode("E2", played: false)]

        viewModel.markSeasonPlayed(episodes, played: true, server: server)

        try await waitUntil("批量标记结束") { viewModel.batchProgress == nil }
        let message = try XCTUnwrap(viewModel.batchMessage)
        XCTAssertTrue(message.contains("1 集成功"), message)
        XCTAssertTrue(message.contains("1 集失败"), message)
        XCTAssertTrue(message.contains("服务器错误"), "失败原因要摆给用户,不能只说失败了")
    }

    @MainActor
    func testViewModelSkipsWriteWhenNothingToChange() async throws {
        let (viewModel, server) = try await makeViewModel()
        let episodes = try [episode("E1", played: true), episode("E2", played: true)]

        viewModel.markSeasonPlayed(episodes, played: true, server: server)

        XCTAssertNil(viewModel.batchProgress, "全都在目标状态时不该起一次批量写入")
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    /// 批量跑到一半切走条目:旧批次不能把进度 / 提示写进新页面,也不能把 `batchProgress` 卡住(新页面的批量入口会点不动)。
    @MainActor
    func testViewModelSwitchPageDuringBatchDoesNotStick() async throws {
        stubPlayed(itemID: "E1")
        stubPlayed(itemID: "E2")
        let (viewModel, server) = try await makeViewModel()
        viewModel.markSeasonPlayed(
            try [episode("E1", played: false), episode("E2", played: false)],
            played: true, server: server
        )
        XCTAssertNotNil(viewModel.batchProgress)

        // 换到另一项(真实路径会发一次详情请求;这里只关心状态清理)
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Users/\(Self.userID)/Items/OTHER")
        viewModel.load(item: try movie("OTHER"), server: server)

        XCTAssertNil(viewModel.batchProgress, "换条目必须清掉上一页的批量进度")
        XCTAssertNil(viewModel.batchMessage)

        // 旧批次跑完后,新页面还能正常发起自己的批量
        try await waitUntil("旧批次结束") {
            MockEmbyURLProtocol.recordedRequests().filter { $0.url.path.contains("/PlayedItems/") }.count == 2
        }
        stubPlayed(itemID: "E9")
        viewModel.markSeasonPlayed(try [episode("E9", played: false)], played: true, server: server)
        XCTAssertEqual(viewModel.batchProgress?.total, 1, "新页面必须能重新发起批量")
    }

    // MARK: - 辅助

    private func movie(_ id: String) throws -> EmbyItem {
        try JSONDecoder().decode(
            EmbyItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie"}"#.utf8)
        )
    }

    private func stubPlayed(itemID: String) {
        MockEmbyURLProtocol.stub(
            .json(#"{"Played":true,"PlayCount":1}"#),
            path: "/emby/Users/\(Self.userID)/PlayedItems/\(itemID)"
        )
    }

    private func viewRequests() -> [MockEmbyURLProtocol.RecordedRequest] {
        MockEmbyURLProtocol.recordedRequests().filter { $0.url.path.hasSuffix("/Views") }
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

    private func makeConnection() async throws -> ServerConnection {
        let profile = makeProfile()
        try await credentials.saveToken(Self.token, forServer: profile.id)
        return ServerConnection(profile: profile, credentials: credentials, session: session)
    }

    @MainActor
    private func makeViewModel() async throws -> (MediaDetailViewModel, ServerProfile) {
        let profile = makeProfile()
        try await credentials.saveToken(Self.token, forServer: profile.id)
        let registry = try ServerRegistry(profiles: [], credentials: credentials)
        let container = AppContainer(registry: registry, credentials: credentials, session: session)
        return (MediaDetailViewModel(container: container), profile)
    }

    private func episode(_ id: String, played: Bool?) throws -> EmbyItem {
        let userData = played.map { #","UserData":{"Played":\#($0)}"# } ?? ""
        return try JSONDecoder().decode(
            EmbyItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode"\#(userData)}"#.utf8)
        )
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
