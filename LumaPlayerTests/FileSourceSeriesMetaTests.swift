import XCTest
@testable import LumaPlayer

/// 剧集详情页标题下那行:季数 / 集数只列一次、不带来源前缀、单季不列季数。
final class FileSourceSeriesMetaTests: XCTestCase {

    func testMultiSeasonShowsBothCounts() {
        XCTAssertEqual(
            FileSourceSeriesMeta.parts(year: 2011, seasons: 8, episodes: 73),
            ["2011", "共 8 季", "共 73 集"])
    }

    /// 只有一季时不显示「共 1 季」(很多剧就一季),但集数照列。
    func testSingleSeasonHidesSeasonCountButKeepsEpisodes() {
        XCTAssertEqual(
            FileSourceSeriesMeta.parts(year: 2024, seasons: 1, episodes: 12),
            ["2024", "共 12 集"])
    }

    func testNoSeasonCountWhenUnknown() {
        XCTAssertEqual(
            FileSourceSeriesMeta.parts(year: 2024, seasons: nil, episodes: 12),
            ["2024", "共 12 集"])
    }

    /// 缺哪段不显示哪段,⛔ 不留空占位、不拿别的字段凑。
    func testMissingPartsAreDropped() {
        XCTAssertEqual(
            FileSourceSeriesMeta.parts(year: nil, seasons: 2, episodes: nil),
            ["共 2 季"])
        XCTAssertEqual(
            FileSourceSeriesMeta.parts(year: nil, seasons: 1, episodes: 0),
            [])
        XCTAssertEqual(
            FileSourceSeriesMeta.parts(year: nil, seasons: nil, episodes: nil),
            [])
    }

    /// 集数为 0 / 负数不列(空占位)。
    func testNonPositiveCountsAreDropped() {
        XCTAssertEqual(
            FileSourceSeriesMeta.parts(year: 2024, seasons: 0, episodes: 0),
            ["2024"])
        XCTAssertEqual(
            FileSourceSeriesMeta.parts(year: 2024, seasons: -1, episodes: -5),
            ["2024"])
    }

    /// 文案里不带「TMDB」等来源前缀。
    func testNoSourcePrefix() {
        let parts = FileSourceSeriesMeta.parts(year: 2011, seasons: 8, episodes: 73)
        XCTAssertTrue(parts.allSatisfy { !$0.contains("TMDB") })
    }
}
