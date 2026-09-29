import XCTest
@testable import LumaPlayer

/// `MPVPlayer` 生命周期契约(`MPV_INTEGRATION.md` §8)。
///
/// ⚠️ 测试环境说明:case 在 LumaPlayer.app(沙盒)host 里跑,mpv 会真实
/// 创建/销毁——这正好复用 S1-S3 已验证过的全链路(加载、渲染、销毁),
/// 测试本身不播放媒体,只走 idle → shutdown 的空生命周期。
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

    /// init 兜底契约:本机 Homebrew libmpv 存在,空闲实例应为 idle
    /// (若 init 失败,initializationFailure 必须有值——不得静默)
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

    /// 事件线程不得强持有 self:否则「调用方丢弃实例但没调 shutdown」时
    /// 引用计数永不归零,deinit 的兜底 shutdown 形同虚设,句柄与线程永久泄漏。
    /// 这条用来钉死回归——写成 `self?.eventLoop(...)` 就会挂。
    func testPlayerDeallocatesWhenDroppedWithoutShutdown() {
        weak var weakPlayer: MPVPlayer?
        autoreleasepool {
            let player = MPVPlayer()
            weakPlayer = player
            // 必须等事件线程真正进入循环再丢弃。旧实现是在线程体执行
            // `self?.eventLoop(...)` 的那一刻才抓到强引用的:如果在那之前
            // 就释放,weak 已经是 nil、线程直接退出,反而碰不到 bug
            // ——实测没有这行时,旧实现也能通过(只是慢 5s,shutdown 等信号量超时)。
            Thread.sleep(forTimeInterval: 0.2)
            // 刻意不调 shutdown():模拟调用方直接丢弃
        }
        XCTAssertNil(weakPlayer,
                     "丢弃实例后必须能析构;非 nil = 事件线程仍强持有 self")
    }

    /// shutdown 必须靠一次性的停机信号退出事件循环,而不是靠 `phase`。
    /// phase 会被事件线程自己改写(START_FILE / END_FILE / SHUTDOWN 都会写),
    /// 一旦退出条件被抹掉,shutdown 就会在**主线程**上空等满 5s 超时。
    /// 这里用耗时兜底:正常退出是毫秒级,退化成超时会让这条直接失败。
    func testShutdownReturnsPromptlyInsteadOfWaitingOutTheTimeout() {
        let player = MPVPlayer()
        let start = Date()
        player.shutdown()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0,
                          "shutdown 应由停机信号即时退出;耗时 \(elapsed)s 说明它等满了 5s 超时")
    }

    /// §8:destroyed 是终态。layer 在销毁之后仍可能异步回调 attachGLContext,
    /// 该回调不得把终态改写成 failed。
    func testAttachGLContextAfterShutdownKeepsDestroyedPhase() {
        let player = MPVPlayer()
        player.shutdown()
        XCTAssertEqual(player.phase, .destroyed)
        // CAOpenGLLayer 的 copyCGLContext 在拆卸期异步到达
        player.attachGLContext(nil)
        XCTAssertEqual(player.phase, .destroyed,
                       "destroyed 是终态,attachGLContext 失败不得把它改写成 failed")
    }

    /// §8:一个实例只播一个 URL,换台 = 销毁重建。第二次 load 必须被拒。
    ///
    /// 注:这里不断言具体错误消息——第二次 load 既可能被 hasLoaded 一次性
    /// 门挡下,也可能因为 mpv 已经对 /dev/null 报错、phase 落到 failed 而被
    /// withLiveHandle 挡下,两条都是「被拒」。契约是「必须抛」,不是「抛哪条」。
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
        // 哨兵:非 time-pos 事件不节流、直通,且排在全部 timePos Task 之后
        // 进入 MainActor 队列——哨兵到达时前一批必然处理完
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

        // 非 time-pos 事件不节流:20 个全部到达
        for _ in 1...20 {
            bridge.submit(.duration(30))
        }
        await fulfillment(of: [sentinel], timeout: 2.0)
        XCTAssertEqual(counter.others, 20)
    }
}
