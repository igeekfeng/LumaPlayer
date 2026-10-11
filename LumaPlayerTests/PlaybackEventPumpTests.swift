import XCTest
@testable import LumaPlayer

/// `PlaybackEventPump` 的行为契约:排空队列、位置事件节流、停止即退出。
@MainActor
final class PlaybackEventPumpTests: XCTestCase {

    private final class Recorder {
        var events: [PlayerEvent] = []
        var failures: [PlayerError] = []
        var positions: [Double] = []
        var sawDuration = false
    }

    /// 一个 tick 内排空队列里的全部事件(非位置事件不丢)
    func testPumpDrainsAllQueuedEvents() async throws {
        let engine = FakePlaybackEngine()
        let pump = PlaybackEventPump()
        let recorder = Recorder()
        let done = expectation(description: "duration 到达")

        pump.start(engine: engine, interval: .milliseconds(5)) { event in
            recorder.events.append(event)
            if case .duration = event { done.fulfill() }
        } onFailure: { recorder.failures.append($0) }

        engine.enqueue(.phaseChanged(.playing))
        engine.enqueue(.tracksChanged([]))
        engine.enqueue(.duration(30))

        await fulfillment(of: [done], timeout: 2)
        pump.stop()

        XCTAssertTrue(recorder.events.contains(.phaseChanged(.playing)))
        XCTAssertTrue(recorder.events.contains(.tracksChanged([])))
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    /// 位置事件在进入上层之前被合并:毫秒级连发 20 个,只应到 1 个
    func testPositionEventsAreThrottledBeforeDelivery() async throws {
        let engine = FakePlaybackEngine()
        let pump = PlaybackEventPump()
        let recorder = Recorder()
        let done = expectation(description: "哨兵 duration 到达")

        pump.start(engine: engine, interval: .milliseconds(5)) { event in
            if case .position(let value) = event { recorder.positions.append(value) }
            if case .duration = event { done.fulfill() }
        } onFailure: { _ in }

        // 远小于 0.2s 节流窗口的连发
        for i in 1...20 { engine.enqueue(.position(Double(i))) }
        engine.enqueue(.duration(30))

        await fulfillment(of: [done], timeout: 2)
        pump.stop()

        XCTAssertEqual(recorder.positions, [1], "20 连发应只有首个位置进入上层")
    }

    /// 停止后不再投递事件
    func testStopHaltsDelivery() async throws {
        let engine = FakePlaybackEngine()
        let pump = PlaybackEventPump()
        let recorder = Recorder()
        let done = expectation(description: "首个 duration 到达")

        pump.start(engine: engine, interval: .milliseconds(5)) { event in
            if case .duration = event {
                recorder.events.append(event)
                done.fulfill()
            }
        } onFailure: { _ in }

        engine.enqueue(.duration(1))
        await fulfillment(of: [done], timeout: 2)
        pump.stop()

        engine.enqueue(.duration(2))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(recorder.events.count, 1, "stop() 之后不得再投递")
    }

    /// 引擎轮询抛错时走 onFailure,不崩
    func testPollErrorIsReportedThroughFailureHandler() async throws {
        let engine = FakePlaybackEngine()
        engine.pollError = PlayerError("轮询失败")
        let pump = PlaybackEventPump()
        let recorder = Recorder()
        let done = expectation(description: "失败到达")

        pump.start(engine: engine, interval: .milliseconds(5)) { _ in
        } onFailure: { error in
            recorder.failures.append(error)
            done.fulfill()
        }

        await fulfillment(of: [done], timeout: 2)
        pump.stop()

        XCTAssertEqual(recorder.failures.first?.message, "轮询失败")
    }
}
