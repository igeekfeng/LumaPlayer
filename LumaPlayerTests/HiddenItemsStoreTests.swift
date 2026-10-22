import XCTest
@testable import LumaPlayer

/// 每个用例一个临时 JSON 文件:测试跑在宿主 App 进程里,不能碰沙盒里真实的那份。
final class HiddenItemsStoreTests: XCTestCase {

    private var fileURL: URL!
    private let sourceID = UUID()

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "hidden-items-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func makeStore() -> HiddenItemsStore {
        HiddenItemsStore(fileURL: fileURL)
    }

    private func makeItem(itemID: String = "42", title: String = "第 3 集") -> HiddenItemsStore.Item {
        HiddenItemsStore.Item(
            ref: SourceItemRef(sourceID: sourceID, itemID: itemID),
            title: title,
            hiddenAt: Date())
    }

    // MARK: - 隐藏与恢复

    func testHiddenRefIsReportedForItsSource() async throws {
        let store = makeStore()
        try await store.hide(makeItem())

        let refs = await store.hiddenRefs(sourceID: sourceID)
        XCTAssertTrue(refs.contains(SourceItemRef(sourceID: sourceID, itemID: "42")))
        // ⛔ 不串来源
        let other = await store.hiddenRefs(sourceID: UUID())
        XCTAssertTrue(other.isEmpty)
    }

    func testRestoreBringsTheItemBack() async throws {
        let store = makeStore()
        let item = makeItem()
        try await store.hide(item)
        try await store.restore(item.ref)

        let refs = await store.hiddenRefs(sourceID: sourceID)
        XCTAssertTrue(refs.isEmpty, "恢复后就不该再被过滤掉")
        let isHidden = await store.isHidden(item.ref)
        XCTAssertFalse(isHidden)
    }

    func testAllIsSortedByMostRecentFirst() async throws {
        let store = makeStore()
        try await store.hide(HiddenItemsStore.Item(
            ref: SourceItemRef(sourceID: sourceID, itemID: "1"),
            title: "旧的", hiddenAt: Date(timeIntervalSince1970: 1_000)))
        try await store.hide(HiddenItemsStore.Item(
            ref: SourceItemRef(sourceID: sourceID, itemID: "2"),
            title: "新的", hiddenAt: Date(timeIntervalSince1970: 9_000)))

        let titles = await store.all().map(\.title)
        XCTAssertEqual(titles, ["新的", "旧的"])
    }

    // MARK: - 隐藏路径(续播卡片过滤)

    /// 目录里各集的续播卡片记的是集文件的 `fs_id`,按 `ref` 挡不住,要靠目录路径过滤。
    func testHiddenPathsReportPathAndDirectoryFlag() async throws {
        let store = makeStore()
        try await store.hide(HiddenItemsStore.Item(
            ref: SourceItemRef(sourceID: sourceID, itemID: "100"),
            title: "琅琊榜",
            hiddenAt: Date(),
            path: "/apps/LumaPlayer/琅琊榜",
            isDirectory: true))

        let paths = await store.hiddenPaths(sourceID: sourceID)

        XCTAssertEqual(paths, [HiddenItemsStore.HiddenPath(
            path: "/apps/LumaPlayer/琅琊榜", isDirectory: true)])
        // ⛔ 不串来源
        let other = await store.hiddenPaths(sourceID: UUID())
        XCTAssertTrue(other.isEmpty)
    }

    /// 没有路径就没有目录语义可判。
    func testHiddenPathsSkipItemsWithoutPath() async throws {
        let store = makeStore()
        try await store.hide(makeItem())

        let paths = await store.hiddenPaths(sourceID: sourceID)

        XCTAssertTrue(paths.isEmpty)
    }

    /// 升级不该把用户的隐藏列表判成损坏。
    func testLegacyFileWithoutPathDecodes() async throws {
        let ref = SourceItemRef(sourceID: sourceID, itemID: "42")
        let id = sourceID.uuidString
        let legacy = "{\"\(id)|42\":{\"ref\":{\"sourceID\":\"\(id)\",\"itemID\":\"42\"},"
            + "\"title\":\"第 3 集\",\"hiddenAt\":\"2026-01-01T00:00:00Z\"}}"
        try Data(legacy.utf8).write(to: fileURL)

        let store = makeStore()
        let refs = await store.hiddenRefs(sourceID: sourceID)
        let failure = await store.lastLoadFailureDescription

        XCTAssertEqual(refs, [ref])
        XCTAssertNil(failure, "老文件不是损坏文件")
        let paths = await store.hiddenPaths(sourceID: sourceID)
        XCTAssertTrue(paths.isEmpty)
    }

    // MARK: - 持久化

    func testSnapshotSurvivesANewStoreInstance() async throws {
        try await makeStore().hide(makeItem())

        let reloaded = await makeStore().hiddenRefs(sourceID: sourceID)
        XCTAssertEqual(reloaded.count, 1)
    }

    func testWritesWithRestrictivePermissions() async throws {
        try await makeStore().hide(makeItem())
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600, "「谁不想看什么」属于隐私")
    }

    /// ⛔ 不静默当成「没有隐藏条目」继续跑。
    func testCorruptedFileIsReportedNotSwallowed() async throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore()

        _ = await store.hiddenRefs(sourceID: sourceID)
        let failure = await store.lastLoadFailureDescription
        XCTAssertNotNil(failure, "损坏原因要留下来,不能假装没事")
    }
}
