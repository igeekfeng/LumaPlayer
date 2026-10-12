import XCTest
@testable import LumaPlayer

/// 本地续播库(百度来源唯一的进度存储 —— 百度没有上报接口,`docs/BAIDU_PAN_API.md`)。
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

    // MARK: - 展示快照(「继续观看」区用)

    private func display(
        sourceID: UUID,
        title: String = "电影",
        cover: ImageDescriptor.Snapshot? = nil
    ) -> WatchProgressStore.Display {
        WatchProgressStore.Display(
            sourceID: sourceID,
            title: title,
            locator: "/apps/LumaPlayer/\(title).mp4",
            fileName: "\(title).mp4",
            cover: cover
        )
    }

    /// 起播时先记展示(此刻位置还是 0),上报器随后才写位置 —— 两者不能互相抹掉。
    func testRememberDisplayThenRecordKeepsBoth() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.rememberDisplay(fileID: "42", display: display(sourceID: sourceID))
        try await store.record(fileID: "42", positionSeconds: 300, durationSeconds: 600)

        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.positionSeconds, 300)
        XCTAssertEqual(entries.first?.display.title, "电影")
    }

    /// 反过来:先有进度、再补展示,位置不能被抹掉。
    func testRecordThenRememberDisplayKeepsPosition() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.record(fileID: "42", positionSeconds: 300, durationSeconds: 600)
        try await store.rememberDisplay(fileID: "42", display: display(sourceID: sourceID))

        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertEqual(position, 300)
    }

    /// 只有位置(老记录 / 别的来源)或只有展示(还没看)的条目都不进「继续观看」。
    func testResumeEntriesSkipsEntriesWithoutDisplayOrProgress() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.record(fileID: "1", positionSeconds: 100, durationSeconds: nil)
        try await store.rememberDisplay(fileID: "2", display: display(sourceID: sourceID))
        try await store.rememberDisplay(fileID: "3", display: display(sourceID: sourceID))
        try await store.record(fileID: "3", positionSeconds: 50, durationSeconds: nil)

        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.map(\.fileID), ["3"])
    }

    /// 看完(≥95%)的集不该再占一张「继续观看」卡 —— 与 `resumeSeconds` 同一把尺子。
    func testResumeEntriesSkipsFinishedEntries() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.rememberDisplay(fileID: "a", display: display(sourceID: sourceID, title: "A"))
        try await store.record(fileID: "a", positionSeconds: 590, durationSeconds: 600)
        try await store.rememberDisplay(fileID: "b", display: display(sourceID: sourceID, title: "B"))
        try await store.record(fileID: "b", positionSeconds: 60, durationSeconds: 600)

        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.map(\.fileID), ["b"])
    }

    /// 时长未知时判不了「看完」,按未看完留在列表里(⛔ 不猜)。
    func testResumeEntriesKeepsUnfinishedWhenDurationUnknown() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.rememberDisplay(fileID: "a", display: display(sourceID: sourceID))
        try await store.record(fileID: "a", positionSeconds: 590, durationSeconds: nil)

        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.map(\.fileID), ["a"])
    }

    func testResumeEntriesFiltersBySourceAndSortsByRecency() async throws {
        let store = makeStore()
        let mine = UUID()
        let other = UUID()
        try await store.rememberDisplay(fileID: "a", display: display(sourceID: mine, title: "A"))
        try await store.record(fileID: "a", positionSeconds: 10, durationSeconds: nil)
        try await Task.sleep(for: .milliseconds(5))
        try await store.rememberDisplay(fileID: "b", display: display(sourceID: mine, title: "B"))
        try await store.record(fileID: "b", positionSeconds: 20, durationSeconds: nil)
        try await store.rememberDisplay(fileID: "c", display: display(sourceID: other, title: "C"))
        try await store.record(fileID: "c", positionSeconds: 30, durationSeconds: nil)

        let entries = await store.resumeEntries(sourceID: mine)
        XCTAssertEqual(entries.map(\.fileID), ["b", "a"], "只出本来源,且最近看的在前")
    }

    /// 封面快照随进度一起持久化,重启后「继续观看」还端得出封面。
    func testCoverSnapshotSurvivesRestart() async throws {
        let sourceID = UUID()
        let cover = ImageDescriptor.Snapshot(
            ownerID: sourceID,
            url: URL(string: "https://d.pcs.baidu.com/file/abc?access_token=T")!,
            headers: ["User-Agent": "netdisk"],
            cacheKey: "baidu|\(sourceID.uuidString)|7|1700000000|cover|400"
        )
        let store = makeStore()
        try await store.rememberDisplay(fileID: "7", display: display(sourceID: sourceID, cover: cover))
        try await store.record(fileID: "7", positionSeconds: 42, durationSeconds: 100)

        let reopened = makeStore()
        let entries = await reopened.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.first?.display.cover, cover)
    }

    /// 旧文件(没有 `display` 字段)必须照常解码 —— 升级不该把已有进度判成损坏。
    func testLegacyFileWithoutDisplayDecodes() async throws {
        let legacy = #"{"42":{"positionSeconds":123,"durationSeconds":600,"updatedAt":"2026-01-01T00:00:00Z"}}"#
        try Data(legacy.utf8).write(to: fileURL)

        let store = makeStore()
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertEqual(position, 123)
        let failure = await store.lastLoadFailureDescription
        XCTAssertNil(failure, "旧文件不是损坏文件")
    }
}
