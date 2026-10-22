import XCTest
@testable import LumaPlayer

@MainActor
final class PlayerMonitoringTests: XCTestCase {
    /// 故意不遵从取消的替身:让停止/面板切换之后的迟到结果真实抵达写回门。
    @MainActor
    private final class ReadGate {
        var names: [[String]] = []
        var continuations: [CheckedContinuation<[String: String], any Error>] = []
        var onRead: (() -> Void)?

        func read(_ player: MPVPlayer, _ names: [String]) async throws -> [String: String] {
            self.names.append(names)
            return try await withCheckedThrowingContinuation {
                continuations.append($0)
                onRead?()
            }
        }

        func complete(_ values: [String: String]) { continuations.removeFirst().resume(returning: values) }
    }

    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() async throws {
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
    }

    func testStatisticsOpensImmediatelyAndToggleBurstCoalescesSerialReads() async throws {
        let gate = ReadGate()
        let viewModel = try makeViewModel(gate)
        let player = MPVPlayer()
        defer { viewModel.stop() }
        let first = expectation(description: "打开面板立即读取,无需等1s timer")
        gate.onRead = { first.fulfill() }
        viewModel.startMonitoring(player: player)
        viewModel.toggleStatistics()
        await fulfillment(of: [first], timeout: 0.5)
        XCTAssertTrue(gate.names[0].contains("video-codec"))

        // 第一轮故意挂起,主线程仍能执行开关;不取消/不并发创建无限轮。
        for _ in 0..<20 { viewModel.toggleStatistics() }
        XCTAssertTrue(viewModel.showsStatistics)
        XCTAssertEqual(gate.names.count, 1)
        let second = expectation(description: "突发请求只排一个紧随轮")
        gate.onRead = { second.fulfill() }
        gate.complete(["video-codec": "OLD", "demuxer-cache-time": "10"])
        await fulfillment(of: [second], timeout: 0.5)
        XCTAssertEqual(gate.names.count, 2)
        XCTAssertNil(viewModel.statistics, "旧面板epoch的统计不能写进重新打开的面板")
        gate.onRead = nil
        gate.complete(["video-codec": "NEW", "demuxer-cache-time": "20"])
        await waitUntil { viewModel.statistics != nil }
        XCTAssertEqual(viewModel.statistics?.lines.first(where: { $0.label == "视频" })?.value, "NEW")
        XCTAssertEqual(viewModel.bufferedUntilSeconds, 20)
    }

    func testBufferingOffOnDropsPreviousBufferingEpochReply() async throws {
        let gate = ReadGate()
        let viewModel = try makeViewModel(gate)
        let player = MPVPlayer()
        defer { viewModel.stop() }
        viewModel.handle(.buffering(true), generation: 0)
        let first = expectation(description: "旧缓冲轮")
        gate.onRead = { first.fulfill() }
        viewModel.startMonitoring(player: player)
        viewModel.toggleStatistics()
        await fulfillment(of: [first], timeout: 0.5)
        XCTAssertTrue(gate.names[0].contains("cache-buffering-state"))
        viewModel.handle(.buffering(false), generation: 0)
        viewModel.handle(.buffering(true), generation: 0)
        viewModel.toggleStatistics()
        viewModel.toggleStatistics()
        let second = expectation(description: "新缓冲轮")
        gate.onRead = { second.fulfill() }
        gate.complete(["cache-buffering-state": "5", "cache-speed": "100"])
        await fulfillment(of: [second], timeout: 0.5)
        XCTAssertNil(viewModel.bufferingPercent, "旧缓冲轮不能污染新缓冲阶段")
        XCTAssertNil(viewModel.cacheSpeedBytesPerSecond)
        gate.onRead = nil
        gate.complete(["cache-buffering-state": "75", "cache-speed": "200"])
        await waitUntil { viewModel.bufferingPercent == 75 }
        XCTAssertEqual(viewModel.cacheSpeedBytesPerSecond, 200)
    }

    func testStoppedPlayerLateReplyCannotWriteMonitoredValues() async throws {
        let gate = ReadGate()
        let viewModel = try makeViewModel(gate)
        let player = MPVPlayer()
        let first = expectation(description: "读取已挂起")
        gate.onRead = { first.fulfill() }
        viewModel.startMonitoring(player: player)
        viewModel.toggleStatistics()
        await fulfillment(of: [first], timeout: 0.5)
        viewModel.stop()
        gate.onRead = nil
        gate.complete(["video-codec": "OLD", "demuxer-cache-time": "99"])
        // 已取消的 worker 返回后没有第二轮;即使替身交付成功值也必须被代次 / identity 门挡住。
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(viewModel.statistics)
        XCTAssertNil(viewModel.bufferedUntilSeconds)
        XCTAssertNil(viewModel.player)
    }

    func testReadFailureKeepsPreviousSampleAndDoesNotFailPlayback() async throws {
        let gate = ReadGate()
        let viewModel = try makeViewModel(gate)
        let player = MPVPlayer()
        defer { viewModel.stop() }
        let first = expectation(description: "首轮")
        gate.onRead = { first.fulfill() }
        viewModel.startMonitoring(player: player)
        viewModel.toggleStatistics()
        await fulfillment(of: [first], timeout: 0.5)
        gate.onRead = nil
        gate.complete(["demuxer-cache-time": "42"])
        await waitUntil { viewModel.bufferedUntilSeconds == 42 }
        viewModel.toggleStatistics()
        let second = expectation(description: "错误轮")
        gate.onRead = { second.fulfill() }
        viewModel.toggleStatistics()
        await fulfillment(of: [second], timeout: 0.5)
        gate.onRead = nil
        gate.continuations.removeFirst().resume(throwing: MPVError.commandFailed(code: -11, message: "TEST"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(viewModel.bufferedUntilSeconds, 42)
        XCTAssertNil(viewModel.failure, "监控诊断失败不能遮住正常视频")
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(0.5)
        while !predicate(), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { XCTFail("等待意外取消"); return }
        }
        XCTAssertTrue(predicate(), "监控结果未及时写回")
    }

    private func makeViewModel(_ gate: ReadGate) throws -> PlayerViewModel {
        // 注册表 actor 与 MainActor 偏好各用一份 defaults,不跨隔离域共享非 Sendable 实例。
        guard let registryDefaults = UserDefaults(suiteName: "test.LumaPlayer.monitor.registry.\(UUID().uuidString)") else {
            throw MPVError.commandFailed(code: -1, message: "测试 defaults 初始化失败")
        }
        let registry = try ServerRegistry(defaults: registryDefaults, credentials: credentials)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test.LumaPlayer.monitor.prefs.\(UUID().uuidString)"))
        let profile = ServerProfile(displayName: "emby.test", baseURL: testURL("https://emby.test"), deviceID: "DEVICE-TEST")
        let item = try JSONDecoder().decode(EmbyItem.self, from: Data(#"{"Id":"ITEM-TEST","Name":"测试影片","Type":"Movie"}"#.utf8))
        return PlayerViewModel(
            container: AppContainer(registry: registry, credentials: credentials, preferences: defaults),
            request: PlaybackRequest(server: profile, item: item),
            displaySleep: RecordingDisplaySleepInhibitor(),
            readMonitoredProperties: { try await gate.read($0, $1) })
    }
}
