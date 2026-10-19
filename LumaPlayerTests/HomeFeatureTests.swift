import XCTest
@testable import LumaPlayer

/// 首页:继续观看、按媒体库分组的「最新」(API_CONTRACT.md 3.2)。
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

    func testNextUpQueryStillSendsSeriesIDWhenGiven() {
        let query = EmbyNextUpQuery(userID: "U", seriesID: "S")
        XCTAssertEqual(query.queryItems, [EmbyQueryItem("UserId", "U"), EmbyQueryItem("SeriesId", "S")])
    }

    /// 音乐 / 有声书 / 直播不在首版范围(非目标清单见 README.md「已知限制」),首页不给它们「最新」行;
    /// CollectionType 为 null 的混合库照常给(不猜它是什么库)。
    func testLatestRowsOnlyForVideoLibraries() throws {
        let views = try [
            view("V1", "movies"), view("V2", "tvshows"), view("V3", "music"),
            view("V4", nil), view("V5", "books"), view("V6", "livetv"),
        ]
        XCTAssertEqual(HomeViewModel.latestViews(in: views).map(\.id), ["V1", "V2", "V4"])
    }

    // MARK: - 一次加载(避免重复请求)

    /// 一次 `load`:媒体库列表、继续观看、hero 的随机推荐各请求**一次**,
    /// 列表回来后每个视频库的「最新」各请求一次(2026-09-24 诊断日志里同一 NextUp
    /// 1 秒内打了两遍,别回退)。跨剧集的 NextUp 已随「下一集」行一起去掉
    /// (PITFALLS.md Q31),首页不再请求它。
    func testLoadRequestsEachSectionOnce() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("user_views_mixed_synthetic.json")),
            path: "/emby/Users/USER-1/Views"
        )
        let (viewModel, server) = try await makeHomeViewModel()

        viewModel.load(server: server)
        await viewModel.waitUntilIdle()

        let views = try XCTUnwrap(viewModel.sections(for: server.id).views.state.value)
        XCTAssertEqual(views.count, 3)
        let requests = MockEmbyURLProtocol.recordedRequests()
        let paths = requests.map(\.url.path)
        XCTAssertEqual(paths.filter { $0.hasSuffix("/Views") }.count, 1)
        XCTAssertEqual(paths.filter { $0.hasSuffix("/Items/Resume") }.count, 1)
        XCTAssertEqual(paths.filter { $0.hasSuffix("/Shows/NextUp") }.count, 0)
        let latestParents = requests
            .filter { $0.url.path.hasSuffix("/Items/Latest") }
            .compactMap { queryValue($0.url, "ParentId") }
        XCTAssertEqual(Set(latestParents), Set(views.map(\.id)))
        XCTAssertEqual(latestParents.count, views.count)

        // hero 的随机推荐:一次,参数就是「随机 + 没看过 + 顶层影剧」。
        // ⛔ 不带 ParentId —— 推荐池要跨全部媒体库,限定成某一个库就只是那个库的随机
        let recommendations = requests.filter { $0.url.path.hasSuffix("/Users/USER-1/Items") }
        XCTAssertEqual(recommendations.count, 1)
        let pick = try XCTUnwrap(recommendations.first)
        XCTAssertEqual(queryValue(pick.url, "Recursive"), "true")
        XCTAssertEqual(queryValue(pick.url, "IncludeItemTypes"), "Movie,Series")
        XCTAssertEqual(queryValue(pick.url, "SortBy"), "Random")
        XCTAssertEqual(queryValue(pick.url, "Filters"), "IsUnplayed")
        // hero 要显示简介与类型,列表接口默认不给,必须显式要;
        // ProviderIds 供弹幕匹配的 TMDB 降级层用(`DANMAKU.md` §3)。
        XCTAssertEqual(queryValue(pick.url, "Fields"), "Overview,Genres,ProviderIds")
        XCTAssertEqual(queryValue(pick.url, "Limit"), String(HomeViewModel.recommendationPoolLimit))
        XCTAssertNil(queryValue(pick.url, "ParentId"))
    }

    // MARK: - hero 的随机推荐(`ServerConnection.recommendations`)

    /// 推荐落到 `Sections.recommended`,并成为 hero 的首选
    func testRecommendationsFeedHero() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"Items":[{"Id":"REC-1","Name":"推荐剧","Type":"Series","BackdropImageTags":["b1"]},{"Id":"REC-2","Name":"推荐片","Type":"Movie","BackdropImageTags":["b2"]}],"TotalRecordCount":2}"#),
            path: "/emby/Users/USER-1/Items"
        )
        let (viewModel, server) = try await makeHomeViewModel()

        viewModel.load(server: server)
        await viewModel.waitUntilIdle()

        let expected = [
            try recItem("REC-1", "推荐剧", "Series", "b1"),
            try recItem("REC-2", "推荐片", "Movie", "b2"),
        ]
        XCTAssertEqual(heroPick(viewModel, server: server), .items(expected))
    }

    /// 推荐请求失败时 hero 退回「继续观看」那张,不是空着 ——
    /// 「一条请求打不通就整块 hero 消失」是首屏最贵的一种回归。
    /// 且退路只给**一张**:轮播要退化成静默单张(见 `HomeHeroPickTests`)
    func testRecommendationFailureFallsBackToResumeHero() async throws {
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Users/USER-1/Items")
        MockEmbyURLProtocol.stub(
            .json(#"{"Items":[{"Id":"R-1","Name":"看了一半","Type":"Movie","BackdropImageTags":["rb"]}],"TotalRecordCount":1}"#),
            path: "/emby/Users/USER-1/Items/Resume"
        )
        MockEmbyURLProtocol.stub(
            .json(#"{"Items":[],"TotalRecordCount":0}"#),
            path: "/emby/Users/USER-1/Views"
        )
        let (viewModel, server) = try await makeHomeViewModel()

        viewModel.load(server: server)
        await viewModel.waitUntilIdle()

        let expected = [try recItem("R-1", "看了一半", "Movie", "rb")]
        XCTAssertEqual(heroPick(viewModel, server: server), .items(expected))
    }

    /// 刷新时复用「最新」的行对象:每行视图只观察自己那一个 `Row`,
    /// 整体换成新对象会让所有行(和整页)重新求值。
    func testReloadReusesLatestRowObjects() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("user_views_mixed_synthetic.json")),
            path: "/emby/Users/USER-1/Views"
        )
        let (viewModel, server) = try await makeHomeViewModel()
        viewModel.load(server: server)
        await viewModel.waitUntilIdle()
        let before = viewModel.sections(for: server.id).latest
        XCTAssertFalse(before.isEmpty)

        viewModel.load(server: server)
        await viewModel.waitUntilIdle()

        let after = viewModel.sections(for: server.id).latest
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        for (id, row) in before {
            XCTAssertTrue(after[id] === row, "行 \(id) 被换成了新对象")
        }
    }

    // MARK: - 「最新」并发上限

    /// 媒体库 20+ 时不能把「最新」一次全压到服务器:同时在途不超过上限,且每个都跑到。
    func testRunLimitedNeverExceedsMaxConcurrent() async {
        let probe = ConcurrencyProbe()
        var finished: [Int] = []

        await HomeViewModel.runLimited(count: 23, maxConcurrent: 4) { index in
            await probe.enter()
            try? await Task.sleep(for: .milliseconds(5))
            await probe.leave()
            return index
        } onResult: { index, value in
            XCTAssertEqual(index, value)
            finished.append(index)
        }

        let peak = await probe.peak
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertGreaterThan(peak, 1, "应当并行,不是退化成串行")
        XCTAssertEqual(finished.sorted(), Array(0..<23))
    }

    /// 切服务器 / 刷新会取消上一轮:取消后排队中的不再发出。
    func testRunLimitedStopsLaunchingAfterCancellation() async throws {
        let probe = ConcurrencyProbe()
        let task = Task { @MainActor in
            await HomeViewModel.runLimited(count: 20, maxConcurrent: 2) { index in
                await probe.enter()
                try? await Task.sleep(for: .milliseconds(20))
                await probe.leave()
                return index
            } onResult: { _, _ in }
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await task.value

        let started = await probe.started
        XCTAssertLessThan(started, 20)
    }

    // MARK: - 整页空状态

    /// 所有分区都加载完且为空才算空;还在加载或失败的分区不算空。
    func testEmptyPlaceholderNeedsEverySectionLoadedAndEmpty() {
        XCTAssertTrue(HomeViewModel.isEverythingEmpty(
            views: .loaded([]), resume: .loaded([]), latest: [.loaded([])]))
        XCTAssertFalse(HomeViewModel.isEverythingEmpty(
            views: .loaded([]), resume: .loading, latest: []))
        XCTAssertFalse(HomeViewModel.isEverythingEmpty(
            views: .loaded([]), resume: .failed(LoadFailure(.unexpectedStatus(400))), latest: []))
    }

    /// 媒体库列表还没回来时不能提前报「没有内容」:「最新」的行要等它回来才知道有几行。
    func testEmptyPlaceholderWaitsForViews() {
        XCTAssertFalse(HomeViewModel.isEverythingEmpty(
            views: .loading, resume: .loaded([]), latest: []))
        XCTAssertTrue(HomeViewModel.isEverythingEmpty(
            views: .failed(LoadFailure(.unexpectedStatus(500))), resume: .loaded([]), latest: []))
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
        await viewModel.waitUntilIdle()
        let before = try XCTUnwrap(loadedResumeItems(viewModel, server: server))
        XCTAssertEqual(before.count, 3)

        viewModel.hideFromResume(before[1], server: server)

        let after = try XCTUnwrap(loadedResumeItems(viewModel, server: server))
        XCTAssertEqual(after.map(\.id), [before[0].id, before[2].id])
        await viewModel.waitUntilIdle()
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
        await viewModel.waitUntilIdle()
        let before = try XCTUnwrap(loadedResumeItems(viewModel, server: server))

        viewModel.hideFromResume(before[1], server: server)
        await viewModel.waitUntilIdle()

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
        await viewModel.waitUntilIdle()
        let before = try XCTUnwrap(loadedResumeItems(viewModel, server: server))

        // 第二次 load:同步返回时状态仍是 loaded(不闪 loading)
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Users/USER-1/Items/Resume")
        viewModel.load(server: server)
        XCTAssertEqual(try loadedResumeItems(viewModel, server: server).map(\.id), before.map(\.id))

        // 刷新失败:保留旧内容,不换成错误态
        await viewModel.waitUntilIdle()
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
        await viewModel.waitUntilIdle()
        let before = try XCTUnwrap(loadedResumeItems(viewModel, server: serverA))

        viewModel.load(server: serverB)
        guard case .loading = viewModel.sections(for: serverB.id).resume.state else {
            return XCTFail("B 首次加载应是 loading,不能露出 A 的内容")
        }
        await viewModel.waitUntilIdle()
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
        await viewModel.waitUntilIdle()
        let loadedA = try XCTUnwrap(viewModel.sections(for: serverA.id).views.state.value)

        viewModel.load(server: serverB)
        guard case .loading = viewModel.sections(for: serverB.id).views.state else {
            return XCTFail("B 首次加载应是 loading")
        }
        await viewModel.waitUntilIdle()

        viewModel.load(server: serverA)
        XCTAssertEqual(viewModel.sections(for: serverA.id).views.state.value?.map(\.id), loadedA.map(\.id))
    }

    // MARK: - 辅助

    /// 按当前各行的状态算一次 hero 该铺什么 —— `HomeView.HomeHeroSlot` 走的是同一个入口
    private func heroPick(_ viewModel: HomeViewModel, server: ServerProfile) -> HomeViewModel.HeroPick {
        let sections = viewModel.sections(for: server.id)
        return HomeViewModel.heroPick(
            recommended: sections.recommended.state,
            views: sections.views.state,
            resume: sections.resume.state,
            latest: { sections.latest[$0.id]?.state ?? .idle }
        )
    }

    /// 造一条带背景图的 Emby 条目(推荐 / 续播的断言都要背景图才上得了 hero)
    private func recItem(_ id: String, _ name: String, _ type: String, _ backdropTag: String) throws -> EmbyItem {
        try JSONDecoder().decode(
            EmbyItem.self,
            from: Data(
                #"{"Id":"\#(id)","Name":"\#(name)","Type":"\#(type)","BackdropImageTags":["\#(backdropTag)"]}"#.utf8
            )
        )
    }

    private func loadedResumeItems(_ viewModel: HomeViewModel, server: ServerProfile) throws -> [EmbyItem] {
        let state = viewModel.sections(for: server.id).resume.state
        guard case .loaded(let items) = state else {
            XCTFail("继续观看应在加载完成状态,实际 \(state)")
            // 只为中止当前用例;别用 CancellationError,会被误读成加载任务被取消
            throw ResumeNotLoaded()
        }
        return items
    }

    private struct ResumeNotLoaded: Error {}

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

/// 记录同时在跑的任务数峰值与累计启动数
private actor ConcurrencyProbe {
    private(set) var peak = 0
    private(set) var started = 0
    private var running = 0

    func enter() {
        running += 1
        started += 1
        peak = max(peak, running)
    }

    func leave() {
        running -= 1
    }
}
