import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// `PlayerViewModel` 依赖的电源断言注入点。
///
/// 与 `PlaybackProgressReporter` 的注入同源:ViewModel 只认这个协议,
/// 单测用替身验「什么时候持有、什么时候释放」,不必真的占住显示器。
@MainActor
protocol DisplaySleepInhibiting: AnyObject {
    /// 是否正持有断言(未持有时为 false —— 创建失败也算未持有)
    var isHeld: Bool { get }
    /// 幂等开关:`true` 持有、`false` 释放;重复设同一个值不做任何事。
    func setActive(_ active: Bool)
}

/// 播放期间阻止**显示器**休眠(息屏)。
///
/// ## 为什么必须由宿主自己做
///
/// mpv 自带 `--stop-screensaver`(默认 `yes`),但它是**经 video output** 实现的:
/// `player/playloop.c` 的 `update_screensaver_state()` 只把状态算成
/// `VOCTRL_KILL_SCREENSAVER` / `VOCTRL_RESTORE_SCREENSAVER` 发给 VO,真正调
/// `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep)`
/// 的是 macOS 的 VO 层(`video/out/mac/common.swift`)。
///
/// 本项目走 render API 并显式设了 `vo=libmpv`(`MPVPlayer.startupOptions`),
/// 而 `video/out/vo_libmpv.c` 的 `control()` 里**没有**这两个 VOCTRL ——
/// 没有 mac VO,就没有人持断言。所以这条只能由 App 自己补
/// (GitHub issue #1;`docs/PITFALLS.md` Q34、`docs/MPV_INTEGRATION.md` 3.2)。
///
/// ## 语义(对齐 mpv 的 `stop-screensaver=yes`,⛔ 不是 `=2` 的「始终抑制」)
///
/// 只在**正在播放**时持有;暂停 / 播完 / 失败 / 拆播放器立即释放,把休眠策略还给系统。
/// 判据本身在 `PlayerViewModel.shouldPreventDisplaySleep`(纯函数,可单测)。
///
/// 只阻止**显示器**休眠,不碰整机 idle sleep:后者会把音频一起掐掉,
/// 不是播放器该替用户做的决定。
@MainActor
final class DisplaySleepAssertion: DisplaySleepInhibiting {
    /// `IOPMAssertionID` 的 0 是无效 id(系统不会分配 0),因此 0 就表示未持有。
    private var assertionID: IOPMAssertionID = 0

    var isHeld: Bool { assertionID != 0 }

    func setActive(_ active: Bool) {
        active ? acquire() : release()
    }

    /// 幂等不是洁癖:重复 acquire 会再拿一个 id 并覆盖旧的,旧的那个再也释放不掉
    /// (断言一直挂在进程上,只能等进程退出)。
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
            // 拿不到断言不打断播放:画面照播,只是系统可能按原计划息屏。
            // 但⛔不能假装持有(CLAUDE.md 硬规则 4)—— 记一条日志,状态保持未持有,
            // 调用方从 `isHeld` 能看出没占上。
            Self.logger.error("显示器休眠断言创建失败, IOReturn=\(result, privacy: .public)")
            return
        }
        assertionID = id
    }

    private func release() {
        guard assertionID != 0 else { return }
        let id = assertionID
        // 先置 0:即便下面的 release 失败,本类也不会再拿这个 id 去重复释放
        assertionID = 0
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess {
            // 释放失败意味着断言可能还挂在系统上,已无法补救,只能靠进程退出兜底 ——
            // 记下来,免得下次排障时以为「已经释放干净了」。
            Self.logger.error("显示器休眠断言释放失败, IOReturn=\(result, privacy: .public)")
        }
    }

    /// `pmset -g assertions` 里显示的名字(排障时一眼看出是谁占的;单测也拿它去系统里数)
    static let assertionName = "LumaPlayer: playing"
    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "power")

    /// deinit 兜底:走到这里说明持有者被丢掉了却没调 `setActive(false)`。
    ///
    /// 主要出口仍是 `PlayerViewModel.stop()`(关窗、切媒体、转码重新起流都走它),
    /// 但断言是**进程级**资源:漏一个的表现是「用户的 Mac 再也不息屏」,直到 App 退出,
    /// 而且这种泄漏在功能测试里基本看不出来 —— 值得多一道保险。
    ///
    /// 用 `isolated deinit` 才能调隔离方法 `release()`(普通 deinit 是非隔离的)。
    /// ⛔ 别把这条当免死金牌:持有者若有引用环(比如某个 Task 忘了 `[weak self]`),
    /// deinit 根本不会跑,所以「别绕开 `stop()`」这条约束不变。
    isolated deinit {
        release()
    }
}
