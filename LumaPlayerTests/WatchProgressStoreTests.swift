import XCTest
@testable import LumaPlayer

/// 本地续播库(百度源唯一的进度存储 —— 百度没有上报接口,文档 §5.2)。
final class WatchProgressStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "watch-progress-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func makeStore() -> WatchProgressStore {
        WatchProgressStore(fileURL: fileURL)
    }

    // MARK: - 续播

    func testNoRecordMeansNoResumePosition() async throws {
        let store = makeStore()
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertNil(position, "没有记录就是 nil,⛔ 不是 0")
    }

    func testRecordsAndReadsBackPosition() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 123.5, durationSeconds: 600)
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertEqual(position, 123.5)
    }

    /// 看完(≥95%)就不再续播,从头开始。
    func testFinishedPlaybackResetsToBeginning() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 590, durationSeconds: 600)
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertNil(position, "已看完的不该再提示续播")
    }

    func testBelowThresholdStillResumes() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 540, durationSeconds: 600)
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertEqual(position, 540)
    }

    /// 时长未知时照样续播(只是判不了「已看完」)。
    func testResumeWorksWithoutDuration() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 88, durationSeconds: nil)
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertEqual(position, 88)
    }

    /// 位置回到 0 时**删掉**这条记录:「从 0 开始看」不是一条进度。
    func testPositionZeroRemovesRecord() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 123, durationSeconds: 600)
        try await store.record(fileID: "42", positionSeconds: 0, durationSeconds: 600)
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertNil(position)
    }

    func testRemoveDeletesOnlyThatEntry() async throws {
        let store = makeStore()
        try await store.record(fileID: "a", positionSeconds: 10, durationSeconds: nil)
        try await store.record(fileID: "b", positionSeconds: 20, durationSeconds: nil)
        try await store.remove(fileID: "a")
        let removed = await store.resumeSeconds(forFileID: "a")
        let kept = await store.resumeSeconds(forFileID: "b")
        XCTAssertNil(removed)
        XCTAssertEqual(kept, 20)
    }

    // MARK: - 落盘

    func testSnapshotSurvivesANewStoreInstance() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 321, durationSeconds: 900)
        // 换一个实例(= 模拟 App 重启):进度必须在盘上
        let reopened = makeStore()
        let position = await reopened.resumeSeconds(forFileID: "42")
        XCTAssertEqual(position, 321)
    }

    /// 文件坏了不能静默「当作没有记录」:原因要留下来。
    func testCorruptedFileIsReportedNotSwallowed() async throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore()
        _ = await store.resumeSeconds(forFileID: "42")
        let failure = await store.lastLoadFailureDescription
        XCTAssertNotNil(failure, "读盘失败必须留下原因,⛔ 不能假装没记录")
    }

    func testWritesWithRestrictivePermissions() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 1, durationSeconds: nil)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)
        // 0o600:「谁看了什么」属于隐私,不该对同机其他用户可读
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }
}
