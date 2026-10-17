import AppKit
import XCTest
@testable import LumaPlayer

/// 视频层只在需要时 render(`MPVPlayer.needsRender`,Q49):
/// - 暂停后 mpv 不再送帧,layer 一次都不画(之前按屏幕刷新率每次都 render);
/// - layer 尺寸变了照样重画一次(mpv 不知道尺寸变化,靠 `requestRender()`)。
///
/// ⚠️ 覆盖边界(照实说):要真窗口 + GPU(无 GPU 的环境会失败而不是 skip)。
/// 只数 draw 次数,不看画面;播放中是否按片源帧率出帧、音画同步、能耗都不在这里验。
@MainActor
final class MPVRenderGateTests: XCTestCase {

    func testPausedLayerStopsDrawingButRedrawsOnResize() async throws {
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
        defer {
            window.orderOut(nil)
            window.contentView = nil
            player.shutdown()
        }
        try XCTSkipUnless(player.phase == .idle, "mpv init 未成功(\(player.phase)),本条不适用")
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

        // 也证明 CA 的定时器在跑:上面的 0 次不是因为窗口不可见
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(player.statisticsSnapshot().drawCalls, pausedDraws, "改尺寸后要按新尺寸重画")
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
