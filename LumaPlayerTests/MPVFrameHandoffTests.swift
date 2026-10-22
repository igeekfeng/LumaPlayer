import AppKit
import XCTest
@testable import LumaPlayer

/// 换集 / 转码 seek / 重试不黑屏的两条前提(`PlayerViewModel.lingeringPlayer`):已拆卸的播放器不再让 layer 画
/// (画面定格);新播放器的视频层被定格层整个盖住时,照样能挂上 GL、画出第一帧并发 `firstVideoFrameRendered`。
///
/// 要真窗口 + GPU(无 GPU 会失败而不是 skip)。验不了定格帧肉眼对不对(见 `MPVPlayer.canRender`)。
@MainActor
final class MPVFrameHandoffTests: XCTestCase {

    func testShutdownPlayerStopsRendering() {
        let player = MPVPlayer()
        XCTAssertFalse(player.canRender, "还没挂 GL 时不画")
        player.shutdown()
        XCTAssertFalse(player.canRender)
    }

    func testCoveredLayerStillAttachesAndReportsFirstVideoFrame() async throws {
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

        let fresh = MPVPlayer()
        let previous = MPVPlayer()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            fresh.shutdown()
            previous.shutdown()
        }
        try XCTSkipUnless(fresh.phase == .idle, "mpv init 未成功(\(fresh.phase)),本条不适用")
        // 上一集已拆卸,视图留在上层盖住新一集(与播放页的层级一致)
        previous.shutdown()
        for player in [fresh, previous] {
            let view = MPVLayerView(player: player)
            view.frame = container.bounds
            container.addSubview(view)
        }
        window.orderFrontRegardless()

        let firstFrame = expectation(description: "第一帧真实视频帧")
        firstFrame.assertForOverFulfill = false
        fresh.attach(eventBridge: MPVEventBridge { event in
            if event == .firstVideoFrameRendered { firstFrame.fulfill() }
        })

        // 与 PlayerViewModel 同一条序:先等 GL 挂上,再 load
        let deadline = Date().addingTimeInterval(2)
        while !fresh.statisticsSnapshot().glAttached, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(fresh.statisticsSnapshot().glAttached,
                      "被盖住的视频层 2s 内没挂上 GL:\(fresh.initializationFailure ?? "-")")
        XCTAssertTrue(fresh.canRender)
        XCTAssertFalse(previous.canRender, "定格层不能再画")

        try fresh.load(url: url, headers: [:])
        await fulfillment(of: [firstFrame], timeout: 5)
        XCTAssertGreaterThan(fresh.statisticsSnapshot().renderedFrames, 0)

        // 它再被拆掉(转码 seek / 重试 / 换集):仍记得出过画面 —— ViewModel 据此留它当定格层
        XCTAssertTrue(fresh.hasRenderedVideoFrame)
        fresh.shutdown()
        XCTAssertTrue(fresh.hasRenderedVideoFrame)
        XCTAssertFalse(fresh.canRender)
        XCTAssertFalse(previous.hasRenderedVideoFrame, "从没播过的实例没有可定格的画面")
    }

    /// 测试 bundle 里资源可能被展平,也可能保留子目录。
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
