import CoreGraphics
import SwiftUI
import XCTest
@testable import LumaPlayer

/// `BaiduPanGeometry` 的转写正确性。
///
/// 官方 SVG 只有绝对 `M/C/L/Z` 命令,几何可无损转写;这里锁两件事:两条 path 的包围盒
/// 与官方一致,以及 `fitTransform` 在等宽高比的 rect 上只做等比缩放(不拉伸、不留白)。
/// 官方路径点抄写漂移时,包围盒会先变。
final class BaiduPanLogoGeometryTests: XCTestCase {
    private let tolerance: CGFloat = 0.01

    func testCloudPathBoundsMatchOfficialSVG() {
        let bounds = BaiduPanGeometry.cloudPath().cgPath.boundingBox
        XCTAssertEqual(bounds.minX, 0, accuracy: tolerance)
        XCTAssertEqual(bounds.minY, 0, accuracy: tolerance)
        XCTAssertEqual(bounds.width, 114, accuracy: tolerance)
        XCTAssertEqual(bounds.height, 90, accuracy: tolerance)
    }

    func testWordmarkPathBoundsMatchOfficialSVG() {
        let bounds = BaiduPanGeometry.wordmarkPath().cgPath.boundingBox
        XCTAssertEqual(bounds.minX, 26.9, accuracy: tolerance)
        XCTAssertEqual(bounds.minY, 22.9, accuracy: tolerance)
        XCTAssertEqual(bounds.width, 60, accuracy: tolerance)
        XCTAssertEqual(bounds.height, 37, accuracy: tolerance)
    }

    func testFitTransformIsIdentityOnCanvasRect() {
        let canvas = CGRect(x: 0, y: 0, width: 114, height: 90)
        let transform = BaiduPanGeometry.fitTransform(for: canvas)
        XCTAssertEqual(transform.a, 1, accuracy: tolerance)
        XCTAssertEqual(transform.d, 1, accuracy: tolerance)
        XCTAssertEqual(transform.tx, 0, accuracy: tolerance)
        XCTAssertEqual(transform.ty, 0, accuracy: tolerance)
    }

    func testFitTransformScalesUniformlyAndPreservesAspect() {
        // 宽高比一致的 rect:等比放大,不产生留白。
        let rect = CGRect(x: 0, y: 0, width: 228, height: 180)
        let transform = BaiduPanGeometry.fitTransform(for: rect)
        XCTAssertEqual(transform.a, 2, accuracy: tolerance)
        XCTAssertEqual(transform.d, 2, accuracy: tolerance)
        XCTAssertEqual(transform.tx, 0, accuracy: tolerance)
        XCTAssertEqual(transform.ty, 0, accuracy: tolerance)

        XCTAssertEqual(BaiduPanGeometry.aspect, 90 / 114, accuracy: 1e-12)
    }
}
