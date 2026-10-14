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
    /// 显示器休眠断言用替身:这些用例验的是接线,不该真去占住显示器
    /// (真断言的行为在 `DisplaySleepAssertionTests` 里验)。
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

    // MARK: - 剧集队列(播放页换集)

    /// 请求自带队列(百度来源的形态):上一集 / 下一集当场就定,⛔ 一次网络都不发。
    ///
    /// 百度没有 Emby 的 `seriesID` / `seasonID`,这条路上以前恒为 nil ——
    /// 播放页因此一个换集入口都不显示(队列由浏览页用已列条目装配后带进请求)。
    func testRequestCarriedQueueResolvesNeighboursWithoutNetwork() throws {
        let viewModel = try makeBaiduViewModel(episodeCount: 3, playingIndex: 1)

        XCTAssertEqual(viewModel.episodes.count, 3)
        XCTAssertEqual(viewModel.currentEpisodeID, "20")
        XCTAssertEqual(viewModel.previousEpisode?.id, "10")
        XCTAssertEqual(viewModel.nextEpisode?.id, "30")
        XCTAssertEqual(viewModel.nextEpisode?.label, "第 3 集")
        XCTAssertNil(viewModel.playingItem, "百度来源没有 Emby 项")
    }

    /// 首集没有上一集、末集没有下一集 —— ⛔ 不绕回。
    func testQueueBoundariesHaveNoWrapAround() throws {
        let first = try makeBaiduViewModel(episodeCount: 3, playingIndex: 0)
        XCTAssertNil(first.previousEpisode)
        XCTAssertEqual(first.nextEpisode?.id, "20")

        let last = try makeBaiduViewModel(episodeCount: 3, playingIndex: 2)
        XCTAssertEqual(last.previousEpisode?.id, "20")
        XCTAssertNil(last.nextEpisode)
    }

    /// 没有队列(电影 / 单条视频)时三个换集入口都不出现。
    func testMovieHasNoEpisodeQueue() throws {
        let viewModel = try makeViewModel()
        XCTAssertTrue(viewModel.episodes.isEmpty)
        XCTAssertNil(viewModel.nextEpisode)
        XCTAssertNil(viewModel.previousEpisode)
        XCTAssertNil(viewModel.currentEpisodeID)
    }

    /// Emby 分集的封面折成**来源无关**的 `.emby` 描述符(选集面板按它请求剧照)。
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

    /// 换集写出的新请求沿用本页的 `pageID`(播放窗口据此不重建播放页),
    /// 但 `id` 是新的 —— 新一集仍是一次独立的播放会话(新 ViewModel、新 mpv、新上报)。
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

    /// 播放器从没建起来时音量是占位值,⛔ 不能当成用户调过的音量带给下一集;
    /// 统计面板是页面级开关,照样带。
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

    /// 换集时上一集的定格画面撤不撤,看 `isAwaitingFirstVideoFrame`:
    /// 出了真实视频帧 → 撤;⛔ 出错 / 纯音频(永远等不到画面)也必须撤。
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

        // 上一个播放器(旧代次)的首帧不算数
        let stale = try makeViewModel()
        stale.stop()
        stale.handle(.firstVideoFrameRendered, generation: 0)
        XCTAssertTrue(stale.isAwaitingFirstVideoFrame)
    }

    /// `makeBaiduViewModel` 最近一次装配的容器(换集用例要读它的 `nowPlaying`)
    private var baiduContainer: AppContainer?

    /// 一部百度来源的剧集:`episodeCount` 集,当前播第 `playingIndex` 集,
    /// 队列由浏览页装配后带进请求(与 `BaiduPanSourceViewModel.play(_ item:)` 同一条路)。
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
        let queue = try XCTUnwrap(BaiduPanSourceViewModel.episodeQueue(
            selecting: playing, in: items, filesByID: files))
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

    /// 关窗 / 切媒体后,待起流的合并 seek 必须被作废。
    ///
    /// ⛔ 这条防的是「已经过了 sleep 的任务」:`stop()` 里 `cancel()` 对它无效,
    /// 只靠 `restartEpoch` 代次门拦住 —— 没有它,关窗后 0.25 秒会自己起流。
    /// `isRestarting` 同时被复位,UI 不会一直挂在「正在从新位置起流…」。
    func testStopCancelsPendingTranscodeSeekMerge() async throws {
        let viewModel = try makeViewModel()
        XCTAssertFalse(viewModel.isRestarting)

        viewModel.stop()
        // stop() 之后再等一拍:若合并没有被作废,这里会看到 isRestarting 转回 true
        try await Task.sleep(for: .milliseconds(
            Int(Metrics.seekRestartMergeDelay * 1000) + 120))
        XCTAssertFalse(viewModel.isRestarting, "关窗后不该还有待起流的 seek")
    }

    /// 合并窗口必须短到感觉不到,又长到足以吃掉连点 —— 0.25 秒是这个取舍的落点。
    /// 太短则连点仍会各起一次流(等于没合并),太长则单次 seek 会明显延迟。
    func testSeekMergeDelayStaysInSensibleRange() {
        XCTAssertGreaterThan(Metrics.seekRestartMergeDelay, 0.1)
        XCTAssertLessThanOrEqual(Metrics.seekRestartMergeDelay, 0.4)
    }

    // MARK: - 显示器休眠断言(GitHub issue #1)

    /// 断言跟着播放状态走:起播持、暂停放、恢复再持、播完放。
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

        // 播完(EOF):mpv 不把 phase 挪走,只能靠 isEnded
        viewModel.handle(.endFile(.eof), generation: 0)
        XCTAssertEqual(viewModel.phase, .playing)
        XCTAssertFalse(displaySleep.isHeld, "播完的卡片不该占着断言")

        viewModel.stop()
        XCTAssertFalse(displaySleep.isHeld)
    }

    /// 关窗 / 切媒体 / 转码重新起流都走 `stop()`:即使还停在 playing 也必须释放,
    /// 不能指望后面还有事件来收这个尾。
    func testStopReleasesDisplaySleepAssertionEvenWhilePlaying() throws {
        let viewModel = try makeViewModel()
        viewModel.handle(.phaseChanged(.playing), generation: 0)
        XCTAssertTrue(displaySleep.isHeld)

        viewModel.stop()

        XCTAssertFalse(displaySleep.isHeld)
        XCTAssertFalse(viewModel.isPreventingDisplaySleep)
    }

    // MARK: - 拖动门禁

    /// 内核没加载好文件、以及已播完这两段时间,拖动必然失败:mpv 对 seek 命令
    /// 一律返回 `-12`(PITFALLS)。门禁判据是 `isReadyToSeek`,⛔ 不是 `duration > 0`
    /// —— 百度源的总时长在会话准备阶段就填好了,那时文件还没开始加载。
    func testSeekGateFollowsKernelReadiness() throws {
        let viewModel = try makeViewModel()

        // 起播准备中:会话与播放器都已就位,但内核里还没有文件
        viewModel.handle(.phaseChanged(.loading), generation: 0)
        XCTAssertFalse(viewModel.isReadyToSeek)
        XCTAssertFalse(viewModel.allowsSeeking, "加载中放行就等于让用户去踩一个必然失败的动作")

        // FILE_LOADED:mpv 正是从这里开始接受 seek
        viewModel.handle(.phaseChanged(.playing), generation: 0)
        XCTAssertTrue(viewModel.isReadyToSeek)
        XCTAssertTrue(viewModel.allowsSeeking)

        viewModel.handle(.phaseChanged(.paused), generation: 0)
        XCTAssertTrue(viewModel.isReadyToSeek, "暂停时同样能拖")

        // 播完:mpv 已卸载文件,phase 却仍停在 .playing(§8 缺「已结束」态,Q7)
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
            container: AppContainer(
                registry: registry,
                credentials: credentials,
                preferences: UserDefaults(suiteName: "test.LumaPlayer.player.prefs.\(UUID().uuidString)")!
            ),
            server: profile,
            item: item,
            displaySleep: displaySleep
        )
    }
}
