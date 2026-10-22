import XCTest
@testable import LumaPlayer

/// 删除 / 隐藏网盘条目时该清哪些本地观看记录。清少了「继续观看」留死卡,清多了误伤同剧其它集的进度;文件只认完全相等,目录才递归包含。
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

    /// `琅琊榜` 与 `琅琊榜2`
    func testDeletingDirectoryDoesNotTouchPrefixSibling() {
        let records = [
            record("1", at: "/apps/LumaPlayer/琅琊榜/01.mp4"),
            record("2", at: "/apps/LumaPlayer/琅琊榜2/01.mp4"),
        ]

        let ids = BaiduPanWatchHistory.fileIDs(
            deletingPath: "/apps/LumaPlayer/琅琊榜", isDirectory: true, from: records)

        XCTAssertEqual(ids, ["1"])
    }

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

    /// `01.mp4` / `01.mp4.part`
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

    /// ⛔ 宁可漏清一条死记录,也不能因空路径把整库当成落在它下面。
    func testEmptyLocatorMatchesNothing() {
        let records = [record("1", at: "")]

        XCTAssertTrue(BaiduPanWatchHistory.fileIDs(
            deletingPath: "/apps/LumaPlayer/琅琊榜", isDirectory: true, from: records).isEmpty)
    }

    // 「已看完 / 位置为 0 的记录也要被圈中」由 `storedRecords` 保证,用例在 `WatchProgressStoreTests.testStoredRecords…`。

    // MARK: - 剧卡上的「已看 N 集」

    /// 每条已看记录给所在目录与所有上层目录各 +1,季文件夹存法(`剧/第1季/01.mp4`)也数得进剧卡;看了一半的不算。
    /// 只统计本地有记录的集:「共几集」要列子目录,配额见 `docs/BAIDU_PAN_API.md` §7。
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

        let counts = FileSourceViewModel.watchedEpisodeCounts(records: records, states: states)

        XCTAssertEqual(counts["/apps/LumaPlayer/琅琊榜"], 2)
        XCTAssertEqual(counts["/apps/LumaPlayer/琅琊榜/第1季"], 1)
        XCTAssertNil(counts["/apps/LumaPlayer/别的剧"], "只看了一半的不算已看")
    }
}
