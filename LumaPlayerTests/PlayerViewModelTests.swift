import XCTest
@testable import LumaPlayer

/// `PlayerViewModel` 的事件代次门。
///
/// 只覆盖**不需要 mpv、不需要网络**的那一段:`init` / `stop()` / `handle`
/// 三者都不碰 libmpv(player 为 nil 时 `stop()` 里的 `shutdown()` 是空操作),
/// 所以这条门可以在 CI 上确定性地验。
/// ⛔ 起真实播放那条路径要 GL layer 与真实服务器,不在这里假装覆盖
/// (见 docs/KNOWN_ISSUES.md Q16)。
@MainActor
final class PlayerViewModelTests: XCTestCase {

    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() async throws {
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
    }

    /// `MPVEventBridge` 经 `Task { @MainActor }` 投递,旧播放器在 shutdown
    /// 前后发出的事件必然晚于同步执行的 `retry()` 到达。没有代次门时它们会
    /// 把上一轮的错误写到刚起来的新会话上。
    func testStaleEventFromPreviousPlayerIsDropped() throws {
        let viewModel = try makeViewModel()

        // 第 0 代:事件正常落地
        viewModel.handle(.endFile(.error("拉流 401")), generation: 0)
        XCTAssertEqual(viewModel.failure?.message, "播放失败:拉流 401")

        // 用户点「重试」:stop() 递增代次,状态被重置
        viewModel.stop()
        XCTAssertEqual(viewModel.failure?.message, "播放失败:拉流 401")

        // 旧播放器排队中的事件此时才到 —— 必须丢弃,不能污染新一轮
        viewModel.handle(.endFile(.error("拉流 401")), generation: 0)
        viewModel.handle(.phaseChanged(.destroyed), generation: 0)
        viewModel.handle(.paused(true), generation: 0)

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertFalse(viewModel.isPaused)
    }

    /// 递增后的代次(= 新播放器实例)照常生效,门不能把正常事件也挡掉。
    func testCurrentGenerationEventsStillApply() throws {
        let viewModel = try makeViewModel()
        viewModel.stop()

        viewModel.handle(.phaseChanged(.playing), generation: 1)
        viewModel.handle(.paused(true), generation: 1)

        XCTAssertEqual(viewModel.phase, .playing)
        XCTAssertTrue(viewModel.isPaused)
    }

    /// `retry()` 走的是 `stop()`,所以它同样把代次推进一格。
    func testRetryAdvancesGenerationSoOldEventsCannotReviveFailure() throws {
        let viewModel = try makeViewModel()
        viewModel.handle(.endFile(.error("解码失败")), generation: 0)
        XCTAssertNotNil(viewModel.failure)

        // retry() 全程同步:stop() 推进代次并清态,start() 只是排一个 Task,
        // 在本用例挂起之前不会运行,所以下面的断言是确定性的。
        viewModel.retry()
        XCTAssertNil(viewModel.failure)

        // 旧实例排队中的事件此时才到 —— 不得让它复活失败态
        viewModel.handle(.endFile(.error("解码失败")), generation: 0)
        XCTAssertNil(viewModel.failure)

        // 收尾:取消 retry() 排下的任务,不让它活过本用例。
        // (即便它跑起来也不发网络:凭据文件里没有 token,
        //  `ensureCredentials()` 在任何请求之前就抛 .unauthorized。)
        viewModel.stop()
    }

    /// 起播后按「简体 → 繁体 → 保持 mpv 默认」自动挑一次中文字幕轨。
    /// mpv 自己会选带 `default` 标记的那条,常是英文 —— 这是这次改动的动机。
    func testPreferredChineseSubtitleIsAppliedOnFirstTrackList() throws {
        let viewModel = try makeViewModel()

        viewModel.handle(.trackList([
            track(1, .audio, lang: "eng", selected: true),
            track(1, .sub, lang: "eng", selected: true),   // mpv 的 default 轨
            track(2, .sub, lang: "chi", title: "简体中文"),
        ]), generation: 0)

        XCTAssertEqual(viewModel.selectedSubtitleTrackID, 2)
    }

    /// 用户手动选过之后,后续 track-list 回传不得再把它顶掉
    /// (切轨后 mpv 会重推 track-list)。
    func testUserSubtitleChoiceIsNotOverridden() throws {
        let viewModel = try makeViewModel()

        viewModel.handle(.trackList([
            track(1, .sub, lang: "eng", selected: true),
            track(2, .sub, lang: "chi", title: "简体中文"),
        ]), generation: 0)
        XCTAssertEqual(viewModel.selectedSubtitleTrackID, 2)

        // 用户改主意要看英文字幕
        viewModel.selectSubtitleTrack(1)
        XCTAssertEqual(viewModel.selectedSubtitleTrackID, 1)

        // mpv 回推的 track-list 里仍带着中文字幕 —— 偏好不得再介入
        viewModel.handle(.trackList([
            track(1, .sub, lang: "eng", selected: true),
            track(2, .sub, lang: "chi", title: "简体中文"),
        ]), generation: 0)

        XCTAssertEqual(viewModel.selectedSubtitleTrackID, 1)
        viewModel.stop()
    }

    /// 没播起来就关窗(会话从未开始):等待收尾必须立即返回,
    /// 否则详情页的关窗回调(docs/PITFALLS.md Q22)会永远不触发。
    func testWaitUntilReportingFinishedReturnsWhenSessionNeverBegan() async throws {
        let viewModel = try makeViewModel()
        viewModel.stop()
        await viewModel.waitUntilReportingFinished()
    }

    // MARK: - 辅助

    private func track(
        _ id: Int, _ type: MPVTrackType, lang: String? = nil,
        title: String? = nil, selected: Bool = false
    ) -> MPVTrack {
        MPVTrack(id: id, type: type, selected: selected, title: title, lang: lang,
                 codec: nil, isExternal: false)
    }

    private func makeViewModel() throws -> PlayerViewModel {
        let registry = try ServerRegistry(
            defaults: UserDefaults(suiteName: "test.LumaPlayer.player.\(UUID().uuidString)")!,
            credentials: credentials
        )
        let profile = ServerProfile(
            displayName: "emby.test",
            baseURL: testURL("https://emby.test"),
            deviceID: "DEVICE-UUID-1"
        )
        let item = try JSONDecoder().decode(
            EmbyItem.self,
            from: Data(#"{"Id":"ITEM-1","Name":"测试影片","Type":"Movie"}"#.utf8)
        )
        return PlayerViewModel(
            container: AppContainer(registry: registry, credentials: credentials),
            server: profile,
            item: item
        )
    }
}
