import Foundation

/// ticks ↔ 秒 的唯一换算处(API_CONTRACT.md 8.3)。
///
/// ⛔ 业务代码里禁止出现 `10_000_000` 字面量 —— 自检命令 4.2(4)会扫
/// 全仓库,散落的换算常量应全部指向这里。
enum TickConverter: Sendable {
    /// 一 tick 对应的秒数(10 MHz,1 tick = 100 ns)
    static let ticksPerSecond: Int64 = 10_000_000

    /// 秒 → ticks。负数原样换算(调用方自己判断语义),
    /// 浮点乘法后向零取整 —— Emby 的位置是整数 ticks。
    static func ticks(fromSeconds seconds: Double) -> Int64 {
        Int64(seconds * Double(ticksPerSecond))
    }

    /// ticks → 秒。负数原样换算。
    static func seconds(fromTicks ticks: Int64) -> Double {
        Double(ticks) / Double(ticksPerSecond)
    }
}
