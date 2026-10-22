import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// `PlayerViewModel` 依赖的电源断言注入点(单测用替身)。
@MainActor
protocol DisplaySleepInhibiting: AnyObject {
    /// 创建失败也算未持有
    var isHeld: Bool { get }
    /// 幂等:`true` 持有、`false` 释放。
    func setActive(_ active: Bool)
}

/// 播放期间阻止显示器休眠。
///
/// mpv 的 `stop-screensaver` 靠 mac VO 持断言,而本项目用 `vo=libmpv`,没人持,只能 App 自己补
/// (`docs/PITFALLS.md` Q34、`docs/MPV_INTEGRATION.md` 3.2)。
///
/// 语义对齐 `stop-screensaver=yes`:只在正在播放时持有,判据见 `PlayerViewModel.shouldPreventDisplaySleep`。
/// 只阻止显示器休眠,不碰整机 idle sleep(会掐掉音频)。
@MainActor
final class DisplaySleepAssertion: DisplaySleepInhibiting {
    /// 0 是无效 id,表示未持有。
    private var assertionID: IOPMAssertionID = 0

    var isHeld: Bool { assertionID != 0 }

    func setActive(_ active: Bool) {
        active ? acquire() : release()
    }

    /// 必须幂等:重复 acquire 会覆盖旧 id,旧断言再也释放不掉。
    private func acquire() {
        guard assertionID == 0 else { return }

        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName as CFString,
            &id
        )
        guard result == kIOReturnSuccess, id != 0 else {
            // 不打断播放,但⛔ 不假装持有:记日志,保持未持有
            Self.logger.error("显示器休眠断言创建失败, IOReturn=\(result, privacy: .public)")
            return
        }
        assertionID = id
    }

    private func release() {
        guard assertionID != 0 else { return }
        let id = assertionID
        // 先置 0:释放失败也不重复释放同一个 id
        assertionID = 0
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess {
            Self.logger.error("显示器休眠断言释放失败, IOReturn=\(result, privacy: .public)")
        }
    }

    /// `pmset -g assertions` 里显示的名字(单测也拿它去系统里数)
    static let assertionName = "LumaPlayer: playing"
    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "power")

    /// 兜底:漏释放的表现是 Mac 一直不息屏。主出口仍是 `PlayerViewModel.stop()`;
    /// 有引用环时 deinit 不会跑,⛔ 不能靠它代替 `stop()`。
    isolated deinit {
        release()
    }
}
