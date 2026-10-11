import AppKit
import XCTest
@testable import LumaPlayer

/// 播放窗口的窗口行为(PlayerCommands.swift 的快捷键表)。
@MainActor
final class PlayerWindowTests: XCTestCase {

    /// SwiftUI 次级 Window 场景的实测默认值:Auxiliary,不能自己全屏。
    /// `WindowBox` 要在拿到窗口时把它提升为 Primary。
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
