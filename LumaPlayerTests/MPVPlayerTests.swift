import XCTest
@testable import LumaPlayer

/// `MPVPlayer` 生命周期契约(`MPV_INTEGRATION.md` §8)。
/// 在沙盒 app host 里真实创建 / 销毁 mpv,不播媒体,只走 idle → shutdown。
final class MPVPlayerLifecycleTests: XCTestCase {

    /// §8 规则 1:shutdown 可重入——重复调用不崩溃
    func testShutdownIsReentrant() {
        let player = MPVPlayer()
        player.shutdown()
        player.shutdown()
        player.shutdown()
        XCTAssertEqual(player.phase, .destroyed)
    }

    /// §8 规则 2:destroyed 之后调用不得静默——抛 instanceDestroyed
    func testLoadAfterDestroyedThrowsInstanceDestroyed() {
        let player = MPVPlayer()
        player.shutdown()
        XCTAssertThrowsError(
            try player.load(url: URL(fileURLWithPath: "/dev/null"), headers: [:])
        ) { error in
            XCTAssertEqual(error as? MPVError, .instanceDestroyed)
        }
    }

    /// §8 规则 2 的「任何方法」:播放控制类方法同样不得静默
    func testCommandsAfterDestroyedThrowInstanceDestroyed() {
        let player = MPVPlayer()
        player.shutdown()
        XCTAssertThrowsError(try player.pause()) { error in
            XCTAssertEqual(error as? MPVError, .instanceDestroyed)
        }
        XCTAssertThrowsError(try player.resume()) { error in
            XCTAssertEqual(error as? MPVError, .instanceDestroyed)
        }
        XCTAssertThrowsError(try player.seek(to: 1)) { error in
            XCTAssertEqual(error as? MPVError, .instanceDestroyed)
        }
        XCTAssertThrowsError(try player.setVolume(50)) { error in
            XCTAssertEqual(error as? MPVError, .instanceDestroyed)
        }
    }

    /// libmpv 可加载时空闲实例为 idle;init 失败则 initializationFailure 必须有值,不得静默。
    func testFreshPlayerIsIdleOrFailedWithReason() {
        let player = MPVPlayer()
        let phase = player.phase
        XCTAssertTrue(phase == .idle || phase == .failed,
                      "全新实例只应为 idle 或 failed,实际 \(phase)")
        if phase == .failed {
            XCTAssertNotNil(player.initializationFailure,
                            "phase == failed 时必须有 init 失败原因")
        }
        player.shutdown()
    }

    /// 事件线程不得强持有 self:否则调用方丢弃实例而没调 shutdown 时 deinit 不触发,句柄与线程永久泄漏。
    func testPlayerDeallocatesWhenDroppedWithoutShutdown() {
        weak var weakPlayer: MPVPlayer?
        autoreleasepool {
            let player = MPVPlayer()
            weakPlayer = player
            // 必须等事件线程真正进入循环再丢弃:提前释放时 weak 已是 nil、线程直接退出,测不到强引用
            Thread.sleep(forTimeInterval: 0.2)
            // 刻意不调 shutdown():模拟调用方直接丢弃
        }
        XCTAssertNil(weakPlayer,
                     "丢弃实例后必须能析构;非 nil = 事件线程仍强持有 self")
    }

    /// shutdown 须靠一次性停机信号退出事件循环,不能靠 `phase`(事件线程会改写它),否则主线程空等 5s 超时。
    /// 用耗时兜底:正常退出是毫秒级。
    func testShutdownReturnsPromptlyInsteadOfWaitingOutTheTimeout() {
        let player = MPVPlayer()
        let start = Date()
        player.shutdown()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0,
                          "shutdown 应由停机信号即时退出;耗时 \(elapsed)s 说明它等满了 5s 超时")
    }

    /// destroyed 是终态:销毁后 layer 仍可能异步回调 attachGLContext,不得改写成 failed(§8)。
    func testAttachGLContextAfterShutdownKeepsDestroyedPhase() {
        let player = MPVPlayer()
        player.shutdown()
        XCTAssertEqual(player.phase, .destroyed)
        // CAOpenGLLayer 的 copyCGLContext 在拆卸期异步到达
        player.attachGLContext(nil)
        XCTAssertEqual(player.phase, .destroyed,
                       "destroyed 是终态,attachGLContext 失败不得把它改写成 failed")
    }

    /// §8:一个实例只播一个 URL,第二次 load 必须抛。
    /// 不断言具体错误:`hasLoaded` 门或已落到 failed 的 phase 都可能挡下,契约只是「必须抛」。
    func testSecondLoadIsRejected() throws {
        let player = MPVPlayer()
        defer { player.shutdown() }
        try XCTSkipUnless(player.phase == .idle,
                          "init 未成功(phase=\(player.phase)),本条不适用")

        let url = URL(fileURLWithPath: "/dev/null")
        try player.load(url: url, headers: [:])
        XCTAssertThrowsError(try player.load(url: url, headers: [:])) { error in
            XCTAssertNotNil(error as? MPVError, "应抛 MPVError,实际 \(error)")
        }
    }
}

/// `MPVEventBridge` 的 time-pos 节流(`MPV_INTEGRATION.md` §6.3:
/// 节流发生在**进入 MainActor 之前**,首事件直通,0.2s 窗口内丢弃)。
final class MPVEventBridgeThrottleTests: XCTestCase {

    @MainActor
    func testTimePosBurstIsThrottledBeforeMainActor() async throws {
        final class Counter {
            var timePos = 0
        }
        let counter = Counter()
        // 哨兵:非 time-pos 事件直通,排在全部 timePos Task 之后进 MainActor,到达时前一批必然处理完
        let sentinel = expectation(description: "哨兵事件(duration)到达 MainActor")

        let bridge = MPVEventBridge { event in
            switch event {
            case .timePos:
                counter.timePos += 1
            case .duration:
                sentinel.fulfill()
            default:
                break
            }
        }

        // 毫秒级连发 20 个 timePos(远小于 0.2s 节流窗口)
        for i in 1...20 {
            bridge.submit(.timePos(Double(i)))
        }
        bridge.submit(.duration(30))

        await fulfillment(of: [sentinel], timeout: 2.0)

        // 首事件直通 + 窗口内全丢 → MainActor 恰好收到 1 次
        XCTAssertEqual(counter.timePos, 1,
                       "20 连发应只有首个 timePos 进入 MainActor")
    }

    @MainActor
    func testOtherEventsAreNotThrottled() async throws {
        final class Counter {
            var others = 0
        }
        let counter = Counter()
        let sentinel = expectation(description: "哨兵到达")

        let bridge = MPVEventBridge { event in
            switch event {
            case .duration:
                counter.others += 1
                if counter.others == 20 { sentinel.fulfill() }
            default:
                break
            }
        }

        for _ in 1...20 {
            bridge.submit(.duration(30))
        }
        await fulfillment(of: [sentinel], timeout: 2.0)
        XCTAssertEqual(counter.others, 20)
    }
}
