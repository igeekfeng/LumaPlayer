import XCTest
@testable import LumaPlayer

/// 音频延迟 / 章节 / 画面适配:纯映射与夹取、真实 libmpv 是否接受这些属性(空闲实例设进去再读回,不播放)、
/// `PlayerViewModel` 的事件与门禁。播放中的实际观感(裁切是否居中、旋转是否跟着字幕)这里验不到。
@MainActor
final class PictureAndChapterTests: XCTestCase {

    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUp() async throws {
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        defaultsSuite = "test.LumaPlayer.picture.prefs.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        defaults.removePersistentDomain(forName: defaultsSuite)
        storage = nil
        credentials = nil
        defaults = nil
    }

    // MARK: - 画面适配 → mpv 属性

    /// 默认值必须等于 mpv 自身默认:没动过画面的用户套用后画面不该变。
    func testDefaultPictureMatchesMPVDefaults() {
        XCTAssertEqual(properties(.default), [
            "panscan": "0.000",
            "video-zoom": "0.000",
            "video-rotate": "0",
            "video-aspect-override": "no",
        ])
    }

    func testPictureWritesAllFourProperties() {
        var picture = PictureSettings()
        picture.fit = .fill
        picture.zoom = 0.5
        picture.rotation = 270
        picture.aspect = .standard
        XCTAssertEqual(properties(picture), [
            "panscan": "1.000",
            "video-zoom": "0.500",
            "video-rotate": "270",
            "video-aspect-override": "4:3",
        ])
    }

    func testPictureClampsZoomAndRotation() {
        var picture = PictureSettings()
        picture.zoom = 9
        picture.rotation = 45
        XCTAssertEqual(picture.clamped.zoom, PictureSettings.zoomRange.upperBound)
        XCTAssertEqual(picture.clamped.rotation, 0, "非法角度退回不旋转")

        picture.zoom = .nan
        XCTAssertEqual(picture.clamped.zoom, 0, "非有限值退回默认")
    }

    func testZoomPercentIsLog2Factor() {
        var picture = PictureSettings()
        picture.zoom = 0
        XCTAssertEqual(picture.zoomPercent, 100)
        picture.zoom = 1
        XCTAssertEqual(picture.zoomPercent, 200)
        picture.zoom = -1
        XCTAssertEqual(picture.zoomPercent, 50)
    }

    func testLibmpvAcceptsPictureProperties() throws {
        let player = MPVPlayer()
        defer { player.shutdown() }
        try XCTSkipIf(player.initializationFailure != nil, "libmpv 初始化失败")

        var picture = PictureSettings()
        picture.fit = .fill
        picture.zoom = 0.25
        picture.rotation = 90
        picture.aspect = .widescreen
        try player.setPicture(picture)

        let read = player.stringProperties(
            ["panscan", "video-zoom", "video-rotate", "video-aspect-override"])
        XCTAssertEqual(read["panscan"].flatMap(Double.init), 1)
        XCTAssertEqual(read["video-zoom"].flatMap(Double.init), 0.25)
        XCTAssertEqual(read["video-rotate"].flatMap(Int.init), 90)
        // mpv 把 `16:9` 归一成小数,读回的是 1.777778
        XCTAssertEqual(read["video-aspect-override"].flatMap(Double.init) ?? 0, 16.0 / 9, accuracy: 0.001)
    }

    // MARK: - 音频延迟

    func testAudioDelayIsClampedAndRounded() {
        XCTAssertEqual(PlayerViewModel.clampedAudioDelay(0.1 + 0.1 + 0.1), 0.3)
        XCTAssertEqual(PlayerViewModel.clampedAudioDelay(500), Metrics.audioDelayRange.upperBound)
        XCTAssertEqual(PlayerViewModel.clampedAudioDelay(-500), Metrics.audioDelayRange.lowerBound)
        XCTAssertEqual(PlayerViewModel.clampedAudioDelay(.nan), 0)
        XCTAssertEqual(PlayerViewModel.clampedAudioDelay(-0.001).sign, .plus, "-0 统一成 0")
    }

    func testAudioDelayTextSaysLaterOrEarlier() {
        XCTAssertEqual(PlayerViewModel.audioDelayText(0.3), "音频延后 0.3 秒")
        XCTAssertEqual(PlayerViewModel.audioDelayText(-1.5), "音频提前 1.5 秒")
        XCTAssertEqual(PlayerViewModel.audioDelayText(0), "音频无延迟")
        XCTAssertEqual(PlayerViewModel.audioDelayValueText(2, unit: "s"), "+2 s")
        XCTAssertEqual(PlayerViewModel.audioDelayValueText(0, unit: "s"), "0 s")
    }

    func testLibmpvAudioDelayReadsBack() throws {
        let player = MPVPlayer()
        defer { player.shutdown() }
        try XCTSkipIf(player.initializationFailure != nil, "libmpv 初始化失败")
        try player.setAudioDelay(-0.35)
        XCTAssertEqual(
            player.stringProperties(["audio-delay"])["audio-delay"].flatMap(Double.init), -0.35)
    }

    func testAudioDelayFollowsReadBackAndGenerationGate() throws {
        let viewModel = try makeViewModel()
        viewModel.handle(.audioDelay(0.4), generation: 0)
        XCTAssertEqual(viewModel.audioDelay, 0.4)

        viewModel.stop()
        viewModel.handle(.audioDelay(9), generation: 0)
        XCTAssertEqual(viewModel.audioDelay, 0.4, "上一轮播放器的迟到事件丢弃")
    }

    /// 没有会话时 C / V 不响应:调了也听不出来,不该留下看不见的状态。
    func testAudioDelayIgnoredWithoutSession() throws {
        let viewModel = try makeViewModel()
        XCTAssertFalse(viewModel.canAdjustAudioDelay)
        viewModel.stepAudioDelay(later: true)
        XCTAssertNil(viewModel.osd, "不响应就不该有屏显")
        XCTAssertEqual(viewModel.audioDelay, 0)
    }

    // MARK: - 章节

    func testChapterLookupPicksLastOneAtOrBeforePosition() {
        let chapters = [
            MPVChapter(index: 0, time: 0, title: "开场"),
            MPVChapter(index: 1, time: 95.5, title: nil),
            MPVChapter(index: 2, time: 300, title: "尾声"),
        ]
        XCTAssertEqual(MPVChapter.current(at: 0, in: chapters)?.index, 0)
        XCTAssertEqual(MPVChapter.current(at: 95.4, in: chapters)?.index, 0, "边界之前仍属上一章")
        XCTAssertEqual(MPVChapter.current(at: 95.5, in: chapters)?.index, 1, "正好在边界时算新的一章")
        XCTAssertEqual(MPVChapter.current(at: 9999, in: chapters)?.index, 2)
        XCTAssertNil(MPVChapter.current(at: .nan, in: chapters))
        XCTAssertNil(MPVChapter.current(at: 10, in: []))
    }

    func testChapterDisplayNameFallsBackToIndex() {
        XCTAssertEqual(MPVChapter(index: 0, time: 0, title: "OP").displayName, "OP")
        XCTAssertEqual(MPVChapter(index: 1, time: 90, title: nil).displayName, "第 2 章")
        XCTAssertEqual(MPVChapter(index: 2, time: 90, title: "  ").displayName, "第 3 章")
    }

    func testChapterListEventDrivesStateAndGenerationGate() throws {
        let viewModel = try makeViewModel()
        let chapters = [
            MPVChapter(index: 0, time: 0, title: "开场"),
            MPVChapter(index: 1, time: 600, title: nil),
        ]
        viewModel.handle(.chapterList(chapters), generation: 0)
        XCTAssertEqual(viewModel.chapters, chapters)
        XCTAssertTrue(viewModel.hasChapters)

        viewModel.stop()
        viewModel.handle(.chapterList([]), generation: 0)
        XCTAssertEqual(viewModel.chapters, chapters, "上一轮播放器的迟到事件丢弃")
    }

    /// 没有会话 / 少于两章时不给入口,也不该有屏显。
    func testSkipChapterWithoutSessionIsIgnored() throws {
        let viewModel = try makeViewModel()
        XCTAssertFalse(viewModel.canSkipChapter)
        viewModel.skipChapter(by: 1)
        XCTAssertNil(viewModel.osd)
    }

    // MARK: - 辅助

    private func properties(_ picture: PictureSettings) -> [String: String] {
        Dictionary(uniqueKeysWithValues: picture.mpvProperties.map { ($0.name, $0.value) })
    }

    private func makeViewModel() throws -> PlayerViewModel {
        let registry = try ServerRegistry(
            defaults: UserDefaults(suiteName: "test.LumaPlayer.picture.registry.\(UUID().uuidString)")!,
            credentials: credentials
        )
        let container = AppContainer(registry: registry, credentials: credentials, preferences: defaults)
        let item = try JSONDecoder().decode(
            EmbyItem.self, from: Data(#"{"Id":"ITEM-1","Name":"测试影片","Type":"Movie"}"#.utf8))
        return PlayerViewModel(
            container: container,
            server: ServerProfile(displayName: "emby.test", baseURL: testURL("https://emby.test"), deviceID: "DEVICE-UUID-1"),
            item: item,
            displaySleep: RecordingDisplaySleepInhibitor()
        )
    }
}
