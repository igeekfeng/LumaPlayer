import XCTest
@testable import LumaPlayer

/// ticks ↔ 秒 的换算(API_CONTRACT.md 8.3;ARCHITECTURE.md 10.1)。
///
/// ⛔ 业务代码里出现 `10_000_000` 字面量是违规的(CLAUDE.md 提交前自检第 4 条),
/// 换算只有这一个出处。
final class TickConverterTests: XCTestCase {

    func testOneSecondIsTenMillionTicks() {
        XCTAssertEqual(TickConverter.ticksPerSecond, 10_000_000)
        XCTAssertEqual(TickConverter.ticks(fromSeconds: 1), TickConverter.ticksPerSecond)
    }

    func testSecondsToTicks() {
        XCTAssertEqual(TickConverter.ticks(fromSeconds: 0), 0)
        XCTAssertEqual(TickConverter.ticks(fromSeconds: 60), 600_000_000)
        // 小数秒向零取整:Emby 的位置是整数 ticks
        XCTAssertEqual(TickConverter.ticks(fromSeconds: 1.5), 15_000_000)
        XCTAssertEqual(TickConverter.ticks(fromSeconds: 0.0000001), 1)
    }

    func testTicksToSeconds() {
        XCTAssertEqual(TickConverter.seconds(fromTicks: 0), 0)
        XCTAssertEqual(TickConverter.seconds(fromTicks: TickConverter.ticksPerSecond), 1)
        XCTAssertEqual(TickConverter.seconds(fromTicks: 600_000_000), 60)
    }

    /// 上报位置经 ticks 往返后不应漂移(5.1 的 PositionTicks 由秒换算而来)。
    func testRoundTripPreservesWholeSeconds() {
        for seconds in [0.0, 1.0, 42.0, 3600.0, 7325.0] {
            XCTAssertEqual(
                TickConverter.seconds(fromTicks: TickConverter.ticks(fromSeconds: seconds)),
                seconds,
                accuracy: 1e-9
            )
        }
    }

    /// 负数原样换算:语义由调用方判断,这里不静默取绝对值。
    func testNegativeValuesArePreserved() {
        XCTAssertEqual(TickConverter.ticks(fromSeconds: -1), -TickConverter.ticksPerSecond)
        XCTAssertEqual(TickConverter.seconds(fromTicks: -10_000_000), -1)
    }
}
