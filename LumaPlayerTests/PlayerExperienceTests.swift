import XCTest
@testable import LumaPlayer

/// 播放体验:下一集查找、连续倍速、事件落地、独立窗口的播放请求。
///
/// 与 `PlayerViewModelTests` 同一原则:只验**不需要 mpv、不需要网络**的部分
/// (`player` 为 nil 时控制方法都是空操作,`handle` 不碰 libmpv)。
/// ⛔ 窗口、自动隐藏、菜单与媒体键是 UI 行为,本机无屏幕录制权限,
/// 不在这里假装覆盖。
@MainActor
final class PlayerExperienceTests: XCTestCase {

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

    // MARK: - 下一集

    func testNextEpisodeIsTheOneRightAfterInServerOrder() throws {
        let episodes = try [item("E1"), item("E2"), item("E3")]
        XCTAssertEqual(NextEpisodeResolver.item(after: "E1", in: episodes)?.id, "E2")
        XCTAssertEqual(NextEpisodeResolver.item(after: "E2", in: episodes)?.id, "E3")
    }

    func testNoNextEpisodeAfterLastOrWhenMissing() throws {
        let episodes = try [item("E1"), item("E2")]
        XCTAssertNil(NextEpisodeResolver.item(after: "E2", in: episodes))
        XCTAssertNil(NextEpisodeResolver.item(after: "NOT-IN-LIST", in: episodes))
        XCTAssertNil(NextEpisodeResolver.item(after: "E1", in: []))
    }

    // MARK: - 倍速

    func testSpeedTextDropsTrailingZeros() {
        XCTAssertEqual(PlayerViewModel.speedText(1), "1×")
        XCTAssertEqual(PlayerViewModel.speedText(2), "2×")
        XCTAssertEqual(PlayerViewModel.speedText(1.25), "1.25×")
        XCTAssertEqual(PlayerViewModel.speedText(0.5), "0.5×")
        // 连续调节会出到两位小数:1.35×,不是四舍五入成 1.4×
        XCTAssertEqual(PlayerViewModel.speedText(1.35), "1.35×")
        XCTAssertEqual(PlayerViewModel.speedText(1.1), "1.1×")
    }

    /// 连续调节:值必须夹在 mpv 的可用区间内,且不带浮点尾数
    /// (滑块拖出来的 `1.1500000000000001` 会让屏显与上报抖动)。
    func testClampedSpeedStaysInMpvsRange() {
        XCTAssertEqual(PlayerViewModel.clampedSpeed(0.1), 0.25)
        XCTAssertEqual(PlayerViewModel.clampedSpeed(9), 4)
        XCTAssertEqual(PlayerViewModel.clampedSpeed(1.1500000000000001), 1.15)
    }

    /// 不再是「跳到下一档」:从任意值出发都只走一个固定步长,端点处不动。
    func testStepSpeedMovesByFixedStepNotPreset() {
        XCTAssertEqual(PlayerViewModel.steppedSpeed(from: 1, up: true, step: 0.1), 1.1)
        XCTAssertEqual(PlayerViewModel.steppedSpeed(from: 1.35, up: true, step: 0.05), 1.4)
        XCTAssertEqual(PlayerViewModel.steppedSpeed(from: 1.35, up: false, step: 0.05), 1.3)
        XCTAssertEqual(PlayerViewModel.steppedSpeed(from: 4, up: true, step: 0.1), 4)
        XCTAssertEqual(PlayerViewModel.steppedSpeed(from: 0.25, up: false, step: 0.1), 0.25)
    }

    /// 连续拖滑块(0.05 一跳)不能每跳都发一次 `PlaybackRateChange` ——
    /// 一次拖动十几个请求,违反真实服务器「低频」纪律。合并后只发最后一次的值。
    func testContinuousSpeedChangeReportsOnce() async throws {
        let recorder = RateChangeRecorder()
        let reporter = PlaybackProgressReporter { endpoint in
            await recorder.record(endpoint)
        }
        let viewModel = try makeViewModel(reporter: reporter)
        await reporter.begin(context: Self.reportContext, state: Self.reportState)

        for value in [1.05, 1.1, 1.15, 1.2, 1.25] {
            viewModel.handle(.speed(value), generation: 0)
        }
        let duringDrag = await recorder.snapshot()
        XCTAssertTrue(duringDrag.isEmpty, "合并窗口内不应发请求")

        try await Task.sleep(for: .milliseconds(800))
        await reporter.drain()
        let sent = await recorder.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.eventName, "PlaybackRateChange")
        XCTAssertEqual(sent.first?.playbackRate, 1.25)
        XCTAssertEqual(viewModel.speed, 1.25)
        viewModel.stop()
    }

    func testSpeedEventUpdatesReadBackValue() throws {
        let viewModel = try makeViewModel()
        viewModel.handle(.speed(1.5), generation: 0)
        XCTAssertEqual(viewModel.speed, 1.5)
    }

    func testBufferingAndEndOfFileEventsApply() throws {
        let viewModel = try makeViewModel()
        viewModel.handle(.buffering(true), generation: 0)
        XCTAssertTrue(viewModel.isBuffering)
        viewModel.handle(.endFile(.eof), generation: 0)
        XCTAssertTrue(viewModel.isEnded)
    }

    /// 播完后重试 / 重播:「已播完」必须复位,否则播完卡片会盖在新一轮播放上。
    func testRetryClearsEndedState() throws {
        let viewModel = try makeViewModel()
        viewModel.handle(.endFile(.eof), generation: 0)
        viewModel.retry()
        XCTAssertFalse(viewModel.isEnded)
        viewModel.stop()
    }

    // MARK: - 音量图标

    func testVolumeSymbolReflectsLevelAndMute() {
        XCTAssertEqual(PlayerViewModel.volumeSymbol(80, muted: true), "speaker.slash.fill")
        XCTAssertEqual(PlayerViewModel.volumeSymbol(0, muted: false), "speaker.slash.fill")
        XCTAssertEqual(PlayerViewModel.volumeSymbol(20, muted: false), "speaker.wave.1.fill")
        XCTAssertEqual(PlayerViewModel.volumeSymbol(50, muted: false), "speaker.wave.2.fill")
        XCTAssertEqual(PlayerViewModel.volumeSymbol(100, muted: false), "speaker.wave.3.fill")
    }

    // MARK: - 时间文案

    func testTimeTextNeverFakesUnknownDuration() {
        XCTAssertEqual(PlayerTime.text(0), "--:--")
        XCTAssertEqual(PlayerTime.text(.nan), "--:--")
        XCTAssertEqual(PlayerTime.text(65), "01:05")
        XCTAssertEqual(PlayerTime.text(3725), "1:02:05")
    }

    /// 剩余时长带负号前缀;剩余为 0 时给 `-00:00`。
    /// ⛔ 曾经在这里输出 `---:--`:`text(0)` 返回 `--:--`,被拼上负号
    /// (2026-10-03 修复,拖到进度条最右端 / 播完必现)。
    func testRemainingTextRendersZeroWithMinusPrefix() {
        XCTAssertEqual(PlayerTime.remainingText(0, durationKnown: true), "-00:00")
        // 不足 1 秒也落到 -00:00,不能闪出 ---:--
        XCTAssertEqual(PlayerTime.remainingText(0.4, durationKnown: true), "-00:00")
        XCTAssertEqual(PlayerTime.remainingText(300, durationKnown: true), "-05:00")
        XCTAssertEqual(PlayerTime.remainingText(3300, durationKnown: true), "-55:00")
        XCTAssertEqual(PlayerTime.remainingText(3725, durationKnown: true), "-1:02:05")
        // 拖过头(夹取)也不能出负号时长
        XCTAssertEqual(PlayerTime.remainingText(-10, durationKnown: true), "-00:00")
    }

    /// 时长未知时**不加负号**:`--:--` 的语义是「不知道」,
    /// 负号的语义是「相对总量的差值」,没有总量就没有差值。
    func testRemainingTextOmitsMinusWhenDurationUnknown() {
        XCTAssertEqual(PlayerTime.remainingText(0, durationKnown: false), "--:--")
        XCTAssertEqual(PlayerTime.remainingText(120, durationKnown: false), "--:--")
    }

    // MARK: - 连点累加跳转

    /// 首次点击是 1 倍,`seekRepeatResetDelay` 内连点逐级加。
    func testSkipRepeatCountsUpWithinWindow() {
        var state = PlayerSkipRepeat()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(state.advance(now: start), 1)
        XCTAssertEqual(state.advance(now: start.addingTimeInterval(0.3)), 2)
        XCTAssertEqual(state.advance(now: start.addingTimeInterval(0.6)), 3)
    }

    /// 超过归零间隔后重新从 1 倍开始 —— 否则停一阵再点会突然跳很远。
    func testSkipRepeatResetsAfterIdle() {
        var state = PlayerSkipRepeat()
        let first = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(state.advance(now: first), 1)
        let second = first.addingTimeInterval(0.3)
        XCTAssertEqual(state.advance(now: second), 2)
        // 从**最后一次**点击起算超过归零间隔
        let later = second.addingTimeInterval(Metrics.seekRepeatResetDelay + 0.1)
        XCTAssertEqual(state.advance(now: later), 1)
    }

    /// 必须封顶:不封顶的话连点几十次会一次跳走几小时。
    func testSkipRepeatStopsAtMaxMultiple() {
        var state = PlayerSkipRepeat()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<20 { _ = state.advance(now: start) }
        XCTAssertEqual(state.advance(now: start), Metrics.seekRepeatMaxMultiple)
    }

    /// tooltip 预告的是**下一次**会跳多少,不是已经用掉的那一档;
    /// 没点过时预告 1 倍,点满上限后不再往上加。
    func testSkipRepeatUpcomingPreviewsNextClick() {
        var state = PlayerSkipRepeat()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(state.upcoming(now: start), 1)
        _ = state.advance(now: start)
        XCTAssertEqual(state.upcoming(now: start), 2)
        for _ in 0..<20 { _ = state.advance(now: start) }
        XCTAssertEqual(state.upcoming(now: start), Metrics.seekRepeatMaxMultiple)
        // 归零后预告也回到 1 倍
        let later = start.addingTimeInterval(Metrics.seekRepeatResetDelay + 0.1)
        XCTAssertEqual(state.upcoming(now: later), 1)
    }

    // MARK: - 预计结束时刻

    /// 倍速必须参与换算:1.25× 下剩 1200 秒,实际只过 960 秒。
    func testEndTimeAccountsForPlaybackSpeed() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let endsAt = try XCTUnwrap(PlayerTime.endsAt(
            position: 0, duration: 1200, speed: 1.25, isEnded: false, now: now
        ))
        XCTAssertEqual(endsAt.timeIntervalSince(now), 960, accuracy: 0.001)
    }

    /// 正常速度就是「现在 + 剩余」。
    func testEndTimeAtNormalSpeedIsNowPlusRemaining() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let endsAt = try XCTUnwrap(PlayerTime.endsAt(
            position: 300, duration: 3600, speed: 1, isEnded: false, now: now
        ))
        XCTAssertEqual(endsAt.timeIntervalSince(now), 3300, accuracy: 0.001)
    }

    /// 四种「宁可不显示」的情况都不能给出时刻 —— 编一个假的结束时间比不显示更糟。
    func testEndTimeIsNilWhenUnknownOrFinished() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 时长未知
        XCTAssertNil(PlayerTime.endsAt(position: 0, duration: 0, speed: 1, isEnded: false, now: now))
        // 已播完
        XCTAssertNil(PlayerTime.endsAt(position: 3600, duration: 3600, speed: 1, isEnded: true, now: now))
        // 剩余非正(拖过了头)
        XCTAssertNil(PlayerTime.endsAt(position: 3700, duration: 3600, speed: 1, isEnded: false, now: now))
        // 倍速非法
        XCTAssertNil(PlayerTime.endsAt(position: 0, duration: 3600, speed: 0, isEnded: false, now: now))
        XCTAssertNil(PlayerTime.endsAt(position: 0, duration: 3600, speed: .nan, isEnded: false, now: now))
        // 位置非有限
        XCTAssertNil(PlayerTime.endsAt(position: .nan, duration: 3600, speed: 1, isEnded: false, now: now))
    }

    // MARK: - 播放请求(独立窗口)

    /// 同一项再点一次播放必须是新请求:播放窗口按 pageID 重建播放页,
    /// id 相同就会被当成「没变」,旧会话继续、不会重新起播。
    func testPlayingSameItemTwiceMakesDistinctRequests() throws {
        let container = try makeContainer()
        let server = makeProfile()
        let movie = try item("M1")
        container.play(movie, on: server)
        let first = try XCTUnwrap(container.state.nowPlaying)
        container.play(movie, on: server)
        let second = try XCTUnwrap(container.state.nowPlaying)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.embyItem?.id, "M1")
        // 从别处起播一律是新播放页;只有播放页内换集才沿用(PlayerViewModelTests)
        XCTAssertEqual(second.pageID, second.id)
        XCTAssertNotEqual(first.pageID, second.pageID)
    }

    /// DesignTokens.swift「界面规则」:切到另一台服务器时结束旧播放,不能让播放器
    /// 继续放上一台的内容、继续往上一台上报。
    func testSwitchingToAnotherServerStopsPlayback() async throws {
        let registry = try makeRegistry()
        let container = AppContainer(registry: registry, credentials: credentials)
        let a = makeProfile(name: "alpha")
        let b = makeProfile(name: "beta")
        try await registry.add(a)
        try await registry.add(b)

        container.play(try item("M1"), on: a)
        try await container.switchCurrent(to: a)
        XCTAssertNotNil(container.state.nowPlaying, "切到正在播放的那台服务器不应打断播放")

        try await container.switchCurrent(to: b)
        XCTAssertNil(container.state.nowPlaying)
    }

    func testRemovingPlayingServerStopsPlayback() async throws {
        let registry = try makeRegistry()
        let container = AppContainer(registry: registry, credentials: credentials)
        let a = makeProfile(name: "alpha")
        try await registry.add(a)
        container.play(try item("M1"), on: a)

        try await container.removeServer(id: a.id)
        XCTAssertNil(container.state.nowPlaying)
    }

    // MARK: - 辅助

    private func item(_ id: String, type: String = "Episode") throws -> EmbyItem {
        try JSONDecoder().decode(
            EmbyItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)"}"#.utf8)
        )
    }

    private func makeRegistry() throws -> ServerRegistry {
        try ServerRegistry(
            defaults: UserDefaults(suiteName: "test.LumaPlayer.experience.\(UUID().uuidString)")!,
            credentials: credentials
        )
    }

    private func makeContainer() throws -> AppContainer {
        AppContainer(
            registry: try makeRegistry(),
            credentials: credentials,
            preferences: UserDefaults(suiteName: "test.LumaPlayer.experience.prefs.\(UUID().uuidString)")!
        )
    }

    private func makeProfile(name: String = "emby.test") -> ServerProfile {
        ServerProfile(
            displayName: name,
            baseURL: testURL("https://\(name).test"),
            deviceID: "DEVICE-UUID-1"
        )
    }

    private func makeViewModel(reporter: PlaybackProgressReporter? = nil) throws -> PlayerViewModel {
        PlayerViewModel(
            container: try makeContainer(),
            server: makeProfile(),
            item: try item("ITEM-1", type: "Movie"),
            reporter: reporter
        )
    }

    /// 只记 Progress 上报里的 `eventName` 与倍速。用 actor 而不是
    /// `@unchecked Sendable` 的盒子(CLAUDE.md「并发分层」,测试代码也不例外)。
    private actor RateChangeRecorder {
        struct Entry: Sendable {
            let eventName: String?
            let playbackRate: Double?
        }

        private var entries: [Entry] = []

        func record(_ endpoint: EmbyEndpoint) {
            guard case .sessionsPlayingProgress(let body) = endpoint else { return }
            entries.append(Entry(eventName: body.eventName, playbackRate: body.playbackRate))
        }

        func snapshot() -> [Entry] { entries }
    }

    private static let reportContext = PlaybackReportContext(
        itemID: "ITEM-1",
        mediaSourceID: "SOURCE-1",
        playSessionID: "SESSION-1",
        method: .directStream
    )
    private static let reportState = PlaybackReportState(
        positionSeconds: 60,
        isPaused: false,
        isMuted: false,
        volume: 80,
        audioStreamIndex: nil,
        subtitleStreamIndex: nil
    )
}
