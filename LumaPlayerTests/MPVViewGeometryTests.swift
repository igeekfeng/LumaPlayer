import AppKit
import XCTest
@testable import LumaPlayer

/// 视频承载视图的几何契约:layer 必须和视图本身严丝合缝,
/// 否则 mpv 画出来的画面会偏移 / 缩放错位。
@MainActor
final class MPVViewGeometryTests: XCTestCase {

    private func makeHostedView(origin: CGPoint) -> (NSWindow, MPVLayerView, MPVPlayer) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.wantsLayer = true
        window.contentView = container
        let player = MPVPlayer()
        let view = MPVLayerView(player: player)
        view.frame = NSRect(origin: origin, size: CGSize(width: 400, height: 300))
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        return (window, view, player)
    }

    /// 视图不在父视图原点时,layer 的 frame(父 layer 坐标系)必须跟着视图走
    func testLayerFollowsViewFrameAtNonZeroOrigin() throws {
        let (window, view, player) = makeHostedView(origin: CGPoint(x: 120, y: 80))
        defer { window.contentView = nil; player.shutdown() }
        let layer = try XCTUnwrap(view.layer)
        XCTAssertTrue(layer is MPVGLLayer)
        XCTAssertEqual(layer.frame, view.frame)
        XCTAssertEqual(layer.bounds.size, view.bounds.size)
    }

    /// 视图尺寸变化(窗口缩放 / 全屏)后 layer 同步变化
    func testLayerTracksResize() throws {
        let (window, view, player) = makeHostedView(origin: CGPoint(x: 10, y: 20))
        defer { window.contentView = nil; player.shutdown() }
        view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        view.superview?.layoutSubtreeIfNeeded()
        let layer = try XCTUnwrap(view.layer)
        XCTAssertEqual(layer.frame, view.frame)
    }

    /// Retina:layer 的像素密度与窗口一致(否则 FBO 尺寸与传给 mpv 的尺寸对不上)
    func testContentsScaleMatchesWindow() throws {
        let (window, view, player) = makeHostedView(origin: .zero)
        defer { window.contentView = nil; player.shutdown() }
        let layer = try XCTUnwrap(view.layer)
        XCTAssertEqual(layer.contentsScale, window.backingScaleFactor)
    }
}

/// 播放窗口必须能自己全屏(UI_DESIGN.md 5.3)
@MainActor
final class PlayerWindowFullScreenTests: XCTestCase {

    /// SwiftUI 次级 Window 场景的实测默认值:Auxiliary,不能自己全屏
    func testWindowBoxPromotesAuxiliaryWindowToPrimary() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        let box = WindowBox()
        box.window = window
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }
}
