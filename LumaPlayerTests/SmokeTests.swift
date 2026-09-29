import XCTest
@testable import LumaPlayer

/// 冒烟测试：确认 test target 可构建、可运行、能链接主 App 模块。
/// 真正的业务测试在其他文件里。
final class SmokeTests: XCTestCase {
    func testTestTargetRuns() {
        XCTAssertTrue(true)
    }
}
