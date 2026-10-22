import AppKit
import XCTest
@testable import LumaPlayer

/// layer 必须和视图严丝合缝,否则 mpv 的画面会偏移 / 缩放错位。
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

    /// layer 的 frame 在父 layer 坐标系里
    func testLayerFollowsViewFrameAtNonZeroOrigin() throws {
        let (window, view, player) = makeHostedView(origin: CGPoint(x: 120, y: 80))
        defer { window.contentView = nil; player.shutdown() }
        let layer = try XCTUnwrap(view.layer)
        XCTAssertTrue(layer is MPVGLLayer)
        XCTAssertEqual(layer.frame, view.frame)
        XCTAssertEqual(layer.bounds.size, view.bounds.size)
    }

    func testLayerTracksResize() throws {
        let (window, view, player) = makeHostedView(origin: CGPoint(x: 10, y: 20))
        defer { window.contentView = nil; player.shutdown() }
        view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        view.superview?.layoutSubtreeIfNeeded()
        let layer = try XCTUnwrap(view.layer)
        XCTAssertEqual(layer.frame, view.frame)
    }

    /// 否则 FBO 尺寸与传给 mpv 的尺寸对不上
    func testContentsScaleMatchesWindow() throws {
        let (window, view, player) = makeHostedView(origin: .zero)
        defer { window.contentView = nil; player.shutdown() }
        let layer = try XCTUnwrap(view.layer)
        XCTAssertEqual(layer.contentsScale, window.backingScaleFactor)
    }
}

/// 播放窗口必须能自己全屏(PlayerCommands.swift 的快捷键表)
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
