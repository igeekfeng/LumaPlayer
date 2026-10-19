import XCTest
@testable import LumaPlayer

/// 无媒体/网络:请求闸的取消竞态与请求簿匹配,加空闲 mpv 的真实 GET_REPLY 验证。
final class MPVAsyncPropertyTests: XCTestCase {
    func testCancellationBeforeContinuationRegistrationCompletesOnce() async {
        let request = MPVPropertyRequest(name: "volume")
        request.finish(.failure(CancellationError()))
        do {
            let _: String? = try await withCheckedThrowingContinuation { request.install($0) }
            XCTFail("注册前取消也必须交付 CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        request.finish(.success("late")) // 迟到回复不得二次 resume
    }

    func testReplyAfterRegistrationCompletesOnce() async throws {
        let request = MPVPropertyRequest(name: "volume")
        let value: String? = try await withCheckedThrowingContinuation {
            request.install($0)
            request.finish(.success("37"))
            request.finish(.failure(MPVError.instanceDestroyed))
        }
        XCTAssertEqual(value, "37")
    }

    func testRequestIDsMatchOutOfOrderRepliesAndAreNotReused() throws {
        var requests = MPVPropertyRequests()
        let first = MPVPropertyRequest(name: "volume")
        let second = MPVPropertyRequest(name: "speed")
        let firstID = try requests.insert(first)
        let secondID = try requests.insert(second)
        XCTAssertNotEqual(firstID, 0)
        XCTAssertGreaterThan(secondID, firstID)
        XCTAssertTrue(requests.take(secondID) === second)
        XCTAssertTrue(requests.take(firstID) === first)
        XCTAssertNil(requests.take(secondID), "重复或迟到回复必须被忽略")
        let thirdID = try requests.insert(MPVPropertyRequest(name: "pause"))
        XCTAssertGreaterThan(thirdID, secondID)
        XCTAssertNil(requests.take(firstID))
    }

    func testShutdownDrainCompletesAllRequestsIncludingUnregistered() async throws {
        var requests = MPVPropertyRequests()
        let first = MPVPropertyRequest(name: "volume")
        let second = MPVPropertyRequest(name: "speed")
        let firstID = try requests.insert(first)
        _ = try requests.insert(second)
        requests.takeAll().forEach { $0.finish(.failure(MPVError.instanceDestroyed)) }
        XCTAssertNil(requests.take(firstID))
        XCTAssertTrue(requests.takeAll().isEmpty)
        for request in [first, second] {
            do {
                let _: String? = try await withCheckedThrowingContinuation { request.install($0) }
                XCTFail("销毁必须完成所有等待者")
            } catch {
                XCTAssertEqual(error as? MPVError, .instanceDestroyed)
            }
        }
    }

    func testCancelledRequestIsRemovedAndLateReplyCannotMatch() throws {
        var requests = MPVPropertyRequests()
        let request = MPVPropertyRequest(name: "volume")
        let id = try requests.insert(request)
        request.finish(.failure(CancellationError()))
        requests.remove(request)
        XCTAssertNil(requests.take(id))
    }

    @MainActor
    func testAsyncPropertiesUseRealRepliesAndOmitUnavailableValues() async throws {
        let player = MPVPlayer()
        defer { player.shutdown() }
        try XCTSkipUnless(player.phase == .idle, "mpv 初始化未成功")
        try player.setVolume(37)
        try player.setSpeed(1.25)
        let values = try await player.stringPropertiesAsync(["volume", "speed", "video-params/w", "volume"])
        XCTAssertEqual(values["volume"].flatMap(Double.init), 37)
        XCTAssertEqual(values["speed"].flatMap(Double.init), 1.25)
        XCTAssertNil(values["video-params/w"], "空闲实例无视频参数,不可填占位")
    }

    @MainActor
    func testUnknownAsyncPropertyThrowsInsteadOfReturningEmptySample() async throws {
        let player = MPVPlayer()
        defer { player.shutdown() }
        try XCTSkipUnless(player.phase == .idle, "mpv 初始化未成功")
        do {
            _ = try await player.stringPropertiesAsync(["lumaplayer-property-does-not-exist"])
            XCTFail("PROPERTY_NOT_FOUND 必须明确抛错")
        } catch {
            XCTAssertNotNil(error as? MPVError)
        }
    }

    @MainActor
    func testAsyncReadAfterShutdownThrowsEvenForEmptyNames() async {
        let player = MPVPlayer()
        player.shutdown()
        for names in [["volume"], []] {
            do {
                _ = try await player.stringPropertiesAsync(names)
                XCTFail("destroyed 不得读成功")
            } catch {
                XCTAssertEqual(error as? MPVError, .instanceDestroyed)
            }
        }
    }

    @MainActor
    func testAlreadyCancelledAsyncReadThrowsCancellation() async {
        let player = MPVPlayer()
        defer { player.shutdown() }
        let task = Task { try await player.stringPropertiesAsync(["volume"]) }
        task.cancel() // 当前 MainActor 尚未挂起,task 确定还未执行
        do {
            _ = try await task.value
            XCTFail("已取消的读取不得 enqueue")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
