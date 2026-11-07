import XCTest
@testable import LumaPlayer

/// 首页:继续观看、按媒体库分组的「最新」(API_CONTRACT.md 3.2)。全部走 `MockEmbyURLProtocol`。
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

    /// 音乐 / 有声书 / 直播不给「最新」行;CollectionType 为 null 的混合库照常给(不猜库类型)。
    func testLatestRowsOnlyForVideoLibraries() throws {
        let views = try [
            view("V1", "movies"), view("V2", "tvshows"), view("V3", "music"),
            view("V4", nil), view("V5", "books"), view("V6", "livetv"),
        ]
        XCTAssertEqual(HomeViewModel.latestViews(in: views).map(\.id), ["V1", "V2", "V4"])
    }

    // MARK: - 一次加载(避免重复请求)

    /// 一次 `load`:媒体库列表、继续观看、hero 推荐各请求一次,每个视频库的「最新」各一次。
    /// ⛔ 首页不请求跨剧集 NextUp(PITFALLS.md Q31)。
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
        // 「最新」行出现在屏幕上才请求(这里模拟每行都出现)
        for view in HomeViewModel.latestViews(in: views) {
            viewModel.latestRowAppeared(view.id, server: server)
        }
        await viewModel.waitUntilIdle()
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

        // hero 推荐:随机 + 没看过 + 顶层影剧;⛔ 不带 ParentId(推荐池跨全部媒体库)
        let recommendations = requests.filter { $0.url.path.hasSuffix("/Users/USER-1/Items") }
        XCTAssertEqual(recommendations.count, 1)
        let pick = try XCTUnwrap(recommendations.first)
        XCTAssertEqual(queryValue(pick.url, "Recursive"), "true")
        XCTAssertEqual(queryValue(pick.url, "IncludeItemTypes"), "Movie,Series")
        XCTAssertEqual(queryValue(pick.url, "SortBy"), "Random")
        XCTAssertEqual(queryValue(pick.url, "Filters"), "IsUnplayed")
        // 列表接口默认不给简介与类型,须显式要;ProviderIds 供弹幕的 TMDB 降级层(`DANMAKU.md` §3)
        XCTAssertEqual(queryValue(pick.url, "Fields"), "Overview,Genres,ProviderIds")
        XCTAssertEqual(queryValue(pick.url, "Limit"), String(HomeViewModel.recommendationPoolLimit))
        XCTAssertNil(queryValue(pick.url, "ParentId"))
    }

    /// 「最新」只给出现在屏幕上的行请求,每轮每行最多一次;没出现的行不发。
    func testLatestRowsAreRequestedOnlyWhenTheyAppear() async throws {
        let ids = (1...6).map { "V\($0)" }
        let items = ids.map { #"{"Id":"\#($0)","Name":"\#($0)","CollectionType":"movies"}"# }
        MockEmbyURLProtocol.stub(
            .json(#"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":\#(ids.count)}"#),
            path: "/emby/Users/USER-1/Views"
        )
        MockEmbyURLProtocol.stub(.json(#"[{"Id":"M1","Name":"M1","Type":"Movie"}]"#), path: "/emby/Users/USER-1/Items/Latest")
        let (viewModel, server, container) = try await makeHomeViewModelWithContainer()

        viewModel.load(server: server)
        await viewModel.waitUntilIdle()
        XCTAssertTrue(latestParents().isEmpty, "没出现的行不请求")

        viewModel.latestRowAppeared("V1", server: server)
        viewModel.latestRowAppeared("V2", server: server)
        viewModel.latestRowAppeared("V1", server: server)
        await viewModel.waitUntilIdle()
        XCTAssertEqual(latestParents().sorted(), ["V1", "V2"], "出现才请求,同一轮不重复")

        let sections = viewModel.sections(for: server.id)
        XCTAssertEqual(sections.latest["V1"]?.state.value?.map(\.id), ["M1"])
        guard case .idle? = sections.latest["V3"]?.state else {
            return XCTFail("没滚到的行保持 idle")
        }

        // 新一轮(⌘R = 先作废缓存再加载):仍在屏幕上的行直接重取,不等再次出现
        viewModel.latestRowDisappeared("V2", server: server)
        await container.responseCache.invalidate(serverID: server.id)
        viewModel.load(server: server, userInitiated: true)
        await viewModel.waitUntilIdle()
        XCTAssertEqual(latestParents().filter { $0 == "V1" }.count, 2)
        XCTAssertEqual(latestParents().filter { $0 == "V2" }.count, 1)
        await container.responseCache.purge(serverID: server.id)
    }

    // MARK: - 请求克制

    /// 返回首页(`appear` 重跑)时没有任何变化:不重新加载,行内容原样。
    func testAppearAgainWithoutChangesDoesNotReload() async throws {
        try stubHomeSections()
        let (viewModel, server, container) = try await makeHomeViewModelWithContainer()
        await viewModel.appear(server: server, refreshToken: 0)
        await viewModel.waitUntilIdle()
        XCTAssertFalse(try loadedResumeItems(viewModel, server: server).isEmpty)
        // 哨兵:真的重新加载的话(哪怕打的是缓存)会被换回服务端那份
        viewModel.sections(for: server.id).resume.replace(with: .loaded([]))
        let before = MockEmbyURLProtocol.recordedRequests().count

        await viewModel.appear(server: server, refreshToken: 0)
        await viewModel.waitUntilIdle()

        XCTAssertTrue(try loadedResumeItems(viewModel, server: server).isEmpty)
        XCTAssertEqual(MockEmbyURLProtocol.recordedRequests().count, before)
        await container.responseCache.purge(serverID: server.id)
    }

    /// 缓存被作废(写操作 / 播放)后再回到首页:静默重新加载。
    func testAppearAfterCacheInvalidationReloads() async throws {
        try stubHomeSections()
        let (viewModel, server, container) = try await makeHomeViewModelWithContainer()
        await viewModel.appear(server: server, refreshToken: 0)
        await viewModel.waitUntilIdle()
        let before = resumeRequestCount()

        await container.responseCache.invalidate(serverID: server.id)
        await viewModel.appear(server: server, refreshToken: 0)
        await viewModel.waitUntilIdle()

        XCTAssertEqual(resumeRequestCount(), before + 1)
        await container.responseCache.purge(serverID: server.id)
    }

    /// 缓存作废后服务器出错:新开的首页(内存里什么都没有)也先显示本地的旧数据,不是错误卡片。
    func testStaleCacheFillsRowsWhenServerFails() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_episodes_synthetic.json")),
            path: "/emby/Users/USER-1/Items/Resume"
        )
        let (viewModel, server, container) = try await makeHomeViewModelWithContainer()
        viewModel.load(server: server)
        await viewModel.waitUntilIdle()
        let before = try XCTUnwrap(loadedResumeItems(viewModel, server: server))

        await container.responseCache.invalidate(serverID: server.id)
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Users/USER-1/Items/Resume")
        let reopened = HomeViewModel(container: container)
        reopened.load(server: server)
        await reopened.waitUntilIdle()

        XCTAssertEqual(try loadedResumeItems(reopened, server: server).map(\.id), before.map(\.id))
        XCTAssertFalse(reopened.isLoading)
        await container.responseCache.purge(serverID: server.id)
    }

    // MARK: - hero 的随机推荐(`ServerConnection.recommendations`)

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

    /// 推荐失败时 hero 退回「继续观看」那一张(轮播退化成静默单张,见 `HomeHeroPickTests`),⛔ 不让整块 hero 消失。
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

    /// 每行视图只观察自己的 `Row`,整体换新对象会让整页重新求值。
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

    /// 媒体库列表没回来前不知道「最新」有几行,不能提前报空。
    func testEmptyPlaceholderWaitsForViews() {
        XCTAssertFalse(HomeViewModel.isEverythingEmpty(
            views: .loading, resume: .loaded([]), latest: []))
        XCTAssertTrue(HomeViewModel.isEverythingEmpty(
            views: .failed(LoadFailure(.unexpectedStatus(500))), resume: .loaded([]), latest: []))
    }

    // MARK: - 移出继续观看(API_CONTRACT.md 5.7)

    /// 移出与放回都走 POST,方向由 `Hide` 表达;不带 `Hide` 时服务端返回 200 但不生效(本地 4.9.5.0)。
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

    /// `Hide=false`,不是 DELETE(不同于 5.5 / 5.6 的「POST 设、DELETE 取消」)。
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

    func testReloadKeepsLoadedContentInsteadOfFallingBackToLoading() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_episodes_synthetic.json")),
            path: "/emby/Users/USER-1/Items/Resume"
        )
        let (viewModel, server) = try await makeHomeViewModel()
        viewModel.load(server: server)
        await viewModel.waitUntilIdle()
        let before = try XCTUnwrap(loadedResumeItems(viewModel, server: server))

        // 同步返回时仍是 loaded(不闪 loading)
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Users/USER-1/Items/Resume")
        viewModel.load(server: server)
        XCTAssertEqual(try loadedResumeItems(viewModel, server: server).map(\.id), before.map(\.id))

        await viewModel.waitUntilIdle()
        XCTAssertEqual(try loadedResumeItems(viewModel, server: server).map(\.id), before.map(\.id))
    }

    /// 按服务器保留首页内容:切回不闪 loading,也不串台。
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

        viewModel.load(server: serverA)
        XCTAssertEqual(try loadedResumeItems(viewModel, server: serverA).map(\.id), before.map(\.id))
    }

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

    /// 与 `HomeView.HomeHeroSlot` 走同一入口
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

    private func stubHomeSections() throws {
        MockEmbyURLProtocol.stub(.json(#"{"Items":[],"TotalRecordCount":0}"#), path: "/emby/Users/USER-1/Views")
        MockEmbyURLProtocol.stub(.json(#"{"Items":[],"TotalRecordCount":0}"#), path: "/emby/Users/USER-1/Items")
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("shows_episodes_synthetic.json")),
            path: "/emby/Users/USER-1/Items/Resume"
        )
    }

    private func latestParents() -> [String] {
        MockEmbyURLProtocol.recordedRequests()
            .filter { $0.url.path.hasSuffix("/Items/Latest") }
            .compactMap { queryValue($0.url, "ParentId") }
    }

    private func resumeRequestCount() -> Int {
        MockEmbyURLProtocol.recordedRequests().filter { $0.url.path.hasSuffix("/Items/Resume") }.count
    }

    private func makeHomeViewModel() async throws -> (HomeViewModel, ServerProfile) {
        let (viewModel, profile, _) = try await makeHomeViewModelWithContainer()
        return (viewModel, profile)
    }

    private func makeHomeViewModelWithContainer() async throws -> (HomeViewModel, ServerProfile, AppContainer) {
        let profile = try await makeServer(host: "emby.test")
        // UserDefaults 不是 Sendable,不能在 MainActor 上构造后送进 actor 的 init,用默认参数(actor 侧求值);registry 不落库。
        let registry = ServerRegistry(profiles: [], credentials: credentials)
        // 首页推荐开关读 preferences;不注入会读到宿主 App 的真实设置
        let container = AppContainer(
            registry: registry, credentials: credentials, session: session,
            preferences: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        return (HomeViewModel(container: container), profile, container)
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
