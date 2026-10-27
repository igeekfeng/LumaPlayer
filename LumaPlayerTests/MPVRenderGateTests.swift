import AppKit
import XCTest
@testable import LumaPlayer

/// 视频层只在需要时 render(`MPVPlayer.needsRender`,Q49):暂停后不再画;layer 尺寸变了照样重画一次(靠 `requestRender()`)。
/// 出帧不依赖主线程;displayLink 报的 swap 让 VO 不因等待超时丢帧。
/// 要真窗口 + GPU(没有会失败而不是 skip);只数 draw 次数与丢帧数,不验出帧节奏、音画同步、能耗。
@MainActor
final class MPVRenderGateTests: XCTestCase {

    /// 真窗口里挂一个视频层、起播 fixture,等到第一帧真实视频帧。调用方负责 `teardown()`。
    private func startPlayback() async throws -> (player: MPVPlayer, view: MPVLayerView, teardown: () -> Void) {
        let url = try XCTUnwrap(fixtureURL("sdr_hevc_synthetic.mp4"), "找不到 fixture")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        container.wantsLayer = true
        window.contentView = container

        let player = MPVPlayer()
        let teardown = {
            window.orderOut(nil)
            window.contentView = nil
            player.shutdown()
        }
        guard player.phase == .idle else {
            teardown()
            throw XCTSkip("mpv init 未成功(\(player.phase)),本条不适用")
        }
        let view = MPVLayerView(player: player)
        view.frame = container.bounds
        container.addSubview(view)
        window.orderFrontRegardless()

        let firstFrame = expectation(description: "第一帧真实视频帧")
        firstFrame.assertForOverFulfill = false
        player.attach(eventBridge: MPVEventBridge { event in
            if event == .firstVideoFrameRendered { firstFrame.fulfill() }
        })

        let deadline = Date().addingTimeInterval(2)
        while !player.statisticsSnapshot().glAttached, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(player.statisticsSnapshot().glAttached,
                      "视频层 2s 内没挂上 GL:\(player.initializationFailure ?? "-")")
        try player.load(url: url, headers: [:])
        await fulfillment(of: [firstFrame], timeout: 5)
        return (player, view, teardown)
    }

    func testPausedLayerStopsDrawingButRedrawsOnResize() async throws {
        let (player, view, teardown) = try await startPlayback()
        defer { teardown() }

        // 只验监控读取(异步回复)与出帧能共存,墙钟耗时不当作顺滑 / 音画同步的证据
        let properties = try await player.stringPropertiesAsync(["video-codec", "container-fps"])
        XCTAssertNotNil(properties["video-codec"])
        XCTAssertNotNil(properties["container-fps"])

        // 24 fps 片源播 0.4 s:按片源帧率约 10 次;按屏幕刷新率(60 / 120 Hz)是 24 / 48 次
        let playingStart = player.statisticsSnapshot().drawCalls
        try await Task.sleep(for: .milliseconds(400))
        let playingDraws = player.statisticsSnapshot().drawCalls - playingStart
        XCTAssertGreaterThan(playingDraws, 0, "播放中要出帧")
        XCTAssertLessThanOrEqual(playingDraws, 18, "播放中不该按屏幕刷新率重画同一帧")

        // 暂停后 mpv 会请求一次重绘,等它画完再数
        try player.pause()
        try await Task.sleep(for: .milliseconds(300))
        let pausedDraws = player.statisticsSnapshot().drawCalls
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(player.statisticsSnapshot().drawCalls, pausedDraws, "暂停期间不该再 render")

        // 也证明窗口可见、CA 会来画:上面的 0 次不是因为窗口不可见
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(player.statisticsSnapshot().drawCalls, pausedDraws, "改尺寸后要按新尺寸重画")
    }

    /// 出帧在 render 队列上(MPV_INTEGRATION.md §2):主线程被堵住时照样画。
    func testDrawsContinueWhileMainThreadIsBlocked() async throws {
        let (player, _, teardown) = try await startPlayback()
        defer { teardown() }

        let before = player.statisticsSnapshot().drawCalls
        blockMainThread(seconds: 0.5)
        XCTAssertGreaterThan(player.statisticsSnapshot().drawCalls, before, "主线程堵住时 render 队列仍要出帧")
    }

    /// displayLink 每个 vsync 报 swap:报了一次之后 VO 每帧都等 swap,等不到 200 ms 就丢帧并计入
    /// `frame-drop-count`(vo_libmpv.c `flip_page`)。只验「报得上」,不验节奏与音画同步。
    func testSwapReportsKeepVideoOutputFromDropping() async throws {
        let (player, _, teardown) = try await startPlayback()
        defer { teardown() }

        // fixture 只有 1 s,播完属性就读不到了
        try await Task.sleep(for: .milliseconds(700))
        let drops = try await frameDropCount(player)
        XCTAssertLessThanOrEqual(drops, 1, "VO 在等 swap 超时丢帧:displayLink 没报上")
    }

    /// 暂停超过空闲时限后 displayLink 停下;恢复播放时 layer 出帧要把它叫醒,否则 VO 每帧等满 200 ms 丢帧。
    func testDisplayLinkWakesAfterIdlePause() async throws {
        let (player, _, teardown) = try await startPlayback()
        defer { teardown() }

        // 先播一段再停:第一帧刚出就暂停、恢复时,VO 追音频会另外丢 2–3 帧,与 displayLink 无关(Q49)
        try await Task.sleep(for: .milliseconds(300))
        try player.pause()
        try await Task.sleep(for: .milliseconds(1500))
        let before = try await frameDropCount(player)
        try player.resume()
        // fixture 只有 1 s,恢复后再播 0.35 s 还没到结尾
        try await Task.sleep(for: .milliseconds(350))
        let after = try await frameDropCount(player)
        XCTAssertLessThanOrEqual(after - before, 1, "恢复后 VO 在等 swap 超时丢帧:displayLink 没被叫醒")
    }

    private func frameDropCount(_ player: MPVPlayer) async throws -> Int {
        let properties = try await player.stringPropertiesAsync(["frame-drop-count"])
        return try XCTUnwrap(properties["frame-drop-count"].flatMap(Int.init))
    }

    /// 同步地堵住主线程(测试类是 @MainActor);`Thread.sleep` 不能直接在 async 函数里调
    private func blockMainThread(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// 测试 bundle 里资源可能被展平,也可能保留子目录:先按名字找,再递归搜
    private func fixtureURL(_ name: String) -> URL? {
        let bundle = Bundle(for: Self.self)
        if let url = bundle.url(forResource: name, withExtension: nil) { return url }
        let root = URL(fileURLWithPath: bundle.resourcePath ?? bundle.bundlePath)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        return nil
    }
}
