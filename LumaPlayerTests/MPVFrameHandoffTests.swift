import AppKit
import XCTest
@testable import LumaPlayer

/// 换集不黑屏的两条前提(`PlayerWindowView.lingeringPlayer`):
/// - 已拆卸的播放器不再让 layer 画(`canRender` 为假 → 画面定格在最后一帧);
/// - 新一集的视频层**被上一集的定格层整个盖住**时,照样能挂上 GL、画出第一帧真实视频帧
///   并发出 `firstVideoFrameRendered`(播放页靠它撤掉定格层)。
///
/// ⚠️ 覆盖边界(照实说):要真窗口 + GPU(本机有;无 GPU 的环境会失败而不是 skip)。
/// 「定格的那一帧肉眼看是不是上一集的最后一帧」验不了 —— CAOpenGLLayer 在 canDraw 为假时保留内容是用独立探针截图
/// 实测的(见 `MPVPlayer.canRender`),不是这个测试。
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
