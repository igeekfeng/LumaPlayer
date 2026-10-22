import IOKit
import IOKit.pwr_mgt
import XCTest
@testable import LumaPlayer

/// `DisplaySleepInhibiting` 的替身:记录调用,不真的占住显示器(真实 IOKit 行为由 `DisplaySleepAssertionTests` 验)。
@MainActor
final class RecordingDisplaySleepInhibitor: DisplaySleepInhibiting {
    private(set) var isHeld = false

    func setActive(_ active: Bool) {
        isHeld = active
    }
}

/// 显示器休眠断言。跑的是真的 `IOPMAssertionCreateWithName`,系统拒发时 `isHeld` 为 false、用例会红。
/// ⛔ 能否真挡住息屏单测证明不了,要在运行中的 App 上看 `pmset -g assertions`。
@MainActor
final class DisplaySleepAssertionTests: XCTestCase {

    func testAcquireAndRelease() {
        let assertion = DisplaySleepAssertion()
        XCTAssertFalse(assertion.isHeld, "刚创建就不该持有")

        assertion.setActive(true)
        XCTAssertTrue(assertion.isHeld, "IOPMAssertionCreateWithName 被拒(或实现没记下 id)")

        assertion.setActive(false)
        XCTAssertFalse(assertion.isHeld)
    }

    /// 幂等必须在实现里挡:重复 acquire 会拿新 id 覆盖旧的,旧断言挂到进程退出。单测看不到泄漏,只验状态与不炸。
    func testSetActiveIsIdempotent() {
        let assertion = DisplaySleepAssertion()

        assertion.setActive(true)
        assertion.setActive(true)
        XCTAssertTrue(assertion.isHeld)

        assertion.setActive(false)
        XCTAssertFalse(assertion.isHeld)

        // 多释放一次也不该出问题(关窗与 stop() 都会走到释放)
        assertion.setActive(false)
        XCTAssertFalse(assertion.isHeld)
    }

    /// 兜底:持有者没调 `setActive(false)` 就被丢掉时,deinit 必须还断言(防将来出现不经过 `stop()` 的销毁路径)。
    func testDroppingWithoutReleaseStillReleasesAssertion() throws {
        guard let baseline = systemAssertionCount() else {
            throw XCTSkip("本测试宿主读不到系统断言列表(沙盒限制),deinit 兜底未在此覆盖")
        }

        var assertion: DisplaySleepAssertion? = DisplaySleepAssertion()
        assertion?.setActive(true)
        XCTAssertEqual(systemAssertionCount(), baseline + 1, "断言没进系统,后面的 deinit 也就无从验起")

        assertion = nil // 故意不调 setActive(false)

        XCTAssertEqual(systemAssertionCount(), baseline, "deinit 兜底没释放:断言还挂在进程上")
    }

    /// 数本进程里名为 `assertionName` 的系统断言(程序化的 `pmset -g assertions`)。
    /// nil = 本宿主查不了,调用方 skip,不当成 0 条。
    private func systemAssertionCount() -> Int? {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byPID = raw?.takeRetainedValue() as? [AnyHashable: Any]
        else { return nil }

        var count = 0
        for (_, value) in byPID {
            guard let assertions = value as? [[String: Any]] else { continue }
            for assertion in assertions where (assertion["AssertName"] as? String)
                == DisplaySleepAssertion.assertionName {
                count += 1
            }
        }
        return count
    }

    func testShouldPreventDisplaySleepOnlyWhilePlaying() {
        // 正在播放,含 paused-for-cache 缓冲期(isPaused 仍是 false,屏不能睡)
        XCTAssertTrue(PlayerViewModel.shouldPreventDisplaySleep(
            phase: .playing, isPaused: false, isEnded: false))

        // 暂停:mpv 把 phase 置 .paused
        XCTAssertFalse(PlayerViewModel.shouldPreventDisplaySleep(
            phase: .paused, isPaused: true, isEnded: false))
        // 起播前就按了暂停:FILE_LOADED 仍会把 phase 推到 .playing
        XCTAssertFalse(PlayerViewModel.shouldPreventDisplaySleep(
            phase: .playing, isPaused: true, isEnded: false))
        // 播完:phase 停在 .playing,只能靠 isEnded 判(docs/PITFALLS.md Q7)
        XCTAssertFalse(PlayerViewModel.shouldPreventDisplaySleep(
            phase: .playing, isPaused: false, isEnded: true))

        // 起播准备中 / 失败 / 已拆:都不该占着断言
        XCTAssertFalse(PlayerViewModel.shouldPreventDisplaySleep(
            phase: .loading, isPaused: false, isEnded: false))
        XCTAssertFalse(PlayerViewModel.shouldPreventDisplaySleep(
            phase: .failed, isPaused: false, isEnded: false))
        XCTAssertFalse(PlayerViewModel.shouldPreventDisplaySleep(
            phase: .tearingDown, isPaused: false, isEnded: false))
        XCTAssertFalse(PlayerViewModel.shouldPreventDisplaySleep(
            phase: .destroyed, isPaused: false, isEnded: false))
        XCTAssertFalse(PlayerViewModel.shouldPreventDisplaySleep(
            phase: .idle, isPaused: false, isEnded: false))
    }
}
