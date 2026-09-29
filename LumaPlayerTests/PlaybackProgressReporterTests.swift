import XCTest
@testable import LumaPlayer

/// `PlaybackProgressReporter` 的串行化、代次门与失败策略
/// (API_CONTRACT.md 5.3、5.4;ARCHITECTURE.md 6.6)。
///
/// 全部用注入的 `send` / `sleeper`,**零网络、零真实 10 秒等待** ——
/// 间隔是断言出来的,不是等出来的(注入的 sleeper 立即返回,只记录时长)。
///
/// ⚠️ 所有 actor 读取都要先取到局部常量再断言:`await` 不能出现在
/// `XCTAssert` 的 autoclosure 里(与 `PlaybackSessionCoordinatorTests` 同因)。
final class PlaybackProgressReporterTests: XCTestCase {

    /// 记录「发了什么」与「睡了多久」。用 actor 而不是 `@unchecked Sendable`
    /// 的盒子:后者是 ARCHITECTURE.md 3.1.2 禁止的手段,测试代码也不例外。
    private actor Recorder {
        private(set) var entered: [EmbyEndpoint] = []
        private(set) var sent: [EmbyEndpoint] = []
        private(set) var sleeps: [TimeInterval] = []
        private var blocked = false
        private var shouldFail = false

        func block() { blocked = true }
        func unblock() { blocked = false }
        func failNext(_ value: Bool) { shouldFail = value }

        func record(_ endpoint: EmbyEndpoint) async throws {
            entered.append(endpoint)
            var waited = 0
            while blocked, waited < 400 {
                try? await Task.sleep(for: .milliseconds(5))
                waited += 1
            }
            if shouldFail { throw ReporterFailure() }
            sent.append(endpoint)
        }

        func recordSleep(_ interval: TimeInterval) {
            sleeps.append(interval)
        }

        func snapshot() -> Snapshot {
            Snapshot(entered: entered, sent: sent, sleeps: sleeps)
        }

        struct Snapshot: Sendable {
            let entered: [EmbyEndpoint]
            let sent: [EmbyEndpoint]
            let sleeps: [TimeInterval]
        }
    }

    private struct ReporterFailure: Error {}

    private static let contextA = PlaybackReportContext(
        itemID: "ITEM-A",
        mediaSourceID: "SOURCE-A",
        playSessionID: "SESSION-A",
        method: .directStream
    )
    private static let contextB = PlaybackReportContext(
        itemID: "ITEM-B",
        mediaSourceID: "SOURCE-B",
        playSessionID: "SESSION-B",
        method: .transcode
    )
    private static let state = PlaybackReportState(
        positionSeconds: 60,
        isPaused: false,
        isMuted: false,
        volume: 80,
        audioStreamIndex: 2,
        subtitleStreamIndex: nil
    )

    // MARK: - 字段(5.1)

    /// 开始播放:`POST /Sessions/Playing`,字段与 5.1 的表逐项对齐。
    func testBeginSendsPlayingWithFullBody() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        await reporter.begin(context: Self.contextA, state: Self.state)
        await waitUntil(count: 1, recorder: recorder)

        let first = await recorder.snapshot().sent.first
        let endpoint = try? XCTUnwrap(first)
        let body = endpoint.flatMap(reportBody)
        XCTAssertEqual(endpoint?.path, "/Sessions/Playing")
        XCTAssertEqual(endpoint?.method, "POST")
        XCTAssertEqual(body?.itemID, "ITEM-A")
        XCTAssertEqual(body?.mediaSourceID, "SOURCE-A")
        XCTAssertEqual(body?.playSessionID, "SESSION-A")
        XCTAssertEqual(body?.playMethod, "DirectStream")
        // 60s × 10_000_000(8.3 的换算,唯一出处是 TickConverter)
        XCTAssertEqual(body?.positionTicks, 600_000_000)
        XCTAssertEqual(body?.isPaused, false)
        XCTAssertEqual(body?.isMuted, false)
        XCTAssertEqual(body?.volumeLevel, 80)
        // DirectStream 可自由 seek(4.5)
        XCTAssertEqual(body?.canSeek, true)
        XCTAssertEqual(body?.audioStreamIndex, 2)
        XCTAssertNil(body?.subtitleStreamIndex)
        XCTAssertEqual(body?.queueableMediaTypes, ["Video"])
        XCTAssertEqual(body?.playbackRate, 1)
        // 5.1:EventName 只有 Progress 才有
        XCTAssertNil(body?.eventName)

        await reporter.finish(finalState: Self.state, sendFinalProgress: false)
    }

    /// 转码会话的 `CanSeek` 必须是 false(4.5:转码流不能客户端 seek)。
    func testTranscodeSessionReportsCanSeekFalse() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        await reporter.begin(context: Self.contextB, state: Self.state)
        await waitUntil(count: 1, recorder: recorder)

        let body = await recorder.snapshot().sent.first.flatMap(reportBody)
        XCTAssertEqual(body?.playMethod, "Transcode")
        XCTAssertEqual(body?.canSeek, false)

        await reporter.finish(finalState: Self.state, sendFinalProgress: false)
    }

    /// 暂停 / 切轨的即时上报走 Progress,并带 5.2 的 EventName。
    func testInteractiveReportUsesProgressWithEventName() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        await reporter.begin(context: Self.contextA, state: Self.state)
        await waitUntil(count: 1, recorder: recorder)
        await reporter.reportNow(eventName: .pause)
        await reporter.reportNow(eventName: .audioTrackChange)
        await waitUntil(count: 3, recorder: recorder)

        let sent = await recorder.snapshot().sent
        XCTAssertEqual(sent.map { $0.path },
                       ["/Sessions/Playing",
                        "/Sessions/Playing/Progress",
                        "/Sessions/Playing/Progress"])
        XCTAssertEqual(sent.dropFirst().compactMap { reportBody($0)?.eventName },
                       ["Pause", "AudioTrackChange"])

        await reporter.finish(finalState: Self.state, sendFinalProgress: false)
    }

    /// 改倍速:立即 Progress,带 `PlaybackRateChange` 与新的 `PlaybackRate`(5.1、5.2)。
    func testRateChangeReportCarriesNewRate() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        await reporter.begin(context: Self.contextA, state: Self.state)
        await waitUntil(count: 1, recorder: recorder)
        var faster = Self.state
        faster.playbackRate = 1.5
        await reporter.update(faster)
        await reporter.reportNow(eventName: .playbackRateChange)
        await waitUntil(count: 2, recorder: recorder)

        let body = await recorder.snapshot().sent.last.flatMap(reportBody)
        XCTAssertEqual(body?.eventName, "PlaybackRateChange")
        XCTAssertEqual(body?.playbackRate, 1.5)

        await reporter.finish(finalState: faster, sendFinalProgress: false)
    }

    // MARK: - 频率(5.3)

    /// 定时上报固定 10 秒。⛔ 不得为「更精确」改成 1–2 秒 —— 官方原文
    /// 「not necessary to automatically report more often than at 10 second
    /// intervals」。这条用例就是那条约束的守门员。
    func testTimerIntervalIsAlwaysTenSeconds() async {
        XCTAssertEqual(PlaybackProgressReporter.reportInterval, 10)

        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        await reporter.begin(context: Self.contextA, state: Self.state)
        await waitUntil(count: 2, recorder: recorder)

        let snapshot = await recorder.snapshot()
        XCTAssertFalse(snapshot.sleeps.isEmpty, "定时器应至少走完一个周期")
        XCTAssertTrue(snapshot.sleeps.allSatisfy { $0 == 10 },
                      "每次等待必须恒为 10 秒,实际: \(snapshot.sleeps)")
        XCTAssertEqual(snapshot.sent.last.flatMap(reportBody)?.eventName, "TimeUpdate")

        await reporter.finish(finalState: Self.state, sendFinalProgress: false)
    }

    // MARK: - 串行化与代次(5.4)

    /// 快速切媒体:旧会话**排队中**的条目必须丢弃。
    ///
    /// 已经在飞的那一条(第一个 Playing)拦不住,也不必拦 —— 5.4 要求的是
    /// 「丢弃旧 generation 的未完成请求**结果**」,而上报结果不改变任何状态。
    /// 关键是 A 的两次 Progress 一次都不能发出去,否则上一部片的进度会盖到
    /// 这一部上(多服务器场景下就是串台)。
    func testQueuedEntriesFromOldGenerationAreDiscarded() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)
        await recorder.block()

        await reporter.begin(context: Self.contextA, state: Self.state)
        // 等第一条真正在飞(否则「切媒体」可能发生在它出队之前,用例就不确定了)
        await waitUntilEntered(count: 1, recorder: recorder)
        await reporter.reportNow(eventName: .pause)
        await reporter.reportNow(eventName: .unpause)

        // 切媒体:generation +1,上面两条还没发出去
        await reporter.begin(context: Self.contextB, state: Self.state)
        await recorder.unblock()
        await waitUntil(count: 2, recorder: recorder)

        let sent = await recorder.snapshot().sent
        XCTAssertEqual(sent.map { $0.path }, ["/Sessions/Playing", "/Sessions/Playing"])
        XCTAssertEqual(sent.compactMap { reportBody($0)?.playSessionID },
                       ["SESSION-A", "SESSION-B"])
        let pending = await reporter.pendingCount
        XCTAssertEqual(pending, 0)

        await reporter.finish(finalState: Self.state, sendFinalProgress: false)
    }

    /// 结束会话(关窗 / 切媒体):最终 Progress + Stopped,Stopped 用最终位置。
    func testFinishSendsFinalProgressThenStopped() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        await reporter.begin(context: Self.contextA, state: Self.state)
        await waitUntil(count: 1, recorder: recorder)
        await reporter.finish(
            finalState: PlaybackReportState(
                positionSeconds: 120, isPaused: true, isMuted: false,
                volume: 80, audioStreamIndex: nil, subtitleStreamIndex: nil),
            sendFinalProgress: true)
        await waitUntil(count: 3, recorder: recorder)

        let sent = await recorder.snapshot().sent
        XCTAssertEqual(sent.map { $0.path },
                       ["/Sessions/Playing",
                        "/Sessions/Playing/Progress",
                        "/Sessions/Playing/Stopped"])
        // ARCHITECTURE.md 6.6:Stopped 用最终位置
        let stopped = sent.last.flatMap(reportBody)
        XCTAssertEqual(stopped?.positionTicks, 1_200_000_000)
        XCTAssertEqual(stopped?.isPaused, true)
    }

    /// 自然播完:直接 Stopped,不再补一次 Progress(6.6)。
    func testNaturalEndSendsStoppedOnly() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        await reporter.begin(context: Self.contextA, state: Self.state)
        await waitUntil(count: 1, recorder: recorder)
        await reporter.finish(finalState: Self.state, sendFinalProgress: false)
        await waitUntil(count: 2, recorder: recorder)

        let sent = await recorder.snapshot().sent
        XCTAssertEqual(sent.map { $0.path },
                       ["/Sessions/Playing", "/Sessions/Playing/Stopped"])
    }

    /// 结束后定时器必须停:否则关窗之后还会继续往上报。
    func testFinishStopsTimer() async throws {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        await reporter.begin(context: Self.contextA, state: Self.state)
        await waitUntil(count: 1, recorder: recorder)
        await reporter.finish(finalState: Self.state, sendFinalProgress: false)
        await waitUntil(count: 2, recorder: recorder)

        let before = await recorder.snapshot().sleeps.count
        // 注入的 sleeper 立即返回,所以定时器若还活着,这一段会跑出很多次等待
        try? await Task.sleep(for: .milliseconds(150))
        let after = await recorder.snapshot().sleeps.count
        XCTAssertEqual(after, before, "定时器未随会话结束停止")
    }

    // MARK: - drain(docs/PITFALLS.md Q22)

    /// 关窗后详情页要等 Stopped 真正发完再向服务端重读续播位置。
    /// `drain()` 必须等到**正卡在网络上**的 Stopped 结束才返回 ——
    /// 只等到「已入队」是不够的,那正是 Q22 里读回旧进度的时序。
    func testDrainWaitsUntilStoppedIsActuallySent() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        await reporter.begin(context: Self.contextA, state: Self.state)
        await waitUntil(count: 1, recorder: recorder)
        await recorder.block()
        await reporter.finish(finalState: Self.state, sendFinalProgress: true)
        // 最终 Progress 已进入发送并卡住,Stopped 还在队里
        await waitUntilEntered(count: 2, recorder: recorder)

        let drained = Task { await reporter.drain() }
        try? await Task.sleep(for: .milliseconds(100))
        let sentWhileBlocked = await recorder.snapshot().sent.count
        XCTAssertEqual(sentWhileBlocked, 1, "卡住期间不应有新的请求被记为已发")

        await recorder.unblock()
        await drained.value

        // drain 返回时 Stopped 必须已经发出,不能靠再等一会儿
        let sent = await recorder.snapshot().sent
        XCTAssertEqual(sent.map { $0.path },
                       ["/Sessions/Playing",
                        "/Sessions/Playing/Progress",
                        "/Sessions/Playing/Stopped"])
    }

    /// 没有待发条目时立即返回,不能挂住关窗后的回调。
    func testDrainReturnsImmediatelyWhenIdle() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        await reporter.drain()

        let sent = await recorder.snapshot().sent
        XCTAssertTrue(sent.isEmpty)
    }

    /// Stopped 失败也算「处理完」:drain 不能因为上报失败而永远不返回
    /// (5.4:失败不阻塞 —— 关窗后的详情刷新同样不该被它卡住)。
    func testDrainReturnsEvenWhenStoppedFails() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        await reporter.begin(context: Self.contextA, state: Self.state)
        await waitUntil(count: 1, recorder: recorder)
        await recorder.failNext(true)
        await reporter.finish(finalState: Self.state, sendFinalProgress: false)
        await reporter.drain()

        let entered = await recorder.snapshot().entered
        XCTAssertEqual(entered.last?.path, "/Sessions/Playing/Stopped")
        let failure = await reporter.lastFailureDescription
        XCTAssertNotNil(failure)
    }

    // MARK: - 失败策略(5.4)

    /// 上报失败:入口都不抛(不阻塞播放、不弹窗),记下失败后下次照常尝试。
    func testFailureIsRecordedAndDoesNotStopLaterReports() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)
        await recorder.failNext(true)

        await reporter.begin(context: Self.contextA, state: Self.state)
        await waitUntilFailure(reporter: reporter)

        let sentAfterFailure = await recorder.snapshot().sent.count
        XCTAssertEqual(sentAfterFailure, 0, "失败的请求不应被记为成功")
        let failure = await reporter.lastFailureDescription
        XCTAssertNotNil(failure)

        // 下一次机会照常补报(5.4:记录最后一次失败,下次机会补报)
        await recorder.failNext(false)
        await reporter.reportNow(eventName: .timeUpdate)
        await waitUntil(count: 1, recorder: recorder)
        let clearedFailure = await reporter.lastFailureDescription
        XCTAssertNil(clearedFailure, "成功后应清掉失败记录")
        let sent = await recorder.snapshot().sent
        XCTAssertEqual(sent.first.flatMap(reportBody)?.eventName, "TimeUpdate")

        await reporter.finish(finalState: Self.state, sendFinalProgress: false)
    }

    // MARK: - 辅助

    /// - Parameter realSleep: 注入的 sleeper 额外真实等待的时长。
    ///   定时器在注入 sleeper 下会**立即**返回(否则每条用例都要等 10 秒),
    ///   结果就是它以最快速度循环上报,把用例的期望搅乱。给一个远长于
    ///   单条用例耗时的真实等待,定时器在断言期间就至多走一轮。
    private func makeReporter(recorder: Recorder, realSleep: TimeInterval = 0.5) -> PlaybackProgressReporter {
        PlaybackProgressReporter(
            send: { endpoint in try await recorder.record(endpoint) },
            sleeper: { interval in
                await recorder.recordSleep(interval)
                // ⛔ 不要写 `try?`:吞掉取消会让定时器在会话结束后
                // 继续跑一轮(真实 `Task.sleep` 会把取消抛出来)
                try await Task.sleep(for: .seconds(realSleep))
            }
        )
    }

    private func reportBody(_ endpoint: EmbyEndpoint) -> PlaybackReportBody? {
        guard case .playbackReport(let body) = endpoint.body else { return nil }
        return body
    }

    /// 等到已成功发出 `count` 条(轮询,不用固定 sleep 赌时序)。
    private func waitUntil(count: Int, recorder: Recorder, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = await recorder.snapshot().sent.count
            if current >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let current = await recorder.snapshot().sent.count
        XCTAssertGreaterThanOrEqual(current, count, "等待已发送条数超时")
    }

    /// 等到有 `count` 条**进入**发送(可能正卡在那里),用于制造确定的时序。
    private func waitUntilEntered(count: Int, recorder: Recorder, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = await recorder.snapshot().entered.count
            if current >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let current = await recorder.snapshot().entered.count
        XCTAssertGreaterThanOrEqual(current, count, "等待进入发送条数超时")
    }

    private func waitUntilFailure(
        reporter: PlaybackProgressReporter,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let failure = await reporter.lastFailureDescription
            if failure != nil { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let failure = await reporter.lastFailureDescription
        XCTAssertNotNil(failure, "等待上报失败超时")
    }
}
