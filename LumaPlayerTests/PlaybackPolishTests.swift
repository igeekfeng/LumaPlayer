import XCTest
@testable import LumaPlayer

/// 播放打磨(2026-09-24 追加):片头 / 片尾标记、续播回退、触控板横滑预览、
/// 统计信息格式化、播放偏好持久化、上一集查找。
///
/// 与 `PlayerExperienceTests` 同一原则:只验不需要 mpv、不需要网络的部分。
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
        viewModel.handle(.timePos(50), generation: 0)
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

    // MARK: - 缓冲 / 统计

    func testBufferingEndClearsProgress() throws {
        let viewModel = try makeViewModel()
        viewModel.handle(.buffering(true), generation: 0)
        viewModel.handle(.buffering(false), generation: 0)
        XCTAssertNil(viewModel.bufferingPercent)
        XCTAssertNil(viewModel.cacheSpeedBytesPerSecond)
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
        XCTAssertEqual(PlayerStatistics.decoderText("no"), "软件解码")
        XCTAssertEqual(PlayerStatistics.decoderText("videotoolbox"), "硬件解码(videotoolbox)")
        XCTAssertEqual(PlayerStatistics.bitrateText("8200000"), "8.2 Mbps")
        XCTAssertEqual(PlayerStatistics.bitrateText("192000"), "192 kbps")
        XCTAssertNil(PlayerStatistics.bitrateText("0"))
        XCTAssertNil(PlayerStatistics.bitrateText("abc"))
        XCTAssertEqual(PlayerStatistics.fpsText("23.976"), "23.976 fps")
    }

    /// 实测值取自本机 mpv 0.41 播放一段 640×360 H.264 测试片的读数。
    func testStatisticsLinesSkipMissingProperties() {
        let stats = PlayerStatistics(properties: [
            "video-codec": "H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10",
            "video-params/w": "640",
            "video-params/h": "360",
            "container-fps": "24",
            "hwdec-current": "no",
            "audio-codec-name": "aac",
            "audio-params/samplerate": "44100",
            "audio-params/channel-count": "1",
        ], session: nil)
        let byLabel = Dictionary(uniqueKeysWithValues: stats.lines.map { ($0.label, $0.value) })
        XCTAssertEqual(byLabel["视频"], "H.264 · 640×360 · 24 fps")
        XCTAssertEqual(byLabel["解码"], "软件解码")
        XCTAssertEqual(byLabel["音频"], "aac · 44.1 kHz · 1 声道")
        XCTAssertNil(byLabel["丢帧"], "读不到的属性不凑「未知」")
        XCTAssertNil(byLabel["播放方式"], "没有会话就不显示播放方式")
    }

    // MARK: - 上一集

    func testPreviousEpisodeIsTheOneRightBefore() throws {
        let episodes = try ["E1", "E2", "E3"].map { try decodeItem(#"{"Id":"\#($0)","Name":"\#($0)","Type":"Episode"}"#) }
        XCTAssertEqual(NextEpisodeResolver.item(before: "E2", in: episodes)?.id, "E1")
        XCTAssertNil(NextEpisodeResolver.item(before: "E1", in: episodes))
        XCTAssertNil(NextEpisodeResolver.item(before: "X", in: episodes))
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

    private func makeViewModel(item: EmbyItem? = nil, startFromBeginning: Bool = false) throws -> PlayerViewModel {
        let registry = try ServerRegistry(
            defaults: UserDefaults(suiteName: "test.LumaPlayer.polish.registry.\(UUID().uuidString)")!,
            credentials: credentials
        )
        let profile = ServerProfile(
            displayName: "emby.test",
            baseURL: testURL("https://emby.test"),
            deviceID: "DEVICE-UUID-1"
        )
        return PlayerViewModel(
            container: AppContainer(registry: registry, credentials: credentials),
            server: profile,
            item: try item ?? decodeItem(#"{"Id":"ITEM-1","Name":"测试影片","Type":"Movie"}"#),
            startFromBeginning: startFromBeginning,
            defaults: defaults
        )
    }
}
