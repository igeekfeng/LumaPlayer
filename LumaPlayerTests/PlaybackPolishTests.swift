import XCTest
@testable import LumaPlayer

/// 播放打磨(2026-09-24 追加):片头 / 片尾标记、续播回退、触控板横滑预览、
/// 统计信息格式化、播放偏好持久化、上一集查找。
/// 2026-10-06 追加:同一部剧沿用的倍速记忆(`PlaybackSpeedStore`)。
///
/// 与 `PlayerExperienceTests` 同一原则:只验不需要内核、不需要网络的部分。
/// ⛔ 按钮位置、倒计时的实际观感、触控板手感、置顶窗口是 UI 行为,
/// 本机无屏幕录制权限,不在这里假装覆盖。
@MainActor
final class PlaybackPolishTests: XCTestCase {

    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUp() async throws {
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        defaultsSuite = "test.LumaPlayer.polish.prefs.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        defaults.removePersistentDomain(forName: defaultsSuite)
        storage = nil
        credentials = nil
        defaults = nil
    }

    // MARK: - 章节解码

    func testChaptersDecodeFromMediaSource() throws {
        let response = try JSONDecoder().decode(
            EmbyPlaybackInfoResponse.self,
            from: try FixtureLoader.data("playback_chapter_markers_synthetic.json"))
        let chapters = try XCTUnwrap(response.mediaSources?.first?.chapters)
        XCTAssertEqual(chapters.count, 5)
        XCTAssertEqual(chapters[1].markerType, "IntroStart")
        XCTAssertEqual(chapters[1].startPositionTicks, 300_000_000)
        // 枚举外的值照样解出来(只是不认识),不能让整个 PlaybackInfo 解码失败
        XCTAssertEqual(chapters[4].markerType, "SomeFutureMarker")
    }

    /// 官方 OpenAPI 4.1.1.0 的 ChapterInfo 没有 `MarkerType`:旧服务器的章节照样能解。
    func testChapterWithoutMarkerTypeStillDecodes() throws {
        let json = #"{"Id":"MS","Chapters":[{"StartPositionTicks":0,"Name":"开头"}]}"#
        let source = try JSONDecoder().decode(EmbyMediaSource.self, from: Data(json.utf8))
        XCTAssertEqual(source.chapters?.first?.name, "开头")
        XCTAssertNil(source.chapters?.first?.markerType)
        XCTAssertEqual(PlaybackMarkers(chapters: source.chapters), .none)
    }

    func testMissingChaptersIsNil() throws {
        let source = try JSONDecoder().decode(EmbyMediaSource.self, from: Data(#"{"Id":"MS"}"#.utf8))
        XCTAssertNil(source.chapters)
    }

    // MARK: - 片头 / 片尾标记

    func testMarkersFromFixture() throws {
        let response = try JSONDecoder().decode(
            EmbyPlaybackInfoResponse.self,
            from: try FixtureLoader.data("playback_chapter_markers_synthetic.json"))
        let markers = PlaybackMarkers(chapters: response.mediaSources?.first?.chapters)
        XCTAssertEqual(markers.intro, 30..<120)
        XCTAssertEqual(markers.creditsStart, 1320)
    }

    func testIntroNeedsBothEndsInOrder() {
        XCTAssertNil(PlaybackMarkers(chapters: [chapter(30, "IntroStart")]).intro, "只有起点")
        XCTAssertNil(PlaybackMarkers(chapters: [chapter(90, "IntroEnd")]).intro, "只有终点")
        XCTAssertNil(
            PlaybackMarkers(chapters: [chapter(90, "IntroStart"), chapter(30, "IntroEnd")]).intro,
            "终点早于起点是脏数据,不显示按钮")
        XCTAssertEqual(
            PlaybackMarkers(chapters: [chapter(0, "IntroStart"), chapter(85, "IntroEnd")]).intro,
            0..<85, "片头从 0 开始是常见情况")
    }

    func testIsInIntroHonoursTailTolerance() {
        let markers = PlaybackMarkers(intro: 30..<120, creditsStart: nil)
        XCTAssertFalse(markers.isInIntro(29.9, tailTolerance: 1))
        XCTAssertTrue(markers.isInIntro(30, tailTolerance: 1))
        XCTAssertTrue(markers.isInIntro(118.9, tailTolerance: 1))
        // 最后 1 秒不再显示:跳过省不了什么,还会在终点附近闪
        XCTAssertFalse(markers.isInIntro(119.5, tailTolerance: 1))
        XCTAssertFalse(markers.isInIntro(120, tailTolerance: 1))
        XCTAssertFalse(PlaybackMarkers.none.isInIntro(60, tailTolerance: 1))
    }

    func testUpNextTriggerPrefersCreditsThenFallsBack() {
        let withCredits = PlaybackMarkers(intro: nil, creditsStart: 1320)
        XCTAssertEqual(withCredits.upNextTrigger(duration: 1440, fallbackLead: 10), 1320)

        XCTAssertEqual(PlaybackMarkers.none.upNextTrigger(duration: 1440, fallbackLead: 10), 1430)

        // 片尾标记晚于时长(脏数据)→ 退回兜底
        let bogus = PlaybackMarkers(intro: nil, creditsStart: 2000)
        XCTAssertEqual(bogus.upNextTrigger(duration: 1440, fallbackLead: 10), 1430)

        // 时长未知时不猜
        XCTAssertNil(withCredits.upNextTrigger(duration: 0, fallbackLead: 10))
        // 比兜底提前量还短的片子:从 0 起就提示,不出现负数
        XCTAssertEqual(PlaybackMarkers.none.upNextTrigger(duration: 5, fallbackLead: 10), 0)
    }

    func testCreditsAtZeroIsIgnored() {
        XCTAssertNil(PlaybackMarkers(chapters: [chapter(0, "CreditsStart")]).creditsStart)
    }

    // MARK: - 续播回退

    func testResumePositionRewindsButNeverBelowZero() {
        XCTAssertEqual(PlayerViewModel.resumePosition(from: 0), 0)
        XCTAssertEqual(PlayerViewModel.resumePosition(from: 3), 0)
        XCTAssertEqual(PlayerViewModel.resumePosition(from: 100), 100 - Metrics.resumeRewind)
    }

    func testViewModelAppliesRewindToServerPosition() throws {
        // 600 秒 = 6_000_000_000 ticks
        let item = try decodeItem(#"{"Id":"M","Name":"M","Type":"Movie","UserData":{"PlaybackPositionTicks":6000000000}}"#)
        let resumed = try makeViewModel(item: item)
        XCTAssertEqual(resumed.resumeStartSeconds, 600 - Metrics.resumeRewind)

        let fromStart = try makeViewModel(item: item, startFromBeginning: true)
        XCTAssertEqual(fromStart.resumeStartSeconds, 0)
    }

    /// DirectStream 续播时,到达续播点之前的 time-pos(文件开头)不可信。
    func testSettledPositionOnlyWaitsForDirectStreamResume() {
        XCTAssertFalse(PlayerViewModel.isSettledPosition(0, startSeconds: 595, method: .directStream))
        XCTAssertTrue(PlayerViewModel.isSettledPosition(594, startSeconds: 595, method: .directStream))
        XCTAssertTrue(PlayerViewModel.isSettledPosition(0, startSeconds: 0, method: .directStream))
        XCTAssertTrue(PlayerViewModel.isSettledPosition(0, startSeconds: 595, method: .transcode))
    }

    // MARK: - 触控板横滑预览

    func testScrubPreviewAccumulatesAndClamps() throws {
        let viewModel = try makeViewModel()
        viewModel.previewScrub(by: 30)
        XCTAssertNil(viewModel.scrubPreviewSeconds, "时长未知时不响应")

        viewModel.handle(.duration(100), generation: 0)
        viewModel.handle(.position(50), generation: 0)
        viewModel.previewScrub(by: 20)
        viewModel.previewScrub(by: 5)
        XCTAssertEqual(viewModel.scrubPreviewSeconds, 75, "从当前位置起累加,而不是每次都从当前位置重算")
        viewModel.previewScrub(by: 500)
        XCTAssertEqual(viewModel.scrubPreviewSeconds, 100)
        viewModel.previewScrub(by: -1000)
        XCTAssertEqual(viewModel.scrubPreviewSeconds, 0)

        viewModel.commitScrub()
        XCTAssertNil(viewModel.scrubPreviewSeconds, "松手后预览清空")
    }

    // MARK: - 偏好

    func testPreferencesDefaultAndPersist() throws {
        let first = try makeViewModel()
        XCTAssertFalse(first.autoSkipIntro, "默认给按钮,不自动跳")
        XCTAssertTrue(first.autoPlayNext)
        XCTAssertFalse(first.floatsOnTop)

        first.autoSkipIntro = true
        first.autoPlayNext = false
        first.floatsOnTop = true

        let second = try makeViewModel()
        XCTAssertTrue(second.autoSkipIntro)
        XCTAssertFalse(second.autoPlayNext)
        XCTAssertTrue(second.floatsOnTop)
    }

    /// 播放窗口菜单里的开关与设置页是同一份状态(都在 `container.preferences` 上)
    func testPreferenceTogglesAreSharedWithContainer() throws {
        let container = try makeContainer()
        let viewModel = try makeViewModel(container: container)
        viewModel.autoSkipIntro = true
        XCTAssertTrue(container.preferences.autoSkipIntro, "菜单里勾了,设置页也要是勾上的")
        container.preferences.autoPlayNext = false
        XCTAssertFalse(viewModel.autoPlayNext)
    }

    /// 起播倍速:这部剧本次运行调过就用调过的(P0-3),没调过用设置页的默认倍速
    func testStartupSpeedPrefersRememberedOverDefault() throws {
        let container = try makeContainer()
        let server = makeServer()
        let series = try episode("E1", series: "S1")
        container.preferences.defaultSpeed = 1.5
        XCTAssertEqual(
            try makeViewModel(container: container, server: server, item: series).startupSpeed, 1.5)

        try makeViewModel(container: container, server: server, item: series).setSpeed(2)
        XCTAssertEqual(
            try makeViewModel(container: container, server: server, item: series).startupSpeed, 2,
            "同一部剧沿用调过的倍速,优先于默认倍速")
    }

    /// 跳转步长跟着设置页走(同一个偏好驱动方向键、控制栏按钮与菜单栏)
    func testSeekStepComesFromPreferences() throws {
        let container = try makeContainer()
        container.preferences.seekStep = 30
        XCTAssertEqual(try makeViewModel(container: container).seekStep, 30)
    }

    // MARK: - 缓冲 / 统计

    func testBufferingFlagFollowsEvents() throws {
        let viewModel = try makeViewModel()
        XCTAssertFalse(viewModel.isBuffering)
        viewModel.handle(.buffering(true), generation: 0)
        XCTAssertTrue(viewModel.isBuffering)
        viewModel.handle(.buffering(false), generation: 0)
        XCTAssertFalse(viewModel.isBuffering)
    }

    func testStatisticsToggle() throws {
        let viewModel = try makeViewModel()
        viewModel.toggleStatistics()
        XCTAssertTrue(viewModel.showsStatistics)
        viewModel.toggleStatistics()
        XCTAssertFalse(viewModel.showsStatistics)
        XCTAssertNil(viewModel.statistics)
    }

    func testStatisticsFormatting() {
        XCTAssertEqual(PlayerStatistics.shortCodecName("H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10"), "H.264")
        XCTAssertEqual(PlayerStatistics.decoderText(name: nil, hardware: false), "软件解码")
        XCTAssertEqual(PlayerStatistics.decoderText(name: "videotoolbox", hardware: true), "硬件解码(videotoolbox)")
        XCTAssertEqual(PlayerStatistics.decoderText(name: "h264", hardware: nil), "h264")
        XCTAssertEqual(PlayerStatistics.bitrateText(8_200_000), "8.2 Mbps")
        XCTAssertEqual(PlayerStatistics.bitrateText(192_000), "192 kbps")
        XCTAssertNil(PlayerStatistics.bitrateText(0))
        XCTAssertEqual(PlayerStatistics.fpsText(23.976), "23.976 fps")
        XCTAssertNil(PlayerStatistics.fpsText(0))
    }

    /// 内核给不了(nil)的字段对应的行直接不显示,不填「未知」凑数。
    func testStatisticsLinesSkipMissingFields() {
        var stats = PlayerStats()
        stats.videoCodec = "H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10"
        stats.width = 640
        stats.height = 360
        stats.frameRate = 24
        stats.isHardwareDecoded = false
        stats.audioCodec = "aac"
        stats.audioSampleRate = 44_100
        stats.audioChannels = 1
        let lines = PlayerStatistics(stats: stats, session: nil)
        let byLabel = Dictionary(uniqueKeysWithValues: lines.lines.map { ($0.label, $0.value) })
        XCTAssertEqual(byLabel["视频"], "H.264 · 640×360 · 24 fps")
        XCTAssertEqual(byLabel["解码"], "软件解码")
        XCTAssertEqual(byLabel["音频"], "aac · 44.1 kHz · 1 声道")
        XCTAssertNil(byLabel["帧"], "内核没给帧数就不显示")
        XCTAssertNil(byLabel["播放方式"], "没有会话就不显示播放方式")
    }

    // MARK: - 上一集

    func testPreviousEpisodeIsTheOneRightBefore() throws {
        let episodes = try ["E1", "E2", "E3"].map { try decodeItem(#"{"Id":"\#($0)","Name":"\#($0)","Type":"Episode"}"#) }
        XCTAssertEqual(NextEpisodeResolver.item(before: "E2", in: episodes)?.id, "E1")
        XCTAssertNil(NextEpisodeResolver.item(before: "E1", in: episodes))
        XCTAssertNil(NextEpisodeResolver.item(before: "X", in: episodes))
    }

    // MARK: - 倍速记忆(同一部剧沿用同一个倍速)

    /// 决策(2026-10-06):同一部**剧集**沿用同一个倍速,不同剧集 / 电影各算各的,
    /// 重启 App 回到 1×。这里只验「记在哪、给谁用」;真正写回引擎的那一步要引擎,
    /// 不在这里假覆盖(`engine` 为 nil 时控制方法本来就是空操作)。
    func testSpeedIsRememberedPerSeries() throws {
        let container = try makeContainer()
        let server = makeServer()
        let first = try makeViewModel(
            container: container, server: server, item: try episode("E1", series: "S1"))
        XCTAssertEqual(first.startupSpeed, 1, "没设过就是 1×")

        first.setSpeed(1.5)

        let nextEpisode = try makeViewModel(
            container: container, server: server, item: try episode("E2", series: "S1"))
        XCTAssertEqual(nextEpisode.startupSpeed, 1.5, "同一部剧的下一集沿用")

        let otherSeries = try makeViewModel(
            container: container, server: server, item: try episode("E9", series: "S2"))
        XCTAssertEqual(otherSeries.startupSpeed, 1, "换一部剧不带过去")

        let otherMovie = try makeViewModel(
            container: container, server: server, item: try movie("M1"))
        XCTAssertEqual(otherMovie.startupSpeed, 1, "电影之间互不影响")
    }

    /// 电影没有 `SeriesId`,判定键退化成「这一项自己的 `Id`」:同一个 Id 重开仍沿用。
    func testSpeedScopeFallsBackToItemIDWithoutSeries() throws {
        let container = try makeContainer()
        let server = makeServer()
        XCTAssertEqual(PlaybackSpeedStore.scopeID(for: try episode("E1", series: "S1")), "S1")
        XCTAssertEqual(PlaybackSpeedStore.scopeID(for: try movie("M1")), "M1")

        try makeViewModel(container: container, server: server, item: try movie("M1")).setSpeed(2)
        XCTAssertEqual(
            try makeViewModel(container: container, server: server, item: try movie("M1")).startupSpeed,
            2)
    }

    /// 记的是夹取之后的值:滑块越界 / 浮点尾数不该原样带给后面几集。
    func testRememberedSpeedIsTheClampedValue() throws {
        let viewModel = try makeViewModel(item: try episode("E1", series: "S1"))
        viewModel.setSpeed(9)
        XCTAssertEqual(viewModel.startupSpeed, 4)
    }

    /// 手动调回 1× = 撤销记忆:后面的集数不该再自己弹回之前设过的高倍速。
    func testBackToNormalSpeedForgetsTheSeries() throws {
        let container = try makeContainer()
        let server = makeServer()
        let viewModel = try makeViewModel(
            container: container, server: server, item: try episode("E1", series: "S1"))
        viewModel.setSpeed(2)
        viewModel.setSpeed(1)
        XCTAssertEqual(
            try makeViewModel(container: container, server: server, item: try episode("E2", series: "S1"))
                .startupSpeed,
            1)
    }

    /// 每台服务器完全隔离:不同服务器上的 Item Id 可能撞车,不隔离会串台。
    func testRememberedSpeedIsScopedPerServer() throws {
        let container = try makeContainer()
        let series = try episode("E1", series: "S1")
        try makeViewModel(container: container, server: makeServer("a.test"), item: series).setSpeed(1.75)
        XCTAssertEqual(
            try makeViewModel(container: container, server: makeServer("b.test"), item: series).startupSpeed,
            1)
    }

    // MARK: - 辅助

    private func chapter(_ seconds: Double, _ marker: String) -> EmbyChapter {
        EmbyChapter(
            startPositionTicks: TickConverter.ticks(fromSeconds: seconds),
            name: marker,
            markerType: marker)
    }

    private func decodeItem(_ json: String) throws -> EmbyItem {
        try JSONDecoder().decode(EmbyItem.self, from: Data(json.utf8))
    }

    private func episode(_ id: String, series: String) throws -> EmbyItem {
        try decodeItem(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode","SeriesId":"\#(series)"}"#)
    }

    private func movie(_ id: String) throws -> EmbyItem {
        try decodeItem(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie"}"#)
    }

    /// 每次都是新容器 = 新的一次「App 运行」;要验跨集沿用就自己传同一个进来。
    ///
    /// `preferences` 用一次性 suite:播放偏好存在 UserDefaults 里,给它 `.standard`
    /// 会让「偏好默认值」这类用例互相污染(别的用例先跑一步就把默认改掉了)。
    private func makeContainer() throws -> AppContainer {
        let registry = try ServerRegistry(
            defaults: UserDefaults(suiteName: "test.LumaPlayer.polish.registry.\(UUID().uuidString)")!,
            credentials: credentials
        )
        return AppContainer(
            registry: registry,
            credentials: credentials,
            preferences: try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        )
    }

    private func makeServer(_ name: String = "emby.test") -> ServerProfile {
        ServerProfile(
            displayName: name,
            baseURL: testURL("https://\(name)"),
            deviceID: "DEVICE-UUID-1"
        )
    }

    private func makeViewModel(
        container: AppContainer? = nil,
        server: ServerProfile? = nil,
        item: EmbyItem? = nil,
        startFromBeginning: Bool = false
    ) throws -> PlayerViewModel {
        PlayerViewModel(
            container: try container ?? makeContainer(),
            server: server ?? makeServer(),
            item: try item ?? decodeItem(#"{"Id":"ITEM-1","Name":"测试影片","Type":"Movie"}"#),
            startFromBeginning: startFromBeginning
        )
    }
}
