import XCTest
@testable import LumaPlayer

/// 改名提交层(提交动作注入,⛔ 不发真请求)。覆盖分批、顺序、失败处置 ——
/// 改名的安全边界:顺序错了会改丢路径,失败不停会算不出「哪些改了、在哪」。
final class BaiduPanRenameExecutorTests: XCTestCase {

    private let identity = BaiduPanRenamePlanner.SeriesIdentity(
        tmdbID: 63926, title: "一拳超人", year: 2015)

    // MARK: - 分批

    /// 层不能混在一批:`path` 定位在父目录改名后立刻失效(§2.6)。
    func testBatchesSplitByLayerFirst() {
        let plan = makePlan()
        let pending = plan.items.filter { !$0.isUnchanged }

        let byLayer = BaiduPanRenameExecutor.batches(of: pending, batchLimit: 50)
        XCTAssertEqual(byLayer.count, 3, "集文件 / 季目录 / 剧根各一层")
        XCTAssertEqual(byLayer[0].count, 2, "第一层是两集")
        XCTAssertEqual(byLayer[1].first?.fsID, 2, "第二层是季目录")
        XCTAssertEqual(byLayer[2].first?.fsID, 1, "第三层是剧根")

        let byOne = BaiduPanRenameExecutor.batches(of: pending, batchLimit: 1)
        XCTAssertEqual(byOne.count, 4)
        XCTAssertTrue(byOne.allSatisfy { $0.count == 1 })
    }

    // MARK: - 执行

    /// 批次数 UI 要报配额消耗。
    func testAllSucceededRecordsBatchCount() async {
        let plan = makePlan()
        let log = SubmitLog()

        let outcome = await BaiduPanRenameExecutor.run(plan: plan) { operations in
            await log.record(operations)
            return operations.map { _ in Self.info(errno: 0) }
        }

        XCTAssertTrue(outcome.isFullySucceeded)
        XCTAssertEqual(outcome.succeeded.count, 4)
        XCTAssertEqual(outcome.submittedBatches, 3)
        let submitted = await log.count
        XCTAssertEqual(submitted, 3)
    }

    /// 失败即停:撤销清单按改名后的路径定位,中间某层没改成,它下面已改好文件的新路径就推不出来。
    func testStopsAfterFirstFailure() async {
        let plan = makePlan()
        let log = SubmitLog()

        let outcome = await BaiduPanRenameExecutor.run(plan: plan) { operations in
            await log.record(operations)
            return operations.enumerated().map { Self.info(errno: $0.offset == 1 ? -9 : 0) }
        }

        let calls = await log.count
        XCTAssertEqual(calls, 1, "失败后不该再提交后面的层")
        XCTAssertTrue(outcome.stoppedEarly)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.failures.first?.errno, -9)
        XCTAssertEqual(outcome.succeeded.count, 1, "同一批里成功的那条要算进去")
    }

    /// 整批没拿到结果(传输 / 条数对不上):⛔ 不假设「一条都没生效」。
    func testBatchLevelFailureMarksEveryItem() async {
        let plan = makePlan()

        let outcome = await BaiduPanRenameExecutor.run(plan: plan) { _ in
            throw BaiduPanError.transport("连接断了")
        }

        XCTAssertEqual(outcome.failures.count, 2, "第一层的两条都要记")
        XCTAssertTrue(outcome.succeeded.isEmpty)
        XCTAssertTrue(outcome.failures.first?.message.contains("可能已部分生效") == true)
    }

    /// 省请求,也省配额。
    func testSkipsUnchangedItems() async {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人 (2015) {tmdbid-63926}")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/一拳超人 (2015) {tmdbid-63926}/Season 01"),
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人 (2015) {tmdbid-63926}/Season 01/一拳超人 (2015) - S01E01.mp4"),
        ]
        let plan = BaiduPanRenamePlanner.makePlan(
            root: root, entries: entries, identity: identity)

        let outcome = await BaiduPanRenameExecutor.run(plan: plan) { _ in
            XCTFail("全是标准名时不该发请求")
            return []
        }

        XCTAssertEqual(outcome.submittedBatches, 0)
        XCTAssertTrue(outcome.isFullySucceeded)
    }

    // MARK: - 撤销

    /// 先还原剧根,否则下面的定位不到。
    func testRollbackIsReversedAndUsesRenamedPaths() {
        let plan = makePlan()
        let outcome = BaiduPanRenameExecutor.Outcome(
            succeeded: plan.items, failures: [], stoppedEarly: false, submittedBatches: 3)

        let operations = BaiduPanRenameExecutor.rollbackOperations(for: outcome)

        XCTAssertEqual(operations.map(\.newName), ["一拳超人", "S1", "02.mp4", "01.mp4"])
        XCTAssertEqual(
            operations[0].path,
            "/apps/LumaPlayer/一拳超人 (2015) {tmdbid-63926}",
            "剧根要先还原,它的 path 是改名**之后**的那个")
    }

    func testRollbackCoversOnlySucceededItems() {
        let plan = makePlan()
        let outcome = BaiduPanRenameExecutor.Outcome(
            succeeded: Array(plan.items.prefix(1)), failures: [], stoppedEarly: true,
            submittedBatches: 1)

        XCTAssertEqual(BaiduPanRenameExecutor.rollbackOperations(for: outcome).count, 1)
    }

    // MARK: - 工具

    /// 用 actor 不用 `@unchecked Sendable` 盒子(测试也守「并发分层」);`@Sendable` 闭包捕获不了普通 `var`。
    private actor SubmitLog {
        private(set) var batches: [[BaiduPanRenameOperation]] = []

        func record(_ operations: [BaiduPanRenameOperation]) { batches.append(operations) }

        var count: Int { batches.count }
    }

    /// `static`:实例方法会把非 Sendable 的 XCTestCase 拖进 `@Sendable` 闭包。
    private static func info(errno: Int) -> BaiduPanFileManagerResponse.Info {
        BaiduPanFileManagerResponse.Info(errno: errno, path: "")
    }

    private func makePlan() -> BaiduPanRenamePlanner.Plan {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/一拳超人/S1"),
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人/S1/01.mp4"),
            video(fsID: 12, path: "/apps/LumaPlayer/一拳超人/S1/02.mp4"),
        ]
        return BaiduPanRenamePlanner.makePlan(
            root: root, entries: entries, identity: identity)
    }

    private func directory(fsID: UInt64, path: String) -> BaiduPanFile {
        BaiduPanFile(
            fsID: fsID, path: path, name: (path as NSString).lastPathComponent,
            sizeBytes: nil, isDirectory: true, category: nil, modifiedAt: nil, thumbnailURL: nil)
    }

    private func video(fsID: UInt64, path: String) -> BaiduPanFile {
        BaiduPanFile(
            fsID: fsID, path: path, name: (path as NSString).lastPathComponent,
            sizeBytes: 1024, isDirectory: false, category: 1, modifiedAt: nil, thumbnailURL: nil)
    }
}
