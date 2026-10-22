import XCTest
@testable import LumaPlayer

/// `PlayerViewModel` 不需要 mpv / 网络的部分(player 为 nil 时 `stop()` 里的 `shutdown()` 是空操作)。
/// 起真实播放要 GL layer 与真实服务器,不在这里覆盖(KNOWN_ISSUES.md Q16)。
@MainActor
final class PlayerViewModelTests: XCTestCase {

    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    /// 替身:这里只验接线,不真去占住显示器。
    private var displaySleep = RecordingDisplaySleepInhibitor()

    override func setUp() async throws {
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        displaySleep = RecordingDisplaySleepInhibitor()
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
    }

    /// 旧播放器的事件经 `Task { @MainActor }` 投递,必然晚于同步的 `retry()` 到达;没有代次门会把上一轮的错误写到新会话上。
    func testStaleEventFromPreviousPlayerIsDropped() throws {
        let viewModel = try makeViewModel()

        viewModel.handle(.endFile(.error("拉流 401")), generation: 0)
        XCTAssertEqual(viewModel.failure?.message, "播放失败:拉流 401")

        // 用户点「重试」
        viewModel.stop()
        XCTAssertEqual(viewModel.failure?.message, "播放失败:拉流 401")

        // 旧播放器排队中的事件此时才到
        viewModel.handle(.endFile(.error("拉流 401")), generation: 0)
        viewModel.handle(.phaseChanged(.destroyed), generation: 0)
        viewModel.handle(.paused(true), generation: 0)

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertFalse(viewModel.isPaused)
    }

    /// 门不能把新代次的正常事件也挡掉。
    func testCurrentGenerationEventsStillApply() throws {
        let viewModel = try makeViewModel()
        viewModel.stop()

        viewModel.handle(.phaseChanged(.playing), generation: 1)
        viewModel.handle(.paused(true), generation: 1)

        XCTAssertEqual(viewModel.phase, .playing)
        XCTAssertTrue(viewModel.isPaused)
    }

    func testRetryAdvancesGenerationSoOldEventsCannotReviveFailure() throws {
        let viewModel = try makeViewModel()
        viewModel.handle(.endFile(.error("解码失败")), generation: 0)
        XCTAssertNotNil(viewModel.failure)

        // retry() 全程同步:start() 只排一个 Task,本用例挂起前不会运行,下面的断言是确定性的。
        viewModel.retry()
        XCTAssertNil(viewModel.failure)

        viewModel.handle(.endFile(.error("解码失败")), generation: 0)
        XCTAssertNil(viewModel.failure)

        // 取消 retry() 排下的任务。即便它跑起来也不发网络:没有 token,`ensureCredentials()` 先抛 .unauthorized。
        viewModel.stop()
    }

    /// 起播后按「简体 → 繁体 → 保持 mpv 默认」挑一次中文字幕轨:mpv 自己选带 `default` 标记的那条,常是英文。
    func testPreferredChineseSubtitleIsAppliedOnFirstTrackList() throws {
        let viewModel = try makeViewModel()

        viewModel.handle(.trackList([
            track(1, .audio, lang: "eng", selected: true),
            track(1, .sub, lang: "eng", selected: true),   // mpv 的 default 轨
            track(2, .sub, lang: "chi", title: "简体中文"),
        ]), generation: 0)

        XCTAssertEqual(viewModel.selectedSubtitleTrackID, 2)
    }

    /// 切轨后 mpv 会重推 track-list,不得再把用户的选择顶掉。
    func testUserSubtitleChoiceIsNotOverridden() throws {
        let viewModel = try makeViewModel()

        viewModel.handle(.trackList([
            track(1, .sub, lang: "eng", selected: true),
            track(2, .sub, lang: "chi", title: "简体中文"),
        ]), generation: 0)
        XCTAssertEqual(viewModel.selectedSubtitleTrackID, 2)

        viewModel.selectSubtitleTrack(1)
        XCTAssertEqual(viewModel.selectedSubtitleTrackID, 1)

        viewModel.handle(.trackList([
            track(1, .sub, lang: "eng", selected: true),
            track(2, .sub, lang: "chi", title: "简体中文"),
        ]), generation: 0)

        XCTAssertEqual(viewModel.selectedSubtitleTrackID, 1)
        viewModel.stop()
    }

    /// 必须立即返回,否则详情页的关窗回调(PITFALLS.md Q22)永远不触发。
    func testWaitUntilReportingFinishedReturnsWhenSessionNeverBegan() async throws {
        let viewModel = try makeViewModel()
        viewModel.stop()
        await viewModel.waitUntilReportingFinished()
    }

    // MARK: - 剧集队列(播放页换集)

    /// 百度来源没有 `seriesID` / `seasonID`,队列由浏览页装配后带进请求。
    func testRequestCarriedQueueResolvesNeighboursWithoutNetwork() throws {
        let viewModel = try makeBaiduViewModel(episodeCount: 3, playingIndex: 1)

        XCTAssertEqual(viewModel.episodes.count, 3)
        XCTAssertEqual(viewModel.currentEpisodeID, "20")
        XCTAssertEqual(viewModel.previousEpisode?.id, "10")
        XCTAssertEqual(viewModel.nextEpisode?.id, "30")
        XCTAssertEqual(viewModel.nextEpisode?.label, "第 3 集")
        XCTAssertNil(viewModel.playingItem, "百度来源没有 Emby 项")
    }

    func testQueueBoundariesHaveNoWrapAround() throws {
        let first = try makeBaiduViewModel(episodeCount: 3, playingIndex: 0)
        XCTAssertNil(first.previousEpisode)
        XCTAssertEqual(first.nextEpisode?.id, "20")

        let last = try makeBaiduViewModel(episodeCount: 3, playingIndex: 2)
        XCTAssertEqual(last.previousEpisode?.id, "20")
        XCTAssertNil(last.nextEpisode)
    }

    func testMovieHasNoEpisodeQueue() throws {
        let viewModel = try makeViewModel()
        XCTAssertTrue(viewModel.episodes.isEmpty)
        XCTAssertNil(viewModel.nextEpisode)
        XCTAssertNil(viewModel.previousEpisode)
        XCTAssertNil(viewModel.currentEpisodeID)
    }

    /// 分集自己的 `Primary` 优先,尺寸档位取 `episodeThumbnailWidth` 的两倍(视网膜屏)。
    func testPlayableEpisodeCarriesLandscapePosterDescriptor() throws {
        let profile = ServerProfile(
            displayName: "emby.test",
            baseURL: testURL("https://emby.test"),
            deviceID: "DEVICE-UUID-1"
        )
        let item = try JSONDecoder().decode(EmbyItem.self, from: Data(#"{"Id":"EP-1","Name":"第一集","Type":"Episode","SeriesId":"SER-1","SeasonId":"SEA-1","IndexNumber":1,"ParentIndexNumber":1,"ImageTags":{"Primary":"TAG-1"}}"#.utf8))

        let episode = PlayerViewModel.playableEpisode(item, on: profile)

        XCTAssertEqual(episode.poster, .emby(ImageSpec(
            serverID: profile.id,
            itemID: "EP-1",
            type: .primary,
            tag: "TAG-1",
            maxWidth: Int(Metrics.episodeThumbnailWidth * 2)
        )))
        XCTAssertNil(episode.resumeItem, "Emby 的进度走服务端,不带展示快照来源")
    }

    // MARK: - 换集不重建播放页

    /// 沿用 `pageID`(播放窗口据此不重建播放页),但 `id` 是新的:新一集是独立的播放会话。
    func testEpisodeSwitchKeepsPageButStartsNewSession() throws {
        let viewModel = try makeBaiduViewModel(episodeCount: 3, playingIndex: 0)
        let current = viewModel.playbackRequest

        viewModel.playNextEpisode()

        let next = try XCTUnwrap(baiduContainer?.state.nowPlaying)
        XCTAssertEqual(next.pageID, current.pageID)
        XCTAssertNotEqual(next.id, current.id)
        XCTAssertEqual(next.baiduFile?.fsID, 20)
        XCTAssertEqual(next.episodeQueue?.current?.id, "20", "百度的队列要原样带过去")
    }

    /// 播放器没建起来时音量是占位值,⛔ 不能当成用户调过的音量带给下一集;统计面板是页面级开关,照样带。
    func testCarryOverWithoutPlayerKeepsOnlyStatistics() throws {
        let viewModel = try makeBaiduViewModel(episodeCount: 3, playingIndex: 0)
        XCTAssertNil(viewModel.pageCarryOver, "什么都没动过就没有要带的")

        viewModel.toggleStatistics()
        let carryOver = try XCTUnwrap(viewModel.pageCarryOver)
        XCTAssertEqual(carryOver, PlayerViewModel.PageCarryOver(
            volume: Metrics.defaultVolume, isMuted: false, showsStatistics: true))

        let next = PlayerViewModel(
            container: try XCTUnwrap(baiduContainer),
            request: viewModel.playbackRequest,
            carryOver: carryOver,
            displaySleep: displaySleep)
        XCTAssertTrue(next.showsStatistics)
    }

    /// 换集时上一集的定格画面靠它撤:⛔ 出错 / 纯音频(永远等不到画面)也必须撤。
    func testAwaitingFirstVideoFrameEndsOnFrameFailureOrAudioOnly() throws {
        let rendered = try makeViewModel()
        XCTAssertTrue(rendered.isAwaitingFirstVideoFrame)
        rendered.handle(.firstVideoFrameRendered, generation: 0)
        XCTAssertFalse(rendered.isAwaitingFirstVideoFrame)

        let failed = try makeViewModel()
        failed.handle(.endFile(.error("拉流 401")), generation: 0)
        XCTAssertFalse(failed.isAwaitingFirstVideoFrame)

        let audioOnly = try makeViewModel()
        audioOnly.handle(.trackList([
            MPVTrack(id: 1, type: .audio, selected: true, title: nil, lang: nil, codec: "aac",
                     isExternal: false, isForced: false, isAlbumArt: false, dolbyVisionProfile: nil),
        ]), generation: 0)
        XCTAssertFalse(audioOnly.isAwaitingFirstVideoFrame)

        // 旧代次的首帧不算数
        let stale = try makeViewModel()
        stale.stop()
        stale.handle(.firstVideoFrameRendered, generation: 0)
        XCTAssertTrue(stale.isAwaitingFirstVideoFrame)
    }

    /// 出错时也不能再盖。转码 seek / 重试那条要真出过画面的 mpv,见 `MPVFrameHandoffTests`。
    func testLingeringFrameShowsOnlyWhileAwaitingFirstFrame() throws {
        let frozen = MPVPlayer()
        defer { frozen.shutdown() }

        let viewModel = try makeViewModel(lastFramePlayer: frozen)
        XCTAssertTrue(viewModel.lingeringPlayer === frozen)
        viewModel.handle(.firstVideoFrameRendered, generation: 0)
        XCTAssertNil(viewModel.lingeringPlayer)
        XCTAssertNil(viewModel.lastFramePlayer, "出画面后就该放掉上一帧")

        let failed = try makeViewModel(lastFramePlayer: frozen)
        failed.handle(.endFile(.error("拉流 401")), generation: 0)
        XCTAssertNil(failed.lingeringPlayer)

        // 还没出过画面就 stop(起播中又重试):沿用更早那一帧
        let restarted = try makeViewModel(lastFramePlayer: frozen)
        restarted.stop()
        XCTAssertTrue(restarted.lingeringPlayer === frozen)
    }

    private var baiduContainer: AppContainer?

    /// 队列由浏览页装配后带进请求(与 `FileSourceViewModel.play(_ item:)` 同一条路)。
    private func makeBaiduViewModel(episodeCount: Int, playingIndex: Int) throws -> PlayerViewModel {
        let registry = try ServerRegistry(
            defaults: UserDefaults(suiteName: "test.LumaPlayer.player.baidu.\(UUID().uuidString)")!,
            credentials: credentials
        )
        let sourceID = UUID()
        let items = (0..<episodeCount).map { index in
            SourceItem(
                ref: SourceItemRef(sourceID: sourceID, fsID: UInt64((index + 1) * 10)),
                title: "示例剧", kind: .episode, overview: nil, year: nil, tmdbID: nil,
                episodeNumber: index + 1, seasonNumber: 1, episodeTitle: nil,
                durationSeconds: nil, poster: nil, metadataOrigin: .filename)
        }
        let files = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (UInt64, BaiduPanFile)? in
            guard let fsID = UInt64(item.ref.itemID) else { return nil }
            return (fsID, BaiduPanFile(
                fsID: fsID,
                path: "/apps/LumaPlayer/\(fsID).mp4",
                name: "\(fsID).mp4",
                sizeBytes: nil,
                isDirectory: false,
                category: nil,
                modifiedAt: nil,
                thumbnailURL: nil))
        })
        let playing = items[playingIndex]
        let queue = try XCTUnwrap(FileSourceViewModel.episodeQueue(
            selecting: playing, in: items, filesByID: files, source: .baiduPan(BaiduPanSource(folderName: "LumaPlayer"))))
        let playingFile = try XCTUnwrap(files[UInt64(playing.ref.itemID) ?? 0])

        let container = AppContainer(
            registry: registry,
            credentials: credentials,
            preferences: UserDefaults(
                suiteName: "test.LumaPlayer.player.baidu.prefs.\(UUID().uuidString)")!,
            watchProgress: WatchProgressStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appending(path: "player-queue-\(UUID().uuidString).json"))
        )
        baiduContainer = container
        return PlayerViewModel(
            container: container,
            request: PlaybackRequest(
                source: .baiduPan(file: playingFile), episodeQueue: queue),
            displaySleep: displaySleep
        )
    }

    // MARK: - 转码 seek 的合并起流

    /// 防的是「已经过了 sleep 的任务」:`cancel()` 对它无效,只靠 `restartEpoch` 拦住,否则关窗后会自己起流。
    func testStopCancelsPendingTranscodeSeekMerge() async throws {
        let viewModel = try makeViewModel()
        XCTAssertFalse(viewModel.isRestarting)

        viewModel.stop()
        // 若合并没被作废,这里会看到 isRestarting 转回 true
        try await Task.sleep(for: .milliseconds(
            Int(Metrics.seekRestartMergeDelay * 1000) + 120))
        XCTAssertFalse(viewModel.isRestarting, "关窗后不该还有待起流的 seek")
    }

    /// 太短连点仍各起一次流,太长单次 seek 明显延迟。
    func testSeekMergeDelayStaysInSensibleRange() {
        XCTAssertGreaterThan(Metrics.seekRestartMergeDelay, 0.1)
        XCTAssertLessThanOrEqual(Metrics.seekRestartMergeDelay, 0.4)
    }

    // MARK: - 显示器休眠断言

    func testDisplaySleepAssertionFollowsPlaybackState() throws {
        let viewModel = try makeViewModel()
        XCTAssertFalse(displaySleep.isHeld, "还没起播就不该持有")

        viewModel.handle(.phaseChanged(.loading), generation: 0)
        XCTAssertFalse(displaySleep.isHeld, "起播准备中不持有(与 mpv 的 playback_active 一致)")

        viewModel.handle(.phaseChanged(.playing), generation: 0)
        XCTAssertTrue(displaySleep.isHeld)
        XCTAssertTrue(viewModel.isPreventingDisplaySleep)

        viewModel.handle(.paused(true), generation: 0)
        XCTAssertFalse(displaySleep.isHeld, "暂停要立刻把休眠策略还给系统")

        viewModel.handle(.paused(false), generation: 0)
        XCTAssertTrue(displaySleep.isHeld)

        // EOF:mpv 不把 phase 挪走,只能靠 isEnded
        viewModel.handle(.endFile(.eof), generation: 0)
        XCTAssertEqual(viewModel.phase, .playing)
        XCTAssertFalse(displaySleep.isHeld, "播完的卡片不该占着断言")

        viewModel.stop()
        XCTAssertFalse(displaySleep.isHeld)
    }

    /// 关窗 / 切媒体 / 转码重新起流都走 `stop()`,不能指望后面还有事件来收尾。
    func testStopReleasesDisplaySleepAssertionEvenWhilePlaying() throws {
        let viewModel = try makeViewModel()
        viewModel.handle(.phaseChanged(.playing), generation: 0)
        XCTAssertTrue(displaySleep.isHeld)

        viewModel.stop()

        XCTAssertFalse(displaySleep.isHeld)
        XCTAssertFalse(viewModel.isPreventingDisplaySleep)
    }

    // MARK: - 拖动门禁

    /// 文件没加载好与已播完时 mpv 对 seek 一律返回 `-12`。⛔ 判据不是 `duration > 0`:
    /// 百度源的总时长在会话准备阶段就填好了,那时文件还没开始加载。
    func testSeekGateFollowsKernelReadiness() throws {
        let viewModel = try makeViewModel()

        // 会话与播放器已就位,内核里还没有文件
        viewModel.handle(.phaseChanged(.loading), generation: 0)
        XCTAssertFalse(viewModel.isReadyToSeek)
        XCTAssertFalse(viewModel.allowsSeeking, "加载中放行就等于让用户去踩一个必然失败的动作")

        // FILE_LOADED 起 mpv 才接受 seek
        viewModel.handle(.phaseChanged(.playing), generation: 0)
        XCTAssertTrue(viewModel.isReadyToSeek)
        XCTAssertTrue(viewModel.allowsSeeking)

        viewModel.handle(.phaseChanged(.paused), generation: 0)
        XCTAssertTrue(viewModel.isReadyToSeek, "暂停时同样能拖")

        // 播完:mpv 已卸载文件,phase 却仍是 .playing(Q7)
        viewModel.handle(.phaseChanged(.playing), generation: 0)
        viewModel.handle(.endFile(.eof), generation: 0)
        XCTAssertEqual(viewModel.phase, .playing)
        XCTAssertFalse(viewModel.isReadyToSeek, "播完之后拖必然失败")
    }

    // MARK: - 辅助

    private func track(
        _ id: Int, _ type: MPVTrackType, lang: String? = nil,
        title: String? = nil, selected: Bool = false
    ) -> MPVTrack {
        MPVTrack(id: id, type: type, selected: selected, title: title, lang: lang,
                 codec: nil, isExternal: false, isForced: false)
    }

    private func makeViewModel(lastFramePlayer: MPVPlayer? = nil) throws -> PlayerViewModel {
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
            container: AppContainer(
                registry: registry,
                credentials: credentials,
                preferences: UserDefaults(suiteName: "test.LumaPlayer.player.prefs.\(UUID().uuidString)")!
            ),
            request: PlaybackRequest(server: profile, item: item),
            lastFramePlayer: lastFramePlayer,
            displaySleep: displaySleep
        )
    }
}
