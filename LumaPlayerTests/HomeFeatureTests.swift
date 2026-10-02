import XCTest
@testable import LumaPlayer

/// 首页:跨剧集「下一集」、按媒体库分组的「最新」(API_CONTRACT.md 3.2)。
/// 全部走 `MockEmbyURLProtocol`,零真实网络依赖。
@MainActor
final class HomeFeatureTests: XCTestCase {
    private static let userID = "USER-1"
    private static let token = "FAKE_TOKEN_0123456789"

    private var session: URLSession!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var suiteName: String!

    override func setUp() async throws {
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        suiteName = "test.LumaPlayer.home.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        try await storage.removeAll()
        storage = nil
        credentials = nil
        session = nil
    }

    /// 首页的「下一集」不带 `SeriesId`(4.1.1.0 里它是可选参数)—— 带了就只剩一部剧。
    func testNextUpAcrossSeriesOmitsSeriesID() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_episodes_synthetic.json")),
            path: "/emby/Shows/NextUp"
        )
        let connection = try await makeConnection()

        let items = try await connection.nextUp(limit: 20)

        XCTAssertEqual(items.count, 3)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "Shows/NextUp"))
        XCTAssertNil(queryValue(request.url, "SeriesId"))
        XCTAssertEqual(queryValue(request.url, "UserId"), Self.userID)
        XCTAssertEqual(queryValue(request.url, "Limit"), "20")
    }

    func testNextUpQueryStillSendsSeriesIDWhenGiven() {
        let query = EmbyNextUpQuery(userID: "U", seriesID: "S")
        XCTAssertEqual(query.queryItems, [EmbyQueryItem("UserId", "U"), EmbyQueryItem("SeriesId", "S")])
    }

    /// 音乐 / 有声书 / 直播不在首版范围(ARCHITECTURE.md 2.4),首页不给它们「最新」行;
    /// CollectionType 为 null 的混合库照常给(不猜它是什么库)。
    func testLatestRowsOnlyForVideoLibraries() throws {
        let views = try [
            view("V1", "movies"), view("V2", "tvshows"), view("V3", "music"),
            view("V4", nil), view("V5", "books"), view("V6", "livetv"),
        ]
        XCTAssertEqual(HomeViewModel.latestViews(in: views).map(\.id), ["V1", "V2", "V4"])
    }

    // MARK: - 一次加载(避免重复请求)

    /// 一次 `load`:媒体库列表、继续观看、下一集各请求**一次**,列表回来后每个视频库
    /// 的「最新」各请求一次(2026-09-24 诊断日志里同一 NextUp 1 秒内打了两遍,别回退)。
    func testLoadRequestsEachSectionOnce() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("user_views_mixed_synthetic.json")),
            path: "/emby/Users/USER-1/Views"
        )
        let (viewModel, server) = try await makeHomeViewModel()

        viewModel.load(server: server)
        try await Task.sleep(for: .milliseconds(50))

        let views = try XCTUnwrap(viewModel.sections(for: server.id).views.value)
        XCTAssertEqual(views.count, 3)
        let paths = MockEmbyURLProtocol.recordedRequests().map(\.url.path)
        XCTAssertEqual(paths.filter { $0.hasSuffix("/Views") }.count, 1)
        XCTAssertEqual(paths.filter { $0.hasSuffix("/Items/Resume") }.count, 1)
        XCTAssertEqual(paths.filter { $0.hasSuffix("/Shows/NextUp") }.count, 1)
        let latestParents = MockEmbyURLProtocol.recordedRequests()
            .filter { $0.url.path.hasSuffix("/Items/Latest") }
            .compactMap { queryValue($0.url, "ParentId") }
        XCTAssertEqual(Set(latestParents), Set(views.map(\.id)))
        XCTAssertEqual(latestParents.count, views.count)
    }

    // MARK: - 「下一集」行失败即隐藏(Q31 方案 B)

    func testNextUpRowHiddenOnlyWhenFailed() {
        XCTAssertFalse(HomeViewModel.showsNextUpRow(.failed(LoadFailure(.unexpectedStatus(400)))))
        XCTAssertTrue(HomeViewModel.showsNextUpRow(.loading))
        XCTAssertTrue(HomeViewModel.showsNextUpRow(.loaded([])))
    }

    /// 「下一集」被隐藏时不能挡住空服务器提示。
    func testFailedNextUpDoesNotBlockEmptyPlaceholder() {
        let failed = LoadState<[EmbyItem]>.failed(LoadFailure(.unexpectedStatus(400)))
        XCTAssertTrue(HomeViewModel.isEverythingEmpty(
            views: .loaded([]), resume: .loaded([]), nextUp: failed, latest: [.loaded([])]))
        XCTAssertFalse(HomeViewModel.isEverythingEmpty(
            views: .loaded([]), resume: .loading, nextUp: failed, latest: []))
        XCTAssertFalse(HomeViewModel.isEverythingEmpty(
            views: .loaded([]), resume: .failed(LoadFailure(.unexpectedStatus(400))), nextUp: .loaded([]), latest: []))
    }

    /// 媒体库列表还没回来时不能提前报「没有内容」:「最新」的行要等它回来才知道有几行。
    func testEmptyPlaceholderWaitsForViews() {
        XCTAssertFalse(HomeViewModel.isEverythingEmpty(
            views: .loading, resume: .loaded([]), nextUp: .loaded([]), latest: []))
        XCTAssertTrue(HomeViewModel.isEverythingEmpty(
            views: .failed(LoadFailure(.unexpectedStatus(500))), resume: .loaded([]), nextUp: .loaded([]), latest: []))
    }

    // MARK: - 移出继续观看(API_CONTRACT.md 5.7)

    /// 移出与放回**都走 POST**,方向由查询参数 `Hide` 表达;
    /// ⚠️ 不带 `Hide` 时服务端返回 200 但不生效(本地 4.9.5.0 实测)。
    func testHideFromResumeSendsPOSTWithHideTrue() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"PlaybackPositionTicks":15000000000}"#),
            path: "/emby/Users/USER-1/Items/ITEM-9/HideFromResume"
        )
        let connection = try await makeConnection()

        let userData = try await connection.setHiddenFromResume(itemID: "ITEM-9", hidden: true)

        XCTAssertEqual(userData.playbackPositionTicks, 15000000000)
        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "Items/ITEM-9/HideFromResume"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(queryValue(request.url, "Hide"), "true")
        XCTAssertEqual(request.header("X-Emby-Token"), Self.token)
    }

    /// 放回继续观看:`Hide=false`,不是 DELETE(5.5 / 5.6 那种「POST 设上、DELETE 取消」不适用)。
    func testPutBackToResumeSendsHideFalse() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"PlaybackPositionTicks":15000000000}"#),
            path: "/emby/Users/USER-1/Items/ITEM-9/HideFromResume"
        )
        let connection = try await makeConnection()

        _ = try await connection.setHiddenFromResume(itemID: "ITEM-9", hidden: false)

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "Items/ITEM-9/HideFromResume"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(queryValue(request.url, "Hide"), "false")
    }

    /// 乐观更新:点完立刻从列表里消失,不等服务端往返。
    func testHideFromResumeRemovesItemImmediately() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_episodes_synthetic.json")),
            path: "/emby/Users/USER-1/Items/Resume"
        )
        MockEmbyURLProtocol.stub(
            .json(#"{"PlaybackPositionTicks":15000000000}"#),
            path: "/emby/Users/USER-1/Items/00000000-0000-0000-0000-000000000202/HideFromResume"
        )
        let (viewModel, server) = try await makeHomeViewModel()
        viewModel.load(server: server)
        try await Task.sleep(for: .milliseconds(20))
        let before = try XCTUnwrap(loadedResumeItems(viewModel, server: server))
        XCTAssertEqual(before.count, 3)

        viewModel.hideFromResume(before[1], server: server)

        let after = try XCTUnwrap(loadedResumeItems(viewModel, server: server))
        XCTAssertEqual(after.map(\.id), [before[0].id, before[2].id])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(viewModel.resumeActionError)
    }

    /// 失败必须让用户知道:列表按原样放回 + 给出提示(硬规则:不静默吞错)。
    func testHideFromResumeRollsBackWithMessageOnFailure() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_episodes_synthetic.json")),
            path: "/emby/Users/USER-1/Items/Resume"
        )
        MockEmbyURLProtocol.stub(
            .status(500),
            path: "/emby/Users/USER-1/Items/00000000-0000-0000-0000-000000000202/HideFromResume"
        )
        let (viewModel, server) = try await makeHomeViewModel()
        viewModel.load(server: server)
        try await Task.sleep(for: .milliseconds(20))
        let before = try XCTUnwrap(loadedResumeItems(viewModel, server: server))

        viewModel.hideFromResume(before[1], server: server)
        try await Task.sleep(for: .milliseconds(20))

        let after = try XCTUnwrap(loadedResumeItems(viewModel, server: server))
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertNotNil(viewModel.resumeActionError)
        XCTAssertTrue(viewModel.updatingResumeIDs.isEmpty)
    }

    /// issue #3:已有内容时再次 load 不能回退到 loading;刷新失败也保留旧内容。
    func testReloadKeepsLoadedContentInsteadOfFallingBackToLoading() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_episodes_synthetic.json")),
            path: "/emby/Users/USER-1/Items/Resume"
        )
        let (viewModel, server) = try await makeHomeViewModel()
        viewModel.load(server: server)
        try await Task.sleep(for: .milliseconds(20))
        let before = try XCTUnwrap(loadedResumeItems(viewModel, server: server))

        // 第二次 load:同步返回时状态仍是 loaded(不闪 loading)
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Users/USER-1/Items/Resume")
        viewModel.load(server: server)
        XCTAssertEqual(try loadedResumeItems(viewModel, server: server).map(\.id), before.map(\.id))

        // 刷新失败:保留旧内容,不换成错误态
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(try loadedResumeItems(viewModel, server: server).map(\.id), before.map(\.id))
    }

    /// issue #3:A 加载完 → 切到 B → 切回 A,A 的内容还在,不回退到 loading;
    /// 且 B 看不到 A 的内容(不串台)。
    func testSwitchingBackToLoadedServerKeepsItsContent() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_episodes_synthetic.json")),
            path: "/emby/Users/USER-1/Items/Resume"
        )
        MockEmbyURLProtocol.stub(
            .json(#"{"Items":[],"TotalRecordCount":0}"#),
            host: "emby-b.test",
            path: "/emby/Users/USER-1/Items/Resume"
        )
        let (viewModel, serverA) = try await makeHomeViewModel()
        let serverB = try await makeServer(host: "emby-b.test")
        viewModel.load(server: serverA)
        try await Task.sleep(for: .milliseconds(20))
        let before = try XCTUnwrap(loadedResumeItems(viewModel, server: serverA))

        viewModel.load(server: serverB)
        guard case .loading = viewModel.sections(for: serverB.id).resume else {
            return XCTFail("B 首次加载应是 loading,不能露出 A 的内容")
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(try loadedResumeItems(viewModel, server: serverB).isEmpty)

        // 切回 A:同步返回时就是 A 上次的内容
        viewModel.load(server: serverA)
        XCTAssertEqual(try loadedResumeItems(viewModel, server: serverA).map(\.id), before.map(\.id))
    }

    /// issue #3:媒体库入口列表同样按服务器保留,切回来不先变成 loading。
    func testViewsKeptPerServer() async throws {
        let views = try FixtureLoader.json("user_views_mixed_synthetic.json")
        MockEmbyURLProtocol.stub(.json(views), path: "/emby/Users/USER-1/Views")
        MockEmbyURLProtocol.stub(.json(views), host: "emby-b.test", path: "/emby/Users/USER-1/Views")
        let (viewModel, serverA) = try await makeHomeViewModel()
        let serverB = try await makeServer(host: "emby-b.test")
        viewModel.load(server: serverA)
        try await Task.sleep(for: .milliseconds(20))
        let loadedA = try XCTUnwrap(viewModel.sections(for: serverA.id).views.value)

        viewModel.load(server: serverB)
        guard case .loading = viewModel.sections(for: serverB.id).views else {
            return XCTFail("B 首次加载应是 loading")
        }
        try await Task.sleep(for: .milliseconds(20))

        viewModel.load(server: serverA)
        XCTAssertEqual(viewModel.sections(for: serverA.id).views.value?.map(\.id), loadedA.map(\.id))
    }

    // MARK: - 辅助

    private func loadedResumeItems(_ viewModel: HomeViewModel, server: ServerProfile) throws -> [EmbyItem] {
        let state = viewModel.sections(for: server.id).resume
        guard case .loaded(let items) = state else {
            XCTFail("继续观看应在加载完成状态,实际 \(state)")
            throw CancellationError()
        }
        return items
    }

    private func makeHomeViewModel() async throws -> (HomeViewModel, ServerProfile) {
        let profile = try await makeServer(host: "emby.test")
        // UserDefaults 不是 Sendable,不能在 MainActor 上构造好再送进 actor 的 init;
        // 用默认参数(在 actor 一侧求值)。这个 registry 只用来装配 container,不落库,
        // 所以不必自带 suite。
        let registry = ServerRegistry(profiles: [], credentials: credentials)
        let container = AppContainer(registry: registry, credentials: credentials, session: session)
        return (HomeViewModel(container: container), profile)
    }

    private func makeServer(host: String) async throws -> ServerProfile {
        let profile = ServerProfile(
            displayName: host,
            baseURL: testURL("https://\(host)"),
            apiPathPrefix: "/emby",
            userID: Self.userID,
            username: "testuser",
            deviceID: "DEVICE-UUID-1"
        )
        try await credentials.saveToken(Self.token, forServer: profile.id)
        return profile
    }

    private func view(_ id: String, _ type: String?) throws -> EmbyView {
        let typeJSON = type.map { #","CollectionType":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(
            EmbyView.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)"\#(typeJSON)}"#.utf8)
        )
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
