import IOKit
import IOKit.pwr_mgt
import XCTest
@testable import LumaPlayer

/// `DisplaySleepInhibiting` 的替身:记录调用,不真的占住显示器。
///
/// `PlayerViewModelTests` 用它验「播放状态 → 断言」的接线,真实 IOKit 断言的行为
/// 由下面 `DisplaySleepAssertionTests` 单独验。
@MainActor
final class RecordingDisplaySleepInhibitor: DisplaySleepInhibiting {
    private(set) var isHeld = false

    func setActive(_ active: Bool) {
        isHeld = active
    }
}

/// 显示器休眠断言(GitHub issue #1)。
///
/// 这里跑的是**真的** `IOPMAssertionCreateWithName`:系统拒发断言时 `isHeld` 会是
/// false,用例就会红 —— 所以本文件同时说明「这台机器允许 App 申请显示器休眠断言」。
///
/// ⛔ 但「能不能真的挡住息屏」单测证明不了:那要在运行中的 App 上看
/// `pmset -g assertions`(issue #1 的验收标准,未在单测 / CI 里覆盖)。
@MainActor
final class DisplaySleepAssertionTests: XCTestCase {

    /// 持有 → 释放;`isHeld` 如实反映系统有没有真的把断言发下来。
    func testAcquireAndRelease() {
        let assertion = DisplaySleepAssertion()
        XCTAssertFalse(assertion.isHeld, "刚创建就不该持有")

        assertion.setActive(true)
        XCTAssertTrue(assertion.isHeld, "IOPMAssertionCreateWithName 被拒(或实现没记下 id)")

        assertion.setActive(false)
        XCTAssertFalse(assertion.isHeld)
    }

    /// 重复设同一个值不能改变状态、也不能出错。
    ///
    /// 幂等挡在实现里是必须的:重复 acquire 会再拿一个 id 覆盖旧的,旧 id 再也
    /// 释放不掉,断言一直挂到进程退出(单测观测不到那条泄漏,`pmset -g assertions`
    /// 才能,所以这里只验状态与「不炸」)。
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

    /// 兜底:持有者被丢掉却没调 `setActive(false)` 时,deinit 必须把断言还给系统。
    ///
    /// 主要出口是 `PlayerViewModel.stop()`;这条保险针对的是「以后有人加了不经过 stop()
    /// 的销毁路径」——断言是进程级资源,漏了就是用户的 Mac 一直不睡,功能测试看不出来。
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

    /// 数本进程里名字为 `DisplaySleepAssertion.assertionName` 的系统断言
    /// (`pmset -g assertions` 的程序化版本)。
    /// 返回 nil 表示这个查询在本宿主不可用 —— 调用方据此 skip,而不是误判成 0 条。
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

    /// 判据本身是纯函数,这里把所有分支钉住。
    func testShouldPreventDisplaySleepOnlyWhilePlaying() {
        // 正在播放(含 mpv 报 paused-for-cache 的缓冲期:那时 isPaused 仍是 false,
        // 画面等着网络回来,屏不能睡)
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
