import XCTest
@testable import LumaPlayer

/// `EofDetector` 的判定契约(当前内核没有独立 EOF 事件,靠推断)。
@MainActor
final class EofDetectorTests: XCTestCase {

    func testPositionReachingEndThenStoppedIsEof() {
        var detector = EofDetector()
        XCTAssertNil(detector.observe(.duration(100)))
        XCTAssertNil(detector.observe(.position(99.8)))
        XCTAssertEqual(detector.observe(.phaseChanged(.stopped)), .eof)
    }

    /// 没到末尾就停(且不是我们主动停的)= 外部停止,不报自然播完
    func testStoppedWithoutReachingEndIsStopped() {
        var detector = EofDetector()
        XCTAssertNil(detector.observe(.duration(100)))
        XCTAssertNil(detector.observe(.position(10)))
        XCTAssertEqual(detector.observe(.phaseChanged(.stopped)), .stopped)
    }

    /// 我们主动 stop() 时,即便位置刚好在末尾也不算自然播完
    func testLocalStopIsReportedAsStopped() {
        var detector = EofDetector()
        XCTAssertNil(detector.observe(.duration(100)))
        XCTAssertNil(detector.observe(.position(100)))
        detector.markLocalStop()
        XCTAssertEqual(detector.observe(.phaseChanged(.stopped)), .stopped)
    }

    /// closed 态同样算结束
    func testClosedIsTerminal() {
        var detector = EofDetector()
        XCTAssertNil(detector.observe(.duration(50)))
        XCTAssertNil(detector.observe(.position(50)))
        XCTAssertEqual(detector.observe(.phaseChanged(.closed)), .eof)
    }

    /// 只报一次:后续的停止 / 位置事件不再产生结束
    func testReportsOnlyOnce() {
        var detector = EofDetector()
        XCTAssertNil(detector.observe(.duration(100)))
        XCTAssertNil(detector.observe(.position(100)))
        XCTAssertEqual(detector.observe(.phaseChanged(.stopped)), .eof)
        XCTAssertNil(detector.observe(.phaseChanged(.closed)))
        XCTAssertNil(detector.observe(.phaseChanged(.stopped)))
    }

    /// 显式的 ended(error) 原样透传
    func testExplicitEndedErrorPassesThrough() {
        var detector = EofDetector()
        XCTAssertEqual(detector.observe(.ended(.error("解码失败"))), .error("解码失败"))
        XCTAssertNil(detector.observe(.phaseChanged(.stopped)))
    }

    /// 没有 duration 时位置不参与判定(避免 0 时长把任意位置当末尾)
    func testPositionWithoutDurationDoesNotMarkEnd() {
        var detector = EofDetector()
        XCTAssertNil(detector.observe(.position(5)))
        XCTAssertEqual(detector.observe(.phaseChanged(.stopped)), .stopped)
    }
}
