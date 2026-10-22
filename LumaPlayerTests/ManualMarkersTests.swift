import XCTest
@testable import LumaPlayer

/// 只验不需要 mpv、不需要网络的部分;菜单 / sheet 的观感不在这里覆盖。
@MainActor
final class ManualMarkersTests: XCTestCase {

    private var fileURL: URL!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "manual-markers-\(UUID().uuidString).json")
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
    }

    override func tearDown() async throws {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        try await storage.removeAll()
        fileURL = nil
        storage = nil
        credentials = nil
    }

    private func makeStore() -> ManualMarkersStore { ManualMarkersStore(fileURL: fileURL) }

    // MARK: - PlaybackMarkers 的手动构造(与章节构造同一套校验)

    func testManualInitValidatesIntroPair() {
        XCTAssertEqual(
            PlaybackMarkers(introStart: 10, introEnd: 20, creditsStart: nil).intro, 10..<20)
        XCTAssertEqual(
            PlaybackMarkers(introStart: 0, introEnd: 85, creditsStart: nil).intro, 0..<85,
            "片头从 0 开始是常见情况")
        XCTAssertNil(
            PlaybackMarkers(introStart: 10, introEnd: nil, creditsStart: nil).intro, "只有起点")
        XCTAssertNil(
            PlaybackMarkers(introStart: nil, introEnd: 20, creditsStart: nil).intro, "只有终点")
        XCTAssertNil(
            PlaybackMarkers(introStart: 90, introEnd: 30, creditsStart: nil).intro, "终点早于起点")
    }

    func testManualInitValidatesCredits() {
        XCTAssertEqual(
            PlaybackMarkers(introStart: nil, introEnd: nil, creditsStart: 1320).creditsStart, 1320)
        XCTAssertNil(
            PlaybackMarkers(introStart: nil, introEnd: nil, creditsStart: 0).creditsStart,
            "0 当作没标(与章节构造同口径)")
    }

    // MARK: - 合并:手动覆盖服务端,按标记组

    func testManualIntroOverridesServerIntroAndKeepsServerCredits() {
        let server = PlaybackMarkers(intro: 30..<120, creditsStart: 1320)
        let merged = ManualMarkers(introStart: 5, introEnd: 15).applying(to: server)
        XCTAssertEqual(merged.intro, 5..<15, "动过片头 → 整组取手动")
        XCTAssertEqual(merged.creditsStart, 1320, "没动过片尾 → 沿用服务端")
    }

    func testManualCreditsOnlyDoesNotWipeServerIntro() {
        let server = PlaybackMarkers(intro: 30..<120, creditsStart: nil)
        let merged = ManualMarkers(creditsStart: 1400).applying(to: server)
        XCTAssertEqual(merged.intro, 30..<120, "只标了片尾不该抹掉服务端片头")
        XCTAssertEqual(merged.creditsStart, 1400)
    }

    func testIncompleteManualIntroYieldsNoIntro() {
        let server = PlaybackMarkers(intro: 30..<120, creditsStart: 1320)
        let merged = ManualMarkers(introStart: 5).applying(to: server)
        XCTAssertNil(merged.intro, "用户要自己标片头,只填一端就不该再混进服务端那组")
        XCTAssertEqual(merged.creditsStart, 1320)
    }

    func testEmptyManualFallsBackToServer() {
        let server = PlaybackMarkers(intro: 30..<120, creditsStart: 1320)
        XCTAssertEqual(ManualMarkers().applying(to: server), server)
        XCTAssertTrue(ManualMarkers().isEmpty)
    }

    // MARK: - 作用范围键

    func testEmbyScopeKeyIsSharedAcrossEpisodesOfASeries() throws {
        let server = makeServer()
        let e1 = try embyItem(#"{"Id":"E1","Name":"E1","Type":"Episode","SeriesId":"SERIES"}"#)
        let e2 = try embyItem(#"{"Id":"E2","Name":"E2","Type":"Episode","SeriesId":"SERIES"}"#)
        XCTAssertEqual(
            ManualMarkersScope.key(for: .emby(server: server, item: e1)),
            ManualMarkersScope.key(for: .emby(server: server, item: e2)),
            "同一部剧的每一集共用同一个键")
    }

    func testEmbyScopeKeyFallsBackToItemIDWithoutSeries() throws {
        let server = makeServer()
        let m1 = try embyItem(#"{"Id":"M1","Name":"M1","Type":"Movie"}"#)
        let m2 = try embyItem(#"{"Id":"M2","Name":"M2","Type":"Movie"}"#)
        XCTAssertNotEqual(
            ManualMarkersScope.key(for: .emby(server: server, item: m1)),
            ManualMarkersScope.key(for: .emby(server: server, item: m2)),
            "没有 SeriesId 时退化为「这一部」")
    }

    func testEmbyScopeKeyIsolatesServers() throws {
        let item = try embyItem(#"{"Id":"M1","Name":"M1","Type":"Movie"}"#)
        XCTAssertNotEqual(
            ManualMarkersScope.key(for: .emby(server: makeServer(name: "a"), item: item)),
            ManualMarkersScope.key(for: .emby(server: makeServer(name: "b"), item: item)),
            "不同服务器上的 Item Id 可能撞车,必须隔离")
    }

    func testBaiduScopeKeyGroupsEpisodesByDirectory() {
        XCTAssertEqual(
            ManualMarkersScope.key(for: .baiduPan(
                file: baiduFile(fsID: 1, path: "/apps/LumaPlayer/琅琊榜/01.mp4"))),
            ManualMarkersScope.key(for: .baiduPan(
                file: baiduFile(fsID: 2, path: "/apps/LumaPlayer/琅琊榜/02.mp4"))),
            "同一目录里的分集共用")
    }

    func testBaiduScopeKeyGroupsExplicitEpisodeNames() {
        XCTAssertEqual(
            ManualMarkersScope.key(for: .baiduPan(
                file: baiduFile(fsID: 1, path: "/apps/x/Show/Show.S01E02.mkv"))),
            ManualMarkersScope.key(for: .baiduPan(
                file: baiduFile(fsID: 2, path: "/apps/x/Show/Show.S01E03.mkv"))))
    }

    func testBaiduScopeKeyKeepsMoviesApart() {
        // 4 位年份是「电影」的形状 → 退回这一条文件自己
        XCTAssertNotEqual(
            ManualMarkersScope.key(for: .baiduPan(
                file: baiduFile(fsID: 11, path: "/apps/LumaPlayer/电影/阿凡达.2009.mkv"))),
            ManualMarkersScope.key(for: .baiduPan(
                file: baiduFile(fsID: 12, path: "/apps/LumaPlayer/电影/2012.mkv"))),
            "同一目录里的电影不共用")
    }

    // MARK: - 持久化

    func testStoreRoundTripsAndSurvivesRestart() async throws {
        let markers = ManualMarkers(introStart: 10, introEnd: 20, creditsStart: 600)
        try await makeStore().set(markers, for: "emby|X|S")

        let reloaded = await makeStore().record(for: "emby|X|S")
        XCTAssertEqual(reloaded?.introStart, 10)
        XCTAssertEqual(reloaded?.introEnd, 20)
        XCTAssertEqual(reloaded?.creditsStart, 600)
    }

    func testSettingEmptyRecordRemovesTheEntry() async throws {
        let store = makeStore()
        try await store.set(ManualMarkers(introStart: 1, introEnd: 2), for: "k")
        try await store.set(ManualMarkers(), for: "k")

        let record = await store.record(for: "k")
        XCTAssertNil(record, "三个位置都空 = 没设过,不该留空壳")
    }

    func testRemoveDeletesTheEntry() async throws {
        let store = makeStore()
        try await store.set(ManualMarkers(creditsStart: 100), for: "k")
        try await store.remove(for: "k")

        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testWritesWithRestrictivePermissions() async throws {
        try await makeStore().set(ManualMarkers(creditsStart: 100), for: "k")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    /// ⛔ 不静默当成「没有手动标注」继续跑。
    func testCorruptedFileIsReportedNotSwallowed() async throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore()

        _ = await store.record(for: "k")
        let failure = await store.lastLoadFailureDescription
        XCTAssertNotNil(failure, "损坏原因要留下来,不能假装没事")
    }

    // MARK: - 菜单摘要文案

    func testSummaryListsWhatIsSet() {
        XCTAssertNil(ManualMarkers().summary, "什么都没设就不显示摘要行")
        XCTAssertEqual(ManualMarkers(introStart: 30, introEnd: 120).summary, "片头 00:30–02:00")
        XCTAssertEqual(ManualMarkers(creditsStart: 1320).summary, "片尾 22:00")
        XCTAssertEqual(
            ManualMarkers(introStart: 0, introEnd: 85, creditsStart: 1320).summary,
            "片头 00:00–01:25 · 片尾 22:00",
            "0 要显示成 00:00,不是 --:--")
    }

    /// 只填一端 / 顺序反了 / 片尾为 0。
    func testSummaryFlagsMarkersThatWillNotTakeEffect() {
        XCTAssertEqual(ManualMarkers(introStart: 30).summary, "片头未生效")
        XCTAssertEqual(ManualMarkers(introEnd: 120).summary, "片头未生效")
        XCTAssertEqual(ManualMarkers(introStart: 120, introEnd: 30).summary, "片头未生效")
        XCTAssertEqual(ManualMarkers(creditsStart: 0).summary, "片尾未生效")
        XCTAssertEqual(
            ManualMarkers(introStart: 30).summary,
            ManualMarkers(introEnd: 120).summary,
            "两种「只填一端」的写法给同一句提示")
    }

    // MARK: - 时间解析

    func testParseTimeText() {
        XCTAssertEqual(PlayerTime.parse("90"), 90)
        XCTAssertEqual(PlayerTime.parse("90.5"), 90.5)
        XCTAssertEqual(PlayerTime.parse("1:30"), 90)
        XCTAssertEqual(PlayerTime.parse("01:02:03"), 3723)
        XCTAssertEqual(PlayerTime.parse(" 12:34 "), 754)
        XCTAssertEqual(PlayerTime.parse("0"), 0)
        XCTAssertNil(PlayerTime.parse(""))
        XCTAssertNil(PlayerTime.parse("abc"))
        XCTAssertNil(PlayerTime.parse("-5"))
        XCTAssertNil(PlayerTime.parse("1:90"), "分 / 秒必须 0–59")
        XCTAssertNil(PlayerTime.parse("1:2:3:4"), "最多三段")
    }

    // MARK: - 播放页接线

    func testPlaybackMergesManualMarkersOverServerChapters() async throws {
        let server = makeServer()
        let item = try embyItem(#"{"Id":"M1","Name":"测试影片","Type":"Movie"}"#)
        let store = makeStore()
        try await store.set(
            ManualMarkers(introStart: 5, introEnd: 15),
            for: ManualMarkersScope.key(for: .emby(server: server, item: item)))

        let container = AppContainer(
            registry: try makeRegistry(),
            credentials: credentials,
            preferences: try XCTUnwrap(
                UserDefaults(suiteName: "test.LumaPlayer.manual.prefs.\(UUID().uuidString)")),
            manualMarkers: store)

        let viewModel = PlayerViewModel(
            container: container,
            request: PlaybackRequest(server: server, item: item),
            preparer: StubPreparer(session: makeSession()),
            displaySleep: RecordingDisplaySleepInhibitor())

        viewModel.start()
        // 等 `prepareAndLoad` 走到设标记那一步(在建 MPVPlayer / 等 GL 之前)
        for _ in 0..<500 {
            if viewModel.markers != .none { break }
            await Task.yield()
        }

        XCTAssertEqual(viewModel.markers.intro, 5..<15, "手动片头覆盖服务端")
        XCTAssertEqual(viewModel.markers.creditsStart, 1320, "没动过片尾 → 沿用服务端")
        XCTAssertTrue(viewModel.hasManualMarkers)
        viewModel.stop()
    }

    /// 不凭空造标记。
    func testPlaybackWithoutAnyMarkersStaysNone() async throws {
        let server = makeServer()
        let item = try embyItem(#"{"Id":"M1","Name":"测试影片","Type":"Movie"}"#)
        let container = AppContainer(
            registry: try makeRegistry(),
            credentials: credentials,
            preferences: try XCTUnwrap(
                UserDefaults(suiteName: "test.LumaPlayer.manual.prefs.\(UUID().uuidString)")),
            manualMarkers: makeStore())

        let viewModel = PlayerViewModel(
            container: container,
            request: PlaybackRequest(server: server, item: item),
            preparer: StubPreparer(session: makeSession(withChapters: false)),
            displaySleep: RecordingDisplaySleepInhibitor())

        viewModel.start()
        // 播放器建起来(或失败)说明已经过了设标记那一步
        for _ in 0..<500 {
            if viewModel.player != nil || viewModel.failure != nil { break }
            await Task.yield()
        }
        XCTAssertEqual(viewModel.markers, .none)
        XCTAssertFalse(viewModel.hasManualMarkers)
        viewModel.stop()
    }

    // MARK: - 替身与辅助

    /// 验的是接线(标记从哪来),不是会话准备。
    private struct StubPreparer: PlaybackSessionPreparing {
        let session: PlaybackSession
        func makeSession(startTimeTicks: Int64?) async throws -> PlaybackSession { session }
    }

    private func makeSession(withChapters: Bool = true) -> PlaybackSession {
        PlaybackSession(
            plan: .directStream(
                url: testURL("https://emby.test/videos/M1"),
                headers: [:], playSessionID: "SESSION-1", mediaSourceID: "SOURCE-1"),
            mediaSource: EmbyMediaSource(
                id: "SOURCE-1",
                container: "mkv",
                supportsDirectStream: true,
                supportsTranscoding: false,
                transcodingUrl: nil,
                mediaStreams: nil,
                chapters: withChapters ? [
                    chapter(30, EmbyChapter.Marker.introStart),
                    chapter(120, EmbyChapter.Marker.introEnd),
                    chapter(1320, EmbyChapter.Marker.creditsStart),
                ] : nil),
            seekStrategy: .clientSeek)
    }

    private func chapter(_ seconds: Double, _ marker: String) -> EmbyChapter {
        EmbyChapter(
            startPositionTicks: TickConverter.ticks(fromSeconds: seconds),
            name: marker,
            markerType: marker)
    }

    private func embyItem(_ json: String) throws -> EmbyItem {
        try JSONDecoder().decode(EmbyItem.self, from: Data(json.utf8))
    }

    private func baiduFile(fsID: UInt64, path: String) -> BaiduPanFile {
        BaiduPanFile(
            fsID: fsID,
            path: path,
            name: (path as NSString).lastPathComponent,
            sizeBytes: nil,
            isDirectory: false,
            category: 1,
            modifiedAt: nil,
            thumbnailURL: nil)
    }

    private func makeRegistry() throws -> ServerRegistry {
        try ServerRegistry(
            defaults: UserDefaults(suiteName: "test.LumaPlayer.manual.registry.\(UUID().uuidString)")!,
            credentials: credentials)
    }

    private func makeServer(name: String = "emby.test") -> ServerProfile {
        ServerProfile(
            displayName: name,
            baseURL: testURL("https://\(name).test"),
            deviceID: "DEVICE-UUID-1")
    }
}
