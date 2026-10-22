import Foundation

/// ticks ↔ 秒的唯一换算处(API_CONTRACT.md 8.3)。⛔ 别处不得出现 `10_000_000` 字面量(自检 (4) 会扫)。
enum TickConverter: Sendable {
    /// 1 tick = 100 ns
    static let ticksPerSecond: Int64 = 10_000_000

    /// 负数原样换算;向零取整(Emby 位置是整数 ticks)。
    static func ticks(fromSeconds seconds: Double) -> Int64 {
        Int64(seconds * Double(ticksPerSecond))
    }

    /// 负数原样换算。
    static func seconds(fromTicks ticks: Int64) -> Double {
        Double(ticks) / Double(ticksPerSecond)
    }
}
