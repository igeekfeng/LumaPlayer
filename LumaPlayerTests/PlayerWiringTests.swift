import XCTest
@testable import LumaPlayer

/// P3c 的接线测试:播放页把内核、上报、偏好、时间基**接对了**没有。
///
/// ## 为什么这批用例是新的
///
/// `main` 上有一批接线测试(`PlayerViewModelTests`,以及 `PlaybackPolishTests`
/// 的一部分:倍速跨集记忆、偏好联动、seek 分派、播完与上报时机)。
/// `exp/avkit-rust-core` 摘掉 libmpv 时它们随 `PlayerViewModel` 一起删了 ——
/// 那时播放层整个不存在,留着也编不过。P3c 把播放页接回来,这批覆盖在这里重建。
///
/// ## 边界(⛔ 别把这三件事混了)
///
/// - **本文件**:接线。内核是替身(`FakePlaybackEngine`),会话是造出来的 ——
///   本机 `xcodebuild test` 起不了 App(`KNOWN_ISSUES.md` Q34),真 `AVPlayer`
///   也不该进单测(要真流、真时间)。
/// - **`Scripts/verify-avkit-playback.sh`**:真内核能不能在这台机器上起播
///   (本地 mp4 / DirectStream / Transcode / 静默删轨负例)。
/// - **`RustPlaybackDecisionTests`**:决策过 FFI 边界后语义有没有走样。
///
/// 窗口、自动隐藏、菜单与媒体键是 UI 行为,本机无屏幕录制权限,不在这里假装覆盖。
@MainActor
final class PlayerWiringTests: XCTestCase {

    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() async throws {
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        MockEmbyURLProtocol.reset()
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
    }

    // MARK: - 起播:续播位置与时间基(R13)

    /// DirectStream 的续播只能客户端 seek:服务端吐的是整份文件。
    /// 起播位置 = 服务端记的进度往回退 `Metrics.resumeRewind` 秒。
    func testDirectStreamResumeSeeksToRewoundPosition() async throws {
        let harness = try await start(item: try item(playbackPositionTicks: 600 * 10_000_000))

        XCTAssertEqual(harness.viewModel.resumeStartSeconds, 600 - Metrics.resumeRewind)
        XCTAssertEqual(harness.engine.seekTargets.first, 600 - Metrics.resumeRewind,
                       "DirectStream 续播必须由客户端 seek 到续播点")
        XCTAssertEqual(harness.engine.playCount, 1, "放流 + 定位之后要真的起播")
        XCTAssertEqual(harness.viewModel.positionSeconds, 600 - Metrics.resumeRewind)
    }

    /// 从头播放(`startFromBeginning`)忽略服务端进度。
    func testStartFromBeginningIgnoresServerProgress() async throws {
        let harness = try await makeHarness(
            item: try item(playbackPositionTicks: 600 * 10_000_000), startFromBeginning: true)
        try await harness.run()

        XCTAssertEqual(harness.viewModel.resumeStartSeconds, 0)
        XCTAssertTrue(harness.engine.seekTargets.isEmpty, "从头播放不该有续播 seek")
        XCTAssertEqual(harness.viewModel.positionSeconds, 0)
    }

    /// ⭐ R13:转码流的**时间原点在起流点**,不是媒体开头。
    ///
    /// - 起流靠服务端的 `StartTimeTicks`(第二次取会话才带上),客户端**不**再 seek;
    /// - 内核报 0 秒时,绝对位置必须是起播点(否则续播的转码流会把进度写回 0)。
    func testTranscodeStartUsesStartTimeTicksAndReportsAbsolutePosition() async throws {
        let resumeStart = 600.0 - Metrics.resumeRewind
        let harness = try await start(
            item: try item(playbackPositionTicks: 600 * 10_000_000), method: .transcode)

        // 先不带 StartTimeTicks 取一次(它是服务端的决策输入),确认转码后带值重取
        let requests = await harness.preparer.startTicksRequests
        XCTAssertEqual(requests.count, 2, "转码 + 非零起播必须重取一次会话")
        XCTAssertNil(requests.first ?? nil)
        XCTAssertEqual(requests.last ?? nil, TickConverter.ticks(fromSeconds: resumeStart))

        XCTAssertTrue(harness.engine.seekTargets.isEmpty,
                      "转码已在起流时偏移过,⛔ 不能再客户端 seek 一次")
        XCTAssertEqual(harness.engine.loadedPlans.count, 1)

        // 内核从 0 开始报位置 → 绝对位置必须是起播点
        harness.engine.reportPosition(0)
        XCTAssertEqual(harness.viewModel.positionSeconds, resumeStart, accuracy: 0.001)
        harness.engine.reportPosition(5)
        XCTAssertEqual(harness.viewModel.positionSeconds, resumeStart + 5, accuracy: 0.001)
    }

    /// 上报的 `PositionTicks` 也必须是绝对位置 —— 这条错了会把服务端进度写回 0。
    func testTranscodeReportsAbsolutePositionTicks() async throws {
        let resumeStart = 600.0 - Metrics.resumeRewind
        let harness = try await start(
            item: try item(playbackPositionTicks: 600 * 10_000_000), method: .transcode)
        harness.engine.reportPosition(3)
        // 用一次会立即上报的交互把当前快照推出去(定时器在测试里是停的)
        harness.viewModel.selectAudioTrack(0)
        await harness.drainReports()

        let bodies = await harness.reporter.progressBodies
        let body = try XCTUnwrap(bodies.last)
        XCTAssertEqual(body.positionTicks, TickConverter.ticks(fromSeconds: resumeStart + 3))
        XCTAssertEqual(body.playMethod, PlaybackMethod.transcode.rawValue)
        XCTAssertFalse(body.canSeek, "转码流不能自由 seek(4.5)")
    }

    /// 总时长优先用服务端的 `RunTimeTicks`:转码起流后内核只剩「剩余那段」。
    func testDurationPrefersServerRuntime() async throws {
        let harness = try await start(item: try item(runTimeTicks: 1800 * 10_000_000))
        XCTAssertEqual(harness.viewModel.durationSeconds, 1800, accuracy: 0.001,
                       "服务端时长是权威值,不该用内核时长(转码起流后它只剩剩余部分)")

        // 服务端没给时长时退回内核读数(此处偏移 0)
        let fallback = try await start(item: try item())
        fallback.engine.reportDuration(42)
        XCTAssertEqual(fallback.viewModel.durationSeconds, 42, accuracy: 0.001)
    }

    func testBufferedPositionIsConvertedToAbsolute() async throws {
        let harness = try await start(
            item: try item(playbackPositionTicks: 600 * 10_000_000), method: .transcode)
        harness.engine.reportBuffered(8)
        XCTAssertEqual(try XCTUnwrap(harness.viewModel.bufferedUntilSeconds),
                       600 - Metrics.resumeRewind + 8, accuracy: 0.001,
                       "已缓冲范围也要过时间基 —— 进度条上的浅色段不能差一个起流点")
    }

    // MARK: - 起播偏好(倍速 / 音量 / 字幕模式)

    /// 内核是新建的(1× / 音量 100),起播偏好要在放流之前套上去。
    /// 倍速优先级:这部剧记过的 > 设置页默认 > 1×。
    func testStartupAppliesRememberedSpeedOverDefault() async throws {
        let harness = try await makeHarness()
        harness.container.preferences.defaultSpeed = 1.25
        harness.container.playbackSpeeds.remember(1.75, for: harness.item, on: harness.server)
        try await harness.run()

        XCTAssertEqual(harness.engine.setRates, [1.75],
                       "同一部剧记过的倍速优先于设置页的「默认倍速」")
        XCTAssertEqual(harness.viewModel.speed, 1.75, "起播倍速要如实反映在状态里")
    }

    func testStartupFallsBackToDefaultSpeed() async throws {
        let harness = try await makeHarness()
        harness.container.preferences.defaultSpeed = 1.5
        try await harness.run()
        XCTAssertEqual(harness.engine.setRates, [1.5])
    }

    /// 1× / 音量 100 是内核的默认值:⛔ 不发一次没有变化的设置。
    func testStartupSkipsRedundantSpeedAndVolume() async throws {
        let harness = try await makeHarness()
        try await harness.run()
        XCTAssertTrue(harness.engine.setRates.isEmpty)
        XCTAssertTrue(harness.engine.setVolumes.isEmpty)
    }

    func testStartupAppliesDefaultVolume() async throws {
        let harness = try await makeHarness()
        harness.container.preferences.defaultVolume = 40
        try await harness.run()
        XCTAssertEqual(harness.engine.setVolumes, [40])
    }

    /// 「中文优先」:简体 → 繁体 → 未标变体。选轨只做一次,且⛔ 不发
    /// `SubtitleTrackChange`(那是起播默认值,不是一次用户操作)。
    func testStartupPicksSimplifiedChineseSubtitleWithoutReporting() async throws {
        let harness = try await start()
        harness.engine.reportTracks([], [
            track(id: 0, lang: "eng", selected: true),
            track(id: 1, lang: "chi", title: "繁體中文"),
            track(id: 2, lang: "chi", title: "简体中文"),
        ])
        await harness.drainReports()

        XCTAssertEqual(harness.engine.subtitleSelections, [2], "简体优先")
        XCTAssertEqual(harness.viewModel.selectedSubtitleTrackID, 2)
        let bodies = await harness.reporter.progressBodies
        XCTAssertFalse(bodies.contains {
            $0.eventName == PlaybackEventName.subtitleTrackChange.rawValue
        }, "起播默认选轨不该被当成一次用户操作去上报")
    }

    /// 用户手动选过之后,起播偏好不再介入(否则轨道列表重推会把用户刚选的顶掉)。
    func testUserChosenSubtitleIsNotOverriddenByStartupPreference() async throws {
        let harness = try await start()
        harness.engine.reportTracks([], [
            track(id: 0, lang: "eng"),
            track(id: 1, lang: "chi", title: "简体中文"),
        ])
        XCTAssertEqual(harness.engine.subtitleSelections, [1])

        harness.viewModel.selectSubtitleTrack(nil)
        harness.engine.reportTracks([], [
            track(id: 0, lang: "eng"),
            track(id: 1, lang: "chi", title: "简体中文"),
        ])
        XCTAssertEqual(harness.engine.subtitleSelections, [1, nil],
                       "用户关掉字幕后不该被偏好再打开")
    }

    // MARK: - 倍速

    /// 「同一部剧沿用同一个倍速」:改一次倍速就记在 `PlaybackSpeedStore` 上,
    /// 同一部剧的下一集起播时套用。
    func testSpeedIsRememberedForTheSeriesAndUsedOnNextEpisode() async throws {
        let harness = try await start()
        harness.viewModel.setSpeed(1.5)

        XCTAssertEqual(harness.engine.setRates.last, 1.5)
        XCTAssertEqual(harness.container.playbackSpeeds.speed(for: harness.item, on: harness.server), 1.5)

        // 同一部剧的另一集(不同 Id、同一个 SeriesId),同一个容器 → 同一份倍速记录
        let second = try item(id: "E2")
        let next = try await makeHarness(
            item: second, container: harness.container, server: harness.server)
        try await next.run()
        XCTAssertEqual(next.engine.setRates, [1.5], "下一集要沿用这部剧的倍速")
    }

    /// 1× 等于「没设过」:手动调回正常速度后,这部剧的后面几集不该再弹回高倍速。
    func testSpeedBackToOneClearsRememberedValue() async throws {
        let harness = try await start()
        harness.viewModel.setSpeed(2)
        harness.viewModel.setSpeed(1)
        XCTAssertNil(harness.container.playbackSpeeds.speed(for: harness.item, on: harness.server))
    }

    /// 改倍速立即上报(`PlaybackRateChange`),但连续拖动要合并成一次。
    func testRateChangeIsReportedOnceAfterDraggingSettles() async throws {
        let harness = try await start()
        harness.viewModel.setSpeed(1.25)
        harness.viewModel.setSpeed(1.5)
        // 合并窗口 `Metrics.speedReportDelay` 之后再断言
        try await Task.sleep(for: .seconds(Metrics.speedReportDelay + 0.3))

        let rateChanges = await harness.reporter.progressBodies.filter {
            $0.eventName == PlaybackEventName.playbackRateChange.rawValue
        }
        XCTAssertEqual(rateChanges.count, 1, "一次拖动只发一次,值取最后那次")
        XCTAssertEqual(rateChanges.first?.playbackRate, 1.5)
    }

    // MARK: - 暂停 / 音量 / 轨道上报

    func testPauseResumeReportEventNamesAndDisplaySleepFollows() async throws {
        let harness = try await start()
        XCTAssertTrue(harness.viewModel.isPreventingDisplaySleep, "正在播放时持有显示器休眠断言")

        harness.viewModel.togglePlayPause()
        await harness.drainReports()
        XCTAssertEqual(harness.engine.pauseCount, 1)
        XCTAssertTrue(harness.viewModel.isPaused)
        XCTAssertFalse(harness.viewModel.isPreventingDisplaySleep, "暂停即释放断言")

        harness.viewModel.togglePlayPause()
        await harness.drainReports()
        XCTAssertEqual(harness.engine.playCount, 2)
        XCTAssertFalse(harness.viewModel.isPaused)
        XCTAssertTrue(harness.viewModel.isPreventingDisplaySleep, "恢复播放要重新持有")

        let names = await harness.reporter.progressBodies.compactMap(\.eventName)
        XCTAssertTrue(names.contains(PlaybackEventName.pause.rawValue))
        XCTAssertTrue(names.contains(PlaybackEventName.unpause.rawValue))
    }

    /// 播完时 `phase` 停在 `.playing`(状态机没有「已结束」态),所以断言必须靠
    /// `isEnded` 才能还回去 —— 否则「用户的 Mac 再也不息屏」。
    func testEndedReleasesDisplaySleepEvenThoughPhaseStaysPlaying() async throws {
        let harness = try await start()
        XCTAssertTrue(harness.viewModel.isPreventingDisplaySleep)

        harness.engine.reportEnded()
        XCTAssertTrue(harness.viewModel.isEnded)
        XCTAssertEqual(harness.viewModel.phase, .playing, "状态机里没有「已结束」态")
        XCTAssertFalse(harness.viewModel.isPreventingDisplaySleep)
    }

    func testVolumeChangeReportsVolumeEvent() async throws {
        let harness = try await start()
        harness.viewModel.setVolume(50)
        harness.viewModel.adjustVolume(by: Metrics.volumeStep)
        await harness.drainReports()

        XCTAssertEqual(harness.engine.setVolumes, [50, 50 + Metrics.volumeStep])
        let bodies = await harness.reporter.progressBodies
        XCTAssertTrue(bodies.contains {
            $0.eventName == PlaybackEventName.volumeChange.rawValue
        })
    }

    /// 音量夹在 0–100 内,不会超出去。
    func testVolumeIsClamped() async throws {
        let harness = try await start()
        harness.viewModel.adjustVolume(by: 100)
        XCTAssertEqual(harness.engine.setVolumes, [Metrics.volumeRange.upperBound])
        harness.viewModel.adjustVolume(by: -1000)
        XCTAssertEqual(harness.engine.setVolumes.last, Metrics.volumeRange.lowerBound)
    }

    /// 调音量顺带解除静音:静音时按 ↑ 却听不到声音,用户只会以为按键没生效。
    func testAdjustingVolumeUnmutes() async throws {
        let harness = try await start()
        harness.viewModel.toggleMute()
        XCTAssertTrue(harness.viewModel.isMuted)
        harness.viewModel.adjustVolume(by: -Metrics.volumeStep)
        XCTAssertFalse(harness.viewModel.isMuted)
    }

    /// DirectStream 的音轨索引要按 `StreamIndexMapper` 换算成 Emby 的
    /// `MediaStream.Index`(⛔ 不是容器轨道号,整体差一位 —— PITFALLS Q21)。
    func testAudioTrackSelectionReportsEmbyStreamIndex() async throws {
        let streams = [
            stream(index: 1, type: "Audio", codec: "aac"),
            stream(index: 3, type: "Audio", codec: "ac3"),
        ]
        let harness = try await start(streams: streams)
        harness.engine.reportTracks([
            track(id: 0, type: .audio, lang: "eng"),
            track(id: 1, type: .audio, lang: "jpn"),
        ], [])
        harness.viewModel.selectAudioTrack(1)
        await harness.drainReports()

        let bodies = await harness.reporter.progressBodies
        let body = try XCTUnwrap(bodies.last {
            $0.eventName == PlaybackEventName.audioTrackChange.rawValue
        })
        XCTAssertEqual(body.audioStreamIndex, 3, "第二条音轨对应 Index=3")
    }

    /// 转码流的轨道构成由服务端决定,与源文件不再一一对应 → ⛔ 不上报索引
    /// (不报胜过报一个错位的值)。
    func testTranscodeOmitsStreamIndexes() async throws {
        let streams = [stream(index: 1, type: "Audio", codec: "aac")]
        let harness = try await start(streams: streams, method: .transcode)
        harness.engine.reportTracks([track(id: 0, type: .audio, lang: "eng")], [])
        harness.viewModel.selectAudioTrack(0)
        await harness.drainReports()

        let bodies = await harness.reporter.progressBodies
        let body = try XCTUnwrap(bodies.last {
            $0.eventName == PlaybackEventName.audioTrackChange.rawValue
        })
        XCTAssertNil(body.audioStreamIndex)
    }

    // MARK: - seek 分派

    /// DirectStream:交给内核 seek,并立即上报(`TimeUpdate`)。
    func testDirectStreamSeekGoesToKernelAndReportsImmediately() async throws {
        let harness = try await start()
        harness.engine.reportDuration(600)
        harness.viewModel.seek(to: 120)
        await harness.viewModel.waitForSeekToFinish()
        await harness.drainReports()

        XCTAssertEqual(harness.engine.seekTargets.last, 120)
        XCTAssertEqual(harness.viewModel.positionSeconds, 120)
        XCTAssertEqual(harness.engine.loadCount, 1, "DirectStream 不该重新起流")
        let bodies = await harness.reporter.progressBodies
        XCTAssertTrue(bodies.contains {
            $0.eventName == PlaybackEventName.timeUpdate.rawValue
        })
    }

    /// 转码:不能客户端 seek —— 停流 + 拆内核 + 带新的 `StartTimeTicks` 重新起流。
    func testTranscodeSeekRestartsStreamWithNewStartTicks() async throws {
        let harness = try await start(method: .transcode)
        harness.engine.reportDuration(1800)

        harness.viewModel.seek(to: 300)
        XCTAssertTrue(harness.viewModel.isRestarting, "转码 seek 期间要给准话(正在起流)")
        // 合并窗口 `Metrics.seekRestartMergeDelay` 之后才真的起流
        try await Task.sleep(for: .seconds(Metrics.seekRestartMergeDelay + 0.6))

        XCTAssertEqual(harness.engine.loadCount, 2, "转码 seek = 拆掉重建")
        XCTAssertEqual(harness.engine.teardownCount, 1)
        let requests = await harness.preparer.startTicksRequests
        XCTAssertEqual(requests.last ?? nil, TickConverter.ticks(fromSeconds: 300))
        XCTAssertTrue(harness.engine.seekTargets.isEmpty, "重新起流靠 StartTimeTicks,不是客户端 seek")
    }

    /// 连点前进(转码)只该起一次流 —— 一次重新起流是 ~4 个请求。
    func testTranscodeSeekCoalescesRapidSeeks() async throws {
        let harness = try await start(method: .transcode)
        harness.engine.reportDuration(1800)

        harness.viewModel.seek(to: 100)
        harness.viewModel.seek(to: 200)
        harness.viewModel.seek(to: 300)
        try await Task.sleep(for: .seconds(Metrics.seekRestartMergeDelay + 0.6))

        XCTAssertEqual(harness.engine.loadCount, 2, "三次连点只重新起一次流")
        let requests = await harness.preparer.startTicksRequests
        XCTAssertEqual(requests.last ?? nil, TickConverter.ticks(fromSeconds: 300), "值取最后一次")
    }

    /// 跳转目标夹在 `[0, duration]` 内(拖到最右不会越过总长)。
    func testSeekIsClampedToDuration() async throws {
        let harness = try await start()
        harness.engine.reportDuration(600)
        harness.viewModel.seek(to: 9999)
        XCTAssertEqual(harness.viewModel.positionSeconds, 600)
        harness.viewModel.seek(to: -50)
        XCTAssertEqual(harness.viewModel.positionSeconds, 0)
    }

    // MARK: - 播完 / 下一集 / 收尾

    /// 播完按设置倒计时播下一集。
    func testEndedStartsCountdownForNextEpisode() async throws {
        let harness = try await start(episodesJSON: episodesJSON)
        try await harness.waitForNextEpisode()
        XCTAssertEqual(harness.viewModel.nextEpisode?.id, "E2")

        harness.engine.reportEnded()
        XCTAssertEqual(harness.viewModel.upNextCountdown, Metrics.upNextCountdown)
    }

    /// 取消倒计时之后本次播放不再提示、不再自动播下一集。
    func testDismissUpNextStopsCountdown() async throws {
        let harness = try await start(episodesJSON: episodesJSON)
        try await harness.waitForNextEpisode()
        harness.engine.reportEnded()
        harness.viewModel.dismissUpNext()

        XCTAssertTrue(harness.viewModel.isUpNextDismissed)
        XCTAssertNil(harness.viewModel.upNextCountdown)
        XCTAssertFalse(harness.viewModel.isUpNextPromptVisible)
    }

    /// 关窗 / 切媒体:补一次最终 Progress 再发 Stopped(ARCHITECTURE.md 6.6),
    /// 发完才算结束 —— 详情页要等这个信号才去重读进度(PITFALLS Q22)。
    func testStopSendsFinalProgressThenStopped() async throws {
        let harness = try await start()
        harness.engine.reportPosition(75)
        harness.viewModel.stop()
        await harness.viewModel.waitUntilReportingFinished()

        let bodies = await harness.reporter.progressBodies
        let last = try XCTUnwrap(bodies.last)
        XCTAssertEqual(last.eventName, PlaybackEventName.timeUpdate.rawValue,
                       "关窗要先补一次最终 Progress")
        XCTAssertEqual(last.positionTicks, TickConverter.ticks(fromSeconds: 75))
        let stopped = await harness.reporter.stoppedBody
        XCTAssertEqual(stopped?.positionTicks, TickConverter.ticks(fromSeconds: 75))
        XCTAssertEqual(harness.engine.teardownCount, 1)
        XCTAssertFalse(harness.viewModel.isPreventingDisplaySleep)
    }

    /// 自然播完直接发 Stopped(位置就是最终位置),不补 Progress。
    func testEndedSendsStoppedWithoutFinalProgress() async throws {
        let harness = try await start()
        harness.engine.reportPosition(90)
        harness.engine.reportEnded()
        await harness.viewModel.waitUntilReportingFinished()

        let stopped = await harness.reporter.stoppedBody
        XCTAssertEqual(stopped?.positionTicks, TickConverter.ticks(fromSeconds: 90))
        let bodies = await harness.reporter.progressBodies
        XCTAssertFalse(bodies.contains {
            $0.eventName == PlaybackEventName.timeUpdate.rawValue
        }, "播完不补 Progress,位置随 Stopped 走")
    }

    // MARK: - 失败

    func testEngineFailureBecomesUserVisibleMessage() async throws {
        let engine = FakePlaybackEngine()
        engine.loadFailure = .missingTracks(["音频"])
        let harness = try await makeHarness(engine: engine)
        try await harness.run()

        let failure = try XCTUnwrap(harness.viewModel.failure)
        XCTAssertTrue(failure.message.contains("音频"), "文案要点名缺哪一维:\(failure.message)")
        XCTAssertFalse(failure.needsLogin, "静默删轨不是登录问题")
    }

    /// 决策失败(Rust 侧抛的)文案原样上屏,⛔ Swift 不重拼一份。
    func testDecisionFailureMessageComesFromRust() async throws {
        let preparer = FakeSessionPreparer(error: PlaybackFailureFfi.NoPlayablePath(
            message: "这台服务器对该文件既不支持直接串流,也没有给出转码地址。"))
        let harness = try await makeHarness(preparer: preparer)
        try await harness.run()

        XCTAssertEqual(
            harness.viewModel.failure?.message,
            "这台服务器对该文件既不支持直接串流,也没有给出转码地址。")
    }

    /// 上一轮内核的迟到事件必须被代次门丢弃(否则新会话会被上一轮的错误污染)。
    func testStaleGenerationEventsAreDropped() async throws {
        let harness = try await start()
        harness.viewModel.stop()

        harness.viewModel.handle(.failed(.playback("上一轮的失败")), generation: 0)
        harness.viewModel.handle(.tracksValidated(.satisfied), generation: 0)

        XCTAssertNil(harness.viewModel.failure, "已拆掉的那一轮的事件不该写进来")
        XCTAssertNil(harness.viewModel.trackValidation)
    }

    // MARK: - 触控板横滑

    /// 横滑只累加预览(不 seek),松手才 seek 一次 —— 转码下一次 seek 就是一次重新起流。
    func testScrubPreviewDefersSeekUntilCommit() async throws {
        let harness = try await start()
        harness.engine.reportDuration(600)
        harness.engine.reportPosition(100)

        harness.viewModel.previewScrub(by: 30)
        harness.viewModel.previewScrub(by: 30)
        XCTAssertEqual(try XCTUnwrap(harness.viewModel.scrubPreviewSeconds), 160, accuracy: 0.001)
        XCTAssertEqual(harness.viewModel.positionSeconds, 100, "预览期间不动真实位置")
        XCTAssertTrue(harness.engine.seekTargets.isEmpty, "预览期间不 seek")

        harness.viewModel.commitScrub()
        await harness.viewModel.waitForSeekToFinish()
        XCTAssertNil(harness.viewModel.scrubPreviewSeconds)
        XCTAssertEqual(harness.engine.seekTargets.last, 160)
    }

    /// 预览位置夹在 `[0, duration]` 内;时长未知时不响应。
    func testScrubPreviewIsClampedAndIgnoresUnknownDuration() async throws {
        let harness = try await start()

        harness.viewModel.previewScrub(by: 30)
        XCTAssertNil(harness.viewModel.scrubPreviewSeconds, "时长未知时不响应横滑")

        harness.engine.reportDuration(100)
        harness.viewModel.previewScrub(by: 500)
        XCTAssertEqual(try XCTUnwrap(harness.viewModel.scrubPreviewSeconds), 100, accuracy: 0.001)
        harness.viewModel.previewScrub(by: -500)
        XCTAssertEqual(try XCTUnwrap(harness.viewModel.scrubPreviewSeconds), 0, accuracy: 0.001)
        harness.viewModel.commitScrub()
    }

    // MARK: - 轨道核验结论

    func testTrackValidationOutcomeIsMirrored() async throws {
        let harness = try await start()
        harness.viewModel.handle(
            .tracksValidated(.unverifiable), generation: harness.viewModel.currentGeneration)
        XCTAssertEqual(harness.viewModel.trackValidation, .unverifiable,
                       "「判不了」要如实记下来,⛔ 不等于核实过没问题")
    }

    // MARK: - 观测台

    /// 一次「起播 + 等落定」的观测台。持有的替身就是注入给 ViewModel 的那几个,
    /// 所以断言看到的就是播放页实际用到的对象。
    @MainActor
    struct Harness {
        let viewModel: PlayerViewModel
        let engine: FakePlaybackEngine
        let preparer: FakeSessionPreparer
        let reporter: RecordingReporter
        let container: AppContainer
        let item: EmbyItem
        let server: ServerProfile

        /// 起播并等到准备工作跑完;成功时再报一次 `.playing` ——
        /// 真实播放页在这个点才开始上报(`reporter.begin`)。
        func run() async throws {
            viewModel.start()
            try await waitUntil("准备工作完成") { !self.viewModel.isPreparing }
            guard viewModel.failure == nil else { return }
            engine.reportPhase(.playing)
            await drainReports()
        }

        func waitForNextEpisode() async throws {
            try await waitUntil("查到下一集") { self.viewModel.nextEpisode != nil }
        }

        /// 等上报队列发完(入队 → runner 取出 → send 各一跳)
        func drainReports() async {
            try? await Task.sleep(for: .milliseconds(80))
        }

        func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("等待超时:\(what)")
        }
    }

    // MARK: - 造场景

    /// 只建场景,不起播 —— 需要先改偏好(默认倍速 / 音量 / 字幕模式)的用例走这条。
    private func makeHarness(
        item: EmbyItem? = nil,
        streams: [EmbyMediaStream] = [],
        method: PlaybackMethod = .directStream,
        startFromBeginning: Bool = false,
        engine: FakePlaybackEngine? = nil,
        preparer: FakeSessionPreparer? = nil,
        container: AppContainer? = nil,
        server: ServerProfile? = nil,
        episodesJSON: String? = nil
    ) async throws -> Harness {
        let container = try container ?? makeContainer()
        // ⛔ 不能写成 `server ?? preparedProfile()`:`??` 的右值是 autoclosure,装不下 `await`
        let server: ServerProfile = if let server { server } else { try await preparedProfile() }
        // 相邻集查询走 `Shows/{Id}/Episodes`;替身 URLProtocol 按路径喂一条
        if let episodesJSON {
            MockEmbyURLProtocol.stub(.json(episodesJSON), path: "/emby/Shows/S1/Episodes")
        }
        let item = try item ?? self.item()
        let engine = engine ?? FakePlaybackEngine()
        let preparer = preparer ?? FakeSessionPreparer(
            sessions: [session(method: method, streams: streams)])
        let reporter = RecordingReporter()
        let viewModel = PlayerViewModel(
            container: container,
            source: .emby(server: server, item: item),
            startFromBeginning: startFromBeginning,
            engine: engine,
            sessionPreparer: preparer,
            reporter: await reporter.makeReporter(),
            displaySleep: FakeDisplaySleep()
        )
        return Harness(
            viewModel: viewModel, engine: engine, preparer: preparer, reporter: reporter,
            container: container, item: item, server: server
        )
    }

    /// 建场景并起播(多数用例走这条)。
    private func start(
        item: EmbyItem? = nil,
        streams: [EmbyMediaStream] = [],
        method: PlaybackMethod = .directStream,
        episodesJSON: String? = nil
    ) async throws -> Harness {
        let harness = try await makeHarness(
            item: item, streams: streams, method: method, episodesJSON: episodesJSON)
        try await harness.run()
        return harness
    }

    private func makeContainer() throws -> AppContainer {
        AppContainer(
            registry: try ServerRegistry(
                defaults: UserDefaults(suiteName: "test.LumaPlayer.wiring.\(UUID().uuidString)")!,
                credentials: credentials
            ),
            credentials: credentials,
            session: MockEmbyURLProtocol.makeSession(),
            preferences: UserDefaults(suiteName: "test.LumaPlayer.wiring.prefs.\(UUID().uuidString)")!
        )
    }

    /// 带 `userID` + `/emby` 前缀 + 已存 token 的档案:相邻集查询要真的过一遍
    /// 鉴权路径(替身 URLProtocol 按路径应答),所以 token 必须先存好
    /// (否则 `ensureCredentials` 直接抛 `.unauthorized`)。
    private func preparedProfile() async throws -> ServerProfile {
        let profile = ServerProfile(
            displayName: "emby.test",
            baseURL: URL(string: "https://emby.test")!,
            apiPathPrefix: "/emby",
            userID: "U1",
            deviceID: "DEVICE-UUID-1"
        )
        try await credentials.saveToken("TEST-TOKEN", forServer: profile.id)
        return profile
    }

    /// 相邻两集:E1 是正在播的那一集,紧跟其后的是 E2。
    private var episodesJSON: String {
        #"{"Items":[{"Id":"E1","Name":"E1","Type":"Episode"},"#
            + #"{"Id":"E2","Name":"E2","Type":"Episode"}]}"#
    }

    private func item(
        id: String = "E1",
        type: String = "Episode",
        runTimeTicks: Int64? = nil,
        playbackPositionTicks: Int64? = nil
    ) throws -> EmbyItem {
        var json = #"{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)","SeriesId":"S1","SeasonId":"SE1""#
        if let runTimeTicks { json += #","RunTimeTicks":\#(runTimeTicks)"# }
        if let playbackPositionTicks {
            json += #","UserData":{"PlaybackPositionTicks":\#(playbackPositionTicks)}"#
        }
        json += "}"
        return try JSONDecoder().decode(EmbyItem.self, from: Data(json.utf8))
    }

    private func session(method: PlaybackMethod, streams: [EmbyMediaStream]) -> PlaybackSession {
        let url = URL(string: "https://emby.test/emby/videos/1/stream")!
        let source = EmbyMediaSource(
            id: "ms1",
            container: "mp4",
            supportsDirectStream: method == .directStream,
            supportsTranscoding: true,
            transcodingUrl: nil,
            mediaStreams: streams,
            chapters: nil,
            directStreamUrl: "/emby/videos/1/stream.mp4"
        )
        let decision = PlaybackDecisionFfi(
            method: method.rawValue,
            methodDisplayName: method == .directStream ? "直接串流" : "服务端转码",
            mediaSourceId: "ms1",
            playSessionId: "ps1",
            directStreamUrl: method == .directStream ? "/emby/videos/1/stream.mp4" : nil,
            transcodingUrl: method == .transcode ? "/emby/videos/1/master.m3u8" : nil,
            transcodingSubProtocol: method == .transcode ? "hls" : nil,
            audit: PlaybackAuditFfi(
                pathActions: [], subtitleAction: nil, unverifiableDimensions: [], notes: []),
            capabilityRevision: "avkit-capability/test"
        )
        return PlaybackSession(
            plan: method == .directStream
                ? .directStream(url: url, headers: [:], playSessionID: "ps1", mediaSourceID: "ms1")
                : .transcode(url: url, headers: [:], playSessionID: "ps1", mediaSourceID: "ms1"),
            mediaSource: source,
            decision: decision,
            // 与 `PlaybackSessionCoordinator` 同一条规则:Emby 的直连是客户端
            // seek,转码是停流 + StartTimeTicks 重新起流。
            seekStrategy: method == .directStream ? .clientSeek : .restartStream
        )
    }

    private func stream(index: Int, type: String, codec: String) -> EmbyMediaStream {
        EmbyMediaStream(
            index: index, type: type, codec: codec, language: nil,
            isDefault: nil, isTextSubtitleStream: nil, isExternal: nil,
            displayTitle: nil, title: nil, width: nil, height: nil, channels: nil
        )
    }

    private func track(
        id: Int,
        type: PlaybackTrackType = .sub,
        lang: String?,
        title: String? = nil,
        selected: Bool = false
    ) -> PlaybackTrack {
        PlaybackTrack(
            id: id, type: type, selected: selected, title: title,
            lang: lang, codec: nil, isExternal: false, isForced: false
        )
    }
}
