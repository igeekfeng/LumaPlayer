import XCTest
@testable import LumaPlayer

/// 「显示首页推荐」开关(`HomeAppearancePreferences`):关掉后跨重启保持、不发推荐请求、hero 完全不画。
/// ⛔ 关掉时不退回「继续观看 / 各库最新」:那条退路只是请求失败时的容错,不是用户的选择。
@MainActor
final class HomeAppearancePreferencesTests: XCTestCase {
    private static let userID = "USER-1"
    private static let token = "FAKE_TOKEN_0123456789"

    private static let oneRecommendation = #"""
    {"Items":[{"Id":"REC-1","Name":"推荐剧","Type":"Series","BackdropImageTags":["b1"]}],"TotalRecordCount":1}
    """#

    private var session: URLSession!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var container: AppContainer!

    override func setUp() async throws {
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        suiteName = "test.LumaPlayer.homeAppearance.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        container = nil
        try await storage.removeAll()
        storage = nil
        credentials = nil
        session = nil
    }

    // MARK: - 偏好本身

    /// 默认开,老用户升级后首屏不会突然少一块。
    func testDefaultsToShowingRecommendations() {
        let store = HomeAppearancePreferences(defaults: defaults)
        XCTAssertTrue(store.showsHeroRecommendations)
        XCTAssertTrue(store.isDefault)
    }

    func testOffSurvivesReopening() {
        let store = HomeAppearancePreferences(defaults: defaults)
        store.showsHeroRecommendations = false
        XCTAssertFalse(store.isDefault)

        let reopened = HomeAppearancePreferences(defaults: defaults)
        XCTAssertFalse(reopened.showsHeroRecommendations)
    }

    /// `bool(forKey:)` 读字符串值会返回 false,「没存过 / 存坏了」⛔ 不能当成「关过」。
    func testGarbageValueFallsBackToDefault() {
        defaults.set("off", forKey: HomeAppearancePreferences.Key.showsHeroRecommendations)
        XCTAssertTrue(HomeAppearancePreferences(defaults: defaults).showsHeroRecommendations)
    }

    // MARK: - 关掉时不发推荐请求

    /// 只少 `/Users/{uid}/Items` 那个推荐查询,其余分区照常请求。
    func testDisabledSkipsRecommendationRequest() async throws {
        try stubStandardSections()
        let (viewModel, server) = try await makeHomeViewModel(recommendationsEnabled: false)

        viewModel.load(server: server)
        await viewModel.waitUntilIdle()

        let requests = MockEmbyURLProtocol.recordedRequests()
        XCTAssertTrue(
            requests.filter { $0.url.path.hasSuffix("/Users/USER-1/Items") }.isEmpty,
            "关掉推荐后不该再请求随机推荐")
        XCTAssertEqual(requests.filter { $0.url.path.hasSuffix("/Views") }.count, 1)
        XCTAssertEqual(requests.filter { $0.url.path.hasSuffix("/Items/Resume") }.count, 1)
    }

    /// 对照组:证明上一条不是 mock 没拦住。
    func testEnabledStillRequestsRecommendations() async throws {
        try stubStandardSections()
        let (viewModel, server) = try await makeHomeViewModel(recommendationsEnabled: true)

        viewModel.load(server: server)
        await viewModel.waitUntilIdle()

        let recommendations = MockEmbyURLProtocol.recordedRequests()
            .filter { $0.url.path.hasSuffix("/Users/USER-1/Items") }
        XCTAssertEqual(recommendations.count, 1)
    }

    // MARK: - 关掉时 hero 不画

    /// 即使推荐池里有能上 hero 的条目也 `.none`,⛔ 不退回「继续观看 / 各库最新」。
    func testHeroPickIsNoneWhenDisabled() throws {
        let recommended = try item("R1", backdrop: true)
        let resumeItem = try item("C1", backdrop: true)
        let latestItem = try item("M1", backdrop: true)
        let pick = HomeViewModel.heroPick(
            recommended: .loaded([recommended]),
            views: .loaded([try view("V1", "movies")]),
            resume: .loaded([resumeItem]),
            latest: { _ in .loaded([latestItem]) },
            recommendationsEnabled: false
        )
        XCTAssertEqual(pick, .none)
    }

    /// 关闭早于加载态短路:否则 `.pending` 会让 hero 位置空着等一个永远不来的请求。
    func testDisabledBeatsPendingState() {
        let pick = HomeViewModel.heroPick(
            recommended: .loading,
            views: .loading,
            resume: .loading,
            latest: { _ in .idle },
            recommendationsEnabled: false
        )
        XCTAssertEqual(pick, .none)
    }

    // MARK: - 运行中改开关

    /// 并清掉那批推荐,下次打开时不先露出过时内容。
    func testTogglingOffClearsExistingRecommendations() async throws {
        try stubStandardSections(recommendationsJSON: Self.oneRecommendation)
        let (viewModel, server) = try await makeHomeViewModel(recommendationsEnabled: true)
        viewModel.load(server: server)
        await viewModel.waitUntilIdle()
        XCTAssertEqual(viewModel.sections(for: server.id).recommended.state.value?.count, 1)

        setRecommendationsEnabled(false)
        viewModel.recommendationsPreferenceChanged(server: server)

        XCTAssertEqual(viewModel.sections(for: server.id).recommended.state.value, [])
        XCTAssertEqual(heroPick(viewModel, server: server, enabled: false), .none)
    }

    /// 补发推荐请求;hero 先 `.pending` 占住高度,否则退路先显示一张再被换掉,首屏会跳。
    func testTogglingOnRefetchesRecommendations() async throws {
        try stubStandardSections(recommendationsJSON: Self.oneRecommendation)
        let (viewModel, server) = try await makeHomeViewModel(recommendationsEnabled: false)
        viewModel.load(server: server)
        await viewModel.waitUntilIdle()
        let before = recommendationRequestCount()
        XCTAssertEqual(before, 0)

        setRecommendationsEnabled(true)
        viewModel.recommendationsPreferenceChanged(server: server)
        XCTAssertEqual(
            viewModel.sections(for: server.id).recommended.state,
            .loading, "推荐还没回来,先占住 hero 的高度")
        await viewModel.waitUntilIdle()

        XCTAssertEqual(recommendationRequestCount(), 1, "打开开关后补发那一次推荐请求")
        XCTAssertEqual(viewModel.sections(for: server.id).recommended.state.value?.count, 1)
    }

    /// 改开关不重载整页(真实服务器纪律:低频率)。
    func testTogglingDoesNotReloadOtherSections() async throws {
        try stubStandardSections()
        let (viewModel, server) = try await makeHomeViewModel(recommendationsEnabled: false)
        viewModel.load(server: server)
        await viewModel.waitUntilIdle()
        let before = MockEmbyURLProtocol.recordedRequests().count

        setRecommendationsEnabled(true)
        viewModel.recommendationsPreferenceChanged(server: server)
        await viewModel.waitUntilIdle()

        let newPaths = MockEmbyURLProtocol.recordedRequests().dropFirst(before).map(\.url.path)
        XCTAssertTrue(
            newPaths.allSatisfy { $0.hasSuffix("/Users/USER-1/Items") },
            "只该补发推荐那一路,实际新请求 \(newPaths)")
    }

    // MARK: - 辅助

    private func setRecommendationsEnabled(_ enabled: Bool) {
        container.homeAppearance.showsHeroRecommendations = enabled
    }

    private func recommendationRequestCount() -> Int {
        MockEmbyURLProtocol.recordedRequests()
            .filter { $0.url.path.hasSuffix("/Users/USER-1/Items") }.count
    }

    /// 媒体库列表 / 继续观看 / 推荐三路的常规响应。
    private func stubStandardSections(
        recommendationsJSON: String = #"{"Items":[],"TotalRecordCount":0}"#
    ) throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("user_views_mixed_synthetic.json")),
            path: "/emby/Users/USER-1/Views"
        )
        MockEmbyURLProtocol.stub(
            .json(#"{"Items":[],"TotalRecordCount":0}"#),
            path: "/emby/Users/USER-1/Items/Resume"
        )
        MockEmbyURLProtocol.stub(.json(recommendationsJSON), path: "/emby/Users/USER-1/Items")
    }

    private func makeHomeViewModel(
        recommendationsEnabled: Bool
    ) async throws -> (HomeViewModel, ServerProfile) {
        let profile = try await makeServer()
        let registry = ServerRegistry(profiles: [], credentials: credentials)
        let container = AppContainer(
            registry: registry, credentials: credentials, session: session, preferences: defaults)
        self.container = container
        container.homeAppearance.showsHeroRecommendations = recommendationsEnabled
        return (HomeViewModel(container: container), profile)
    }

    private func heroPick(
        _ viewModel: HomeViewModel,
        server: ServerProfile,
        enabled: Bool
    ) -> HomeViewModel.HeroPick {
        let sections = viewModel.sections(for: server.id)
        return HomeViewModel.heroPick(
            recommended: sections.recommended.state,
            views: sections.views.state,
            resume: sections.resume.state,
            latest: { sections.latest[$0.id]?.state ?? .idle },
            recommendationsEnabled: enabled
        )
    }

    private func makeServer() async throws -> ServerProfile {
        let profile = ServerProfile(
            displayName: "emby.test",
            baseURL: testURL("https://emby.test"),
            apiPathPrefix: "/emby",
            userID: Self.userID,
            username: "testuser",
            deviceID: "DEVICE-UUID-1"
        )
        try await credentials.saveToken(Self.token, forServer: profile.id)
        return profile
    }

    private func item(_ id: String, backdrop: Bool) throws -> EmbyItem {
        let tags = backdrop ? ",\"BackdropImageTags\":[\"b-\(id)\"]" : ",\"BackdropImageTags\":[]"
        let json = "{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Movie\"\(tags)}"
        return try JSONDecoder().decode(EmbyItem.self, from: Data(json.utf8))
    }

    private func view(_ id: String, _ type: String?) throws -> EmbyView {
        let typeJSON = type.map { #","CollectionType":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(
            EmbyView.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)"\#(typeJSON)}"#.utf8)
        )
    }
}
