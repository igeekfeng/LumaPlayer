import XCTest
@testable import LumaPlayer

/// `PlayerViewModel` ↔ `PlaybackEngine` 的接线(用假引擎,零真实内核、零真实网络)。
///
/// 走 `MockEmbyURLProtocol` 提供 `PlaybackInfo`,所以 `prepareAndLoad` 能一路跑到
/// 「建引擎 → open → play」,可以断言起播偏好(倍速 / 音量 / 字幕外观 / 超分)
/// 确实写到了引擎上、引擎事件确实进了 ViewModel。
///
/// ⛔ 真实解码 / 渲染那一段仍要真机验证,见 docs/KNOWN_ISSUES.md。
@MainActor
final class PlayerViewModelEngineTests: XCTestCase {
    private static let userID = "USER-1"
    private static let token = "FAKE_TOKEN_0123456789"
    private static let itemID = "ITEM-1"

    private var session: URLSession!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUp() async throws {
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        defaultsSuite = "test.LumaPlayer.engine.prefs.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        defaults.removePersistentDomain(forName: defaultsSuite)
        session = nil
        storage = nil
        credentials = nil
        defaults = nil
    }

    /// 起播:引擎拿到 `open(URL + 认证头)` 与 `play`,起播偏好落到引擎上。
    func testStartOpensEngineAndAppliesStartupPreferences() async throws {
        try stubPlaybackInfo("playback_direct_stream_synthetic.json")
        defaults.set(1.5, forKey: PlaybackPreferences.Key.defaultSpeed)
        defaults.set(40.0, forKey: PlaybackPreferences.Key.defaultVolume)
        defaults.set(true, forKey: PlaybackPreferences.Key.useNeuralUpscaler)
        defaults.set(Data(#"{"scale":1.25}"#.utf8), forKey: SubtitleStyleStore.defaultsKey)

        let engine = FakePlaybackEngine()
        var requestedUpscaler: PlayerUpscaler?
        let (container, server) = try await makeContainerAndServer()
        let viewModel = makeViewModel(container: container, server: server, engine: engine) { upscaler in
            requestedUpscaler = upscaler
            return engine
        }

        viewModel.start()
        await waitUntil("引擎收到 play") { engine.didPlay }

        XCTAssertEqual(engine.openedURLs.count, 1)
        XCTAssertTrue(engine.openedURLs.first?.absoluteString.contains("static=true") == true)
        XCTAssertEqual(engine.openHeaders.first?["X-Emby-Token"], Self.token)
        XCTAssertEqual(requestedUpscaler, .artCNN, "超分偏好传给了引擎工厂")
        XCTAssertEqual(engine.rates, [1.5])
        XCTAssertEqual(engine.volumes, [0.4], "音量按 0–1 交给引擎")
        XCTAssertEqual(engine.subtitleStyles.last?.scale, 1.25)

        viewModel.stop()
        XCTAssertTrue(engine.didClose, "stop() 要关引擎")
    }

    /// 引擎事件经事件泵进入 ViewModel。
    func testEngineEventsReachViewModel() async throws {
        try stubPlaybackInfo("playback_direct_stream_synthetic.json")
        let engine = FakePlaybackEngine()
        let (container, server) = try await makeContainerAndServer()
        let viewModel = makeViewModel(container: container, server: server, engine: engine)
        viewModel.start()
        await waitUntil("引擎收到 play") { engine.didPlay }

        engine.enqueue(.duration(100))
        engine.enqueue(.position(42))
        engine.enqueue(.paused(true))
        engine.enqueue(.buffering(true))
        await waitUntil("位置事件到达") { viewModel.positionSeconds == 42 }

        XCTAssertEqual(viewModel.durationSeconds, 100)
        XCTAssertTrue(viewModel.isPaused)
        XCTAssertTrue(viewModel.isBuffering)

        viewModel.stop()
    }

    /// 自然播完:`isEnded` 置位并释放休眠断言。
    func testEndedEofMarksPlaybackFinished() async throws {
        try stubPlaybackInfo("playback_direct_stream_synthetic.json")
        let engine = FakePlaybackEngine()
        let (container, server) = try await makeContainerAndServer()
        let viewModel = makeViewModel(container: container, server: server, engine: engine)
        viewModel.start()
        await waitUntil("引擎收到 play") { engine.didPlay }

        engine.enqueue(.phaseChanged(.playing))
        engine.enqueue(.ended(.eof))
        await waitUntil("播完事件到达") { viewModel.isEnded }

        XCTAssertTrue(viewModel.isEnded)

        viewModel.stop()
    }

    // MARK: - 辅助

    private func stubPlaybackInfo(_ fixture: String, file: StaticString = #filePath, line: UInt = #line) throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json(fixture)),
            path: "/emby/Items/\(Self.itemID)/PlaybackInfo"
        )
    }

    private func makeContainerAndServer() async throws -> (AppContainer, ServerProfile) {
        let registry = try ServerRegistry(
            defaults: UserDefaults(suiteName: "test.LumaPlayer.engine.registry.\(UUID().uuidString)")!,
            credentials: credentials
        )
        let profile = ServerProfile(
            displayName: "emby.test",
            baseURL: testURL("https://emby.test"),
            apiPathPrefix: "/emby",
            userID: Self.userID,
            username: "testuser",
            deviceID: "DEVICE-UUID-1"
        )
        try await credentials.saveToken(Self.token, forServer: profile.id)
        let container = AppContainer(
            registry: registry,
            credentials: credentials,
            session: session,
            preferences: defaults
        )
        return (container, profile)
    }

    private func makeViewModel(
        container: AppContainer,
        server: ServerProfile,
        engine: FakePlaybackEngine,
        factory: (@MainActor (PlayerUpscaler) throws -> any PlaybackEngine)? = nil
    ) -> PlayerViewModel {
        let item = try! JSONDecoder().decode(
            EmbyItem.self,
            from: Data(#"{"Id":"\#(Self.itemID)","Name":"测试影片","Type":"Movie"}"#.utf8)
        )
        return PlayerViewModel(
            container: container,
            server: server,
            item: item,
            displaySleep: RecordingDisplaySleepInhibitor(),
            engineFactory: factory ?? { _ in engine }
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "超时未满足:\(description)")
    }
}
