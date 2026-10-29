import XCTest
@testable import LumaPlayer

/// 挂事件桥之前设的起播值(倍速 / 音量)的变化事件要在挂桥时补发,否则读回值停在默认值(PITFALLS.md 第 2 节)。
/// 真实 libmpv,不需要 GPU。
@MainActor
final class MPVEventBridgeAttachTests: XCTestCase {

    func testValuesSetBeforeAttachAreDeliveredAfterAttach() async throws {
        let player = MPVPlayer()
        defer { player.shutdown() }
        try XCTSkipIf(player.initializationFailure != nil, "libmpv 初始化失败:\(player.initializationFailure ?? "")")

        try player.setSpeed(1.5)
        try player.setVolume(40)
        // 让事件线程先把这两次变化取走(复现「事件先于桥到达」)
        try await Task.sleep(for: .milliseconds(300))

        var speeds: [Double] = []
        var volumes: [Double] = []
        let speedArrived = expectation(description: "speed 1.5")
        let volumeArrived = expectation(description: "volume 40")
        player.attach(eventBridge: MPVEventBridge { event in
            switch event {
            case .speed(let value):
                speeds.append(value)
                if value == 1.5 { speedArrived.fulfill() }
            case .volume(let value):
                volumes.append(value)
                if value == 40 { volumeArrived.fulfill() }
            default:
                break
            }
        })
        await fulfillment(of: [speedArrived, volumeArrived], timeout: 2)
        XCTAssertEqual(speeds.last, 1.5, "补发按序,最后一个是设上的值")
        XCTAssertEqual(volumes.last, 40)
    }
}
