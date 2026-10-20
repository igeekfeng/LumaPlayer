import XCTest
@testable import LumaPlayer

/// 删除 / 隐藏一条网盘条目时,**本地观看记录**该清哪些(`BaiduPanWatchHistory`,纯函数)。
///
/// 这块判定的分量:清少了 → 「继续观看」里留一张点开就播不了的卡;清多了 →
/// 同剧其它集的进度被误伤(用户会看到「看过的集又变成没看过」)。
/// 判据只有路径,所以这里逐条钉住「文件只认完全相等、目录才递归包含」。
final class BaiduPanWatchHistoryTests: XCTestCase {

    private let sourceID = UUID()

    private func record(
        _ fileID: String,
        at path: String
    ) -> WatchProgressStore.StoredRecord {
        WatchProgressStore.StoredRecord(
            fileID: fileID,
            display: WatchProgressStore.Display(
                sourceID: sourceID,
                title: "琅琊榜",
                locator: path,
                fileName: (path as NSString).lastPathComponent,
                cover: nil,
                episodeNumber: Int(fileID)
            )
        )
    }

    // MARK: - 删目录:递归包含

    func testDeletingSeriesDirectoryTakesEveryEpisodeRecord() {
        let records = [
            record("1", at: "/apps/LumaPlayer/琅琊榜/01.mp4"),
            record("2", at: "/apps/LumaPlayer/琅琊榜/第1季/02.mp4"),
            record("9", at: "/apps/LumaPlayer/别的剧/01.mp4"),
        ]

        let ids = BaiduPanWatchHistory.fileIDs(
            deletingPath: "/apps/LumaPlayer/琅琊榜", isDirectory: true, from: records)

        XCTAssertEqual(Set(ids), ["1", "2"], "目录要递归包含,别处的一集都不能碰")
    }

    /// 前缀相似的兄弟目录不能被误伤(`琅琊榜` 与 `琅琊榜2`)。
    func testDeletingDirectoryDoesNotTouchPrefixSibling() {
        let records = [
            record("1", at: "/apps/LumaPlayer/琅琊榜/01.mp4"),
            record("2", at: "/apps/LumaPlayer/琅琊榜2/01.mp4"),
        ]

        let ids = BaiduPanWatchHistory.fileIDs(
            deletingPath: "/apps/LumaPlayer/琅琊榜", isDirectory: true, from: records)

        XCTAssertEqual(ids, ["1"])
    }

    /// 删一个季目录只清这一季,别的季留着。
    func testDeletingSeasonDirectoryKeepsOtherSeasons() {
        let records = [
            record("1", at: "/apps/LumaPlayer/琅琊榜/第1季/01.mp4"),
            record("2", at: "/apps/LumaPlayer/琅琊榜/第2季/01.mp4"),
        ]

        let ids = BaiduPanWatchHistory.fileIDs(
            deletingPath: "/apps/LumaPlayer/琅琊榜/第1季", isDirectory: true, from: records)

        XCTAssertEqual(ids, ["1"])
    }

    // MARK: - 删单个文件:只清那一条

    func testDeletingOneFileKeepsSiblingEpisodes() {
        let records = [
            record("1", at: "/apps/LumaPlayer/琅琊榜/01.mp4"),
            record("2", at: "/apps/LumaPlayer/琅琊榜/02.mp4"),
        ]

        let ids = BaiduPanWatchHistory.fileIDs(
            deletingPath: "/apps/LumaPlayer/琅琊榜/01.mp4", isDirectory: false, from: records)

        XCTAssertEqual(ids, ["1"], "删一集不该把同剧别集的进度一起清了")
    }

    /// 同一目录、文件名是另一个文件的前缀(`01.mp4` / `01.mp4.part`):文件判定必须完全相等。
    func testFileMatchIsExactNotPrefix() {
        let records = [record("2", at: "/apps/LumaPlayer/琅琊榜/01.mp4.part")]

        let ids = BaiduPanWatchHistory.fileIDs(
            deletingPath: "/apps/LumaPlayer/琅琊榜/01.mp4", isDirectory: false, from: records)

        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - 边界

    func testEmptyPathSelectsNothing() {
        let records = [record("1", at: "/apps/LumaPlayer/琅琊榜/01.mp4")]
        XCTAssertTrue(BaiduPanWatchHistory.fileIDs(
            deletingPath: "", isDirectory: true, from: records).isEmpty)
        XCTAssertTrue(BaiduPanWatchHistory.fileIDs(
            deletingPath: "", isDirectory: false, from: records).isEmpty)
    }

    /// 记录里缺 `locator`(空串)时谁都圈不中 —— ⛔ 宁可漏清一条死记录,
    /// 也不能因为空路径把**整库**都当成「落在它下面」。
    func testEmptyLocatorMatchesNothing() {
        let records = [record("1", at: "")]

        XCTAssertTrue(BaiduPanWatchHistory.fileIDs(
            deletingPath: "/apps/LumaPlayer/琅琊榜", isDirectory: true, from: records).isEmpty)
    }

    // ⚠️ 「已看完 / 位置为 0 的记录也要被圈中」这件事由 `storedRecords` 保证
    // (它本来就不过滤),用例在 `WatchProgressStoreTests.testStoredRecords…` 那一组。

    // MARK: - 剧卡上的「已看 N 集」

    /// 一条已看记录给它所在目录与**所有上层目录**各 +1 —— 剧目录卡片查的就是自己的
    /// 路径,所以季文件夹存法(`剧/第1季/01.mp4`)也数得进去;只看了一半的不算。
    ///
    /// ⚠️ 这个数只统计**本地有记录**的集:网格上算不出「共几集 / 还有几集未看」
    /// (那要列子目录,配额见 `docs/BAIDU_PAN_API.md` §7)。
    @MainActor
    func testWatchedEpisodeCountsRollUpThroughAncestors() {
        let records = [
            record("1", at: "/apps/LumaPlayer/琅琊榜/01.mp4"),
            record("2", at: "/apps/LumaPlayer/琅琊榜/第1季/02.mp4"),
            record("3", at: "/apps/LumaPlayer/别的剧/01.mp4"),
        ]
        let states: [String: WatchProgressStore.WatchState] = [
            "1": .watched,
            "2": .watched,
            "3": .inProgress(seconds: 20),
        ]

        let counts = BaiduPanSourceViewModel.watchedEpisodeCounts(records: records, states: states)

        XCTAssertEqual(counts["/apps/LumaPlayer/琅琊榜"], 2)
        XCTAssertEqual(counts["/apps/LumaPlayer/琅琊榜/第1季"], 1)
        XCTAssertNil(counts["/apps/LumaPlayer/别的剧"], "只看了一半的不算已看")
    }
}
