import XCTest
@testable import LumaPlayer

/// 百度 `order=name` 是纯字符串序(`10.mp4` 在 `2.mp4` 前),剧集排序要客户端自己做(`docs/BAIDU_PAN_API.md` §2.2)。
final class BaiduPanSortOrderTests: XCTestCase {

    private let sourceID = UUID()
    private var nextFsID: UInt64 = 1000

    // MARK: - 工具

    /// 默认落在 `/apps/LumaPlayer/琅琊榜`(剧集文件夹结构)。
    private func file(
        _ name: String,
        directory: String = "/apps/LumaPlayer/琅琊榜",
        size: UInt64? = 1_000,
        modifiedAt: Date? = nil,
        isDirectory: Bool = false
    ) -> BaiduPanFile {
        nextFsID += 1
        return BaiduPanFile(
            fsID: nextFsID,
            path: "\(directory)/\(name)",
            name: name,
            sizeBytes: isDirectory ? nil : size,
            isDirectory: isDirectory,
            category: isDirectory ? nil : BaiduPanCategory.video,
            modifiedAt: modifiedAt,
            thumbnailURL: nil
        )
    }

    private func files(
        _ names: String...,
        directory: String = "/apps/LumaPlayer/琅琊榜"
    ) -> [BaiduPanFile] {
        names.map { file($0, directory: directory) }
    }

    /// 走完整条链路(合成 → 排序)后回原始文件名。⛔ 不手搓 `SourceItem`:集号 / 季号由 `BaiduPanMetadataSynthesizer` 解析,手搓就跳过了被测的那一步。
    private func sortedNames(
        _ files: [BaiduPanFile],
        order: BaiduPanSortOrder,
        ascending: Bool? = nil
    ) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: files.map { (String($0.fsID), $0.name) })
        let items = BaiduPanMetadataSynthesizer.synthesize(files: files, sourceID: sourceID)
            .map(\.item)
        let byID = Dictionary(uniqueKeysWithValues: files.map { ($0.fsID, $0) })
        return order
            .apply(to: items, filesByID: byID, ascending: ascending ?? order.defaultAscending)
            .map { names[$0.contentID] ?? $0.title }
    }

    // MARK: - 剧集顺序(默认)

    func testEpisodeOrderSortsNumbersNumerically() {
        let input = files("1.mp4", "10.mp4", "11.mp4", "12.mp4", "2.mp4", "3.mp4")

        XCTAssertEqual(
            sortedNames(input, order: .episode),
            ["1.mp4", "2.mp4", "3.mp4", "10.mp4", "11.mp4", "12.mp4"]
        )
    }

    func testEpisodeOrderSortsBySeasonThenEpisode() {
        let input = files("S02E01.mkv", "S01E10.mkv", "S01E02.mkv")

        XCTAssertEqual(
            sortedNames(input, order: .episode),
            ["S01E02.mkv", "S01E10.mkv", "S02E01.mkv"]
        )
    }

    /// 目录恒在最前、不跟随升降序;但目录之间的顺序跟随。
    func testEpisodeOrderKeepsFoldersFirstInBothDirections() {
        let input = [
            file("2.mp4"),
            file("第10季", isDirectory: true),
            file("1.mp4"),
            file("第2季", isDirectory: true),
        ]

        XCTAssertEqual(
            sortedNames(input, order: .episode),
            ["第2季", "第10季", "1.mp4", "2.mp4"]
        )
        XCTAssertEqual(
            sortedNames(input, order: .episode, ascending: false),
            ["第10季", "第2季", "2.mp4", "1.mp4"]
        )
    }

    /// 花絮、混进剧集目录的电影 ⛔ 不占「第 1 集」的位置。
    func testEpisodeOrderPutsItemsWithoutEpisodeNumberLast() {
        let input = files("1.mp4", "Making.of.2019.1080p.mkv", "2.mp4")

        XCTAssertEqual(
            sortedNames(input, order: .episode),
            ["1.mp4", "2.mp4", "Making.of.2019.1080p.mkv"]
        )
    }

    // MARK: - 名称

    func testNameOrderIsNatural() {
        XCTAssertEqual(
            sortedNames(files("10.mp4", "2.mp4"), order: .name),
            ["2.mp4", "10.mp4"]
        )
    }

    /// 剧集文件夹结构下 `title` 是剧名(整个目录都一样),拿它排等于没排。
    func testNameOrderUsesOriginalFileNameNotSeriesTitle() {
        let input = files("第10集.mp4", "第2集.mp4")

        XCTAssertEqual(
            sortedNames(input, order: .name),
            ["第2集.mp4", "第10集.mp4"]
        )
    }

    // MARK: - 修改时间 / 大小

    /// 缺 `server_mtime` ⛔ 不当成 1970。
    func testModifiedDateOrderPutsNewestFirstAndUnknownLast() {
        let input = [
            file("older.mp4", modifiedAt: Date(timeIntervalSince1970: 1_000_000)),
            file("unknown.mp4", modifiedAt: nil),
            file("newer.mp4", modifiedAt: Date(timeIntervalSince1970: 2_000_000)),
        ]

        XCTAssertEqual(
            sortedNames(input, order: .modifiedDate),
            ["newer.mp4", "older.mp4", "unknown.mp4"]
        )
    }

    /// 缺 `size` ⛔ 不当成 0 字节。
    func testSizeOrderPutsLargestFirstAndUnknownLast() {
        let input = [
            file("small.mp4", size: 10),
            file("unknown.mp4", size: nil),
            file("big.mp4", size: 5_000_000_000),
        ]

        XCTAssertEqual(
            sortedNames(input, order: .size),
            ["big.mp4", "small.mp4", "unknown.mp4"]
        )
    }

    /// 「缺值排最后」不跟随升降序;当成「值最小」处理的话倒序会把它顶到最前。
    func testUnknownValuesStayLastWhenDescending() {
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)

        XCTAssertEqual(
            sortedNames(
                [file("older.mp4", modifiedAt: older), file("unknown.mp4", modifiedAt: nil),
                 file("newer.mp4", modifiedAt: newer)],
                order: .modifiedDate, ascending: false),
            ["newer.mp4", "older.mp4", "unknown.mp4"]
        )
        XCTAssertEqual(
            sortedNames(
                [file("small.mp4", size: 10), file("unknown.mp4", size: nil),
                 file("big.mp4", size: 5_000_000_000)],
                order: .size, ascending: true),
            ["small.mp4", "big.mp4", "unknown.mp4"]
        )
    }

    // MARK: - 方向

    func testDescendingReversesEpisodeOrder() {
        XCTAssertEqual(
            sortedNames(files("1.mp4", "2.mp4", "10.mp4"), order: .episode, ascending: false),
            ["10.mp4", "2.mp4", "1.mp4"]
        )
    }

    func testDefaultDirections() {
        XCTAssertTrue(BaiduPanSortOrder.episode.defaultAscending)
        XCTAssertTrue(BaiduPanSortOrder.name.defaultAscending)
        XCTAssertFalse(BaiduPanSortOrder.modifiedDate.defaultAscending)
        XCTAssertFalse(BaiduPanSortOrder.size.defaultAscending)
    }

    /// 兜底键是自然名,否则同键条目的顺序随数据规模漂移、测试不可复现。
    func testEqualKeysFallBackToNaturalName() {
        let sameMoment = Date(timeIntervalSince1970: 1_000_000)
        let input = [
            file("10.mp4", modifiedAt: sameMoment),
            file("2.mp4", modifiedAt: sameMoment),
        ]

        XCTAssertEqual(
            sortedNames(input, order: .modifiedDate),
            ["2.mp4", "10.mp4"]
        )
    }
}
