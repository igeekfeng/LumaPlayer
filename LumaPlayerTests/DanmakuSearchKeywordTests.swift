import XCTest
@testable import LumaPlayer

/// 手动搜索关键词:末尾集号标记剥进 `episode`,作品名不能被切坏。
final class DanmakuSearchKeywordTests: XCTestCase {

    private func split(_ keyword: String) -> DanmakuSearchKeyword.Parts {
        DanmakuSearchKeyword.split(keyword)
    }

    /// 实际踩到的输入:带 `S01E01` 时 `/search/episodes` 0 条。
    func testStripsSceneStyleMarker() {
        XCTAssertEqual(split("暗潮之下 S01E01"), .init(title: "暗潮之下", episode: 1, season: 1))
        XCTAssertEqual(split("暗潮之下 s2e10"), .init(title: "暗潮之下", episode: 10, season: 2))
        XCTAssertEqual(split("暗潮之下 S01 E03"), .init(title: "暗潮之下", episode: 3, season: 1))
        XCTAssertEqual(split("Some.Show.S01E05"), .init(title: "Some.Show", episode: 5, season: 1))
        XCTAssertEqual(split("  暗潮之下 S01E01  "), .init(title: "暗潮之下", episode: 1, season: 1))
    }

    func testStripsEpisodeOnlyMarkers() {
        XCTAssertEqual(split("暗潮之下 E07"), .init(title: "暗潮之下", episode: 7))
        XCTAssertEqual(split("暗潮之下 EP12"), .init(title: "暗潮之下", episode: 12))
        XCTAssertEqual(split("暗潮之下 第3集"), .init(title: "暗潮之下", episode: 3))
        XCTAssertEqual(split("暗潮之下第 3 话"), .init(title: "暗潮之下", episode: 3))
    }

    /// 没有标记、标记不在末尾、标记贴着作品名:原样不动。
    func testLeavesPlainTitlesAlone() {
        XCTAssertEqual(split("暗潮之下"), .init(title: "暗潮之下", episode: nil))
        XCTAssertEqual(split("S01E01 暗潮之下"), .init(title: "S01E01 暗潮之下", episode: nil))
        XCTAssertEqual(split("WALLE2"), .init(title: "WALLE2", episode: nil))
        XCTAssertEqual(split("命运石之门0"), .init(title: "命运石之门0", episode: nil))
    }

    /// 剥完不足 2 个字(接口下限)就不剥;集号 0 不算。
    func testDoesNotStripIntoTooShortTitleOrZero() {
        XCTAssertEqual(split("X S01E01"), .init(title: "X S01E01", episode: nil))
        XCTAssertEqual(split("暗潮之下 E0"), .init(title: "暗潮之下 E0", episode: nil))
    }
}

/// 搜索结果按季在本地筛(接口没有季参数)。
final class DanmakuSearchSeasonFilterTests: XCTestCase {

    private func group(_ id: Int64, _ title: String?) -> DanmakuSearchGroup {
        DanmakuSearchGroup(animeID: id, animeTitle: title, typeDescription: nil, episodes: [])
    }

    private lazy var groups = [
        group(1, "暗潮之下(2026)【电视剧】from renren"),
        group(2, "某番 第二季"),
        group(3, "某番 Season 3"),
        group(4, nil),
    ]

    func testNoSeasonKeepsEverything() {
        XCTAssertEqual(DanmakuSearchKeyword.groups(groups, inSeason: nil).map(\.animeID), [1, 2, 3, 4])
    }

    /// 单季剧标题不写季,算第 1 季 —— 填 1 不能把它筛掉。
    func testUnmarkedTitlesCountAsSeasonOne() {
        XCTAssertEqual(DanmakuSearchKeyword.groups(groups, inSeason: 1).map(\.animeID), [1, 4])
    }

    func testFiltersByMarkedSeason() {
        XCTAssertEqual(DanmakuSearchKeyword.groups(groups, inSeason: 2).map(\.animeID), [2])
        XCTAssertEqual(DanmakuSearchKeyword.groups(groups, inSeason: 3).map(\.animeID), [3])
        XCTAssertEqual(DanmakuSearchKeyword.groups(groups, inSeason: 5).map(\.animeID), [])
    }
}

/// 手动搜索框预填值去掉年份。
final class DanmakuSearchKeywordYearTests: XCTestCase {

    func testRemovesBracketedYear() {
        XCTAssertEqual(DanmakuSearchKeyword.removingYear("暗潮之下 (2026)"), "暗潮之下")
        XCTAssertEqual(DanmakuSearchKeyword.removingYear("暗潮之下（2026）"), "暗潮之下")
        XCTAssertEqual(DanmakuSearchKeyword.removingYear("[2019] 某番"), "某番")
        XCTAssertEqual(DanmakuSearchKeyword.removingYear("某番 【1998】 剧场版"), "某番 剧场版")
    }

    func testRemovesTrailingBareYear() {
        XCTAssertEqual(DanmakuSearchKeyword.removingYear("Some.Show.2026"), "Some.Show")
        XCTAssertEqual(DanmakuSearchKeyword.removingYear("暗潮之下 2026"), "暗潮之下")
    }

    /// 片名里的数字、片名就是年份:不动。
    func testKeepsTitlesThatAreNotYears() {
        XCTAssertEqual(DanmakuSearchKeyword.removingYear("暗潮之下"), "暗潮之下")
        XCTAssertEqual(DanmakuSearchKeyword.removingYear("1917"), "1917")
        XCTAssertEqual(DanmakuSearchKeyword.removingYear("银河铁道999"), "银河铁道999")
        XCTAssertEqual(DanmakuSearchKeyword.removingYear("2001太空漫游"), "2001太空漫游")
        XCTAssertEqual(DanmakuSearchKeyword.removingYear("某番 (12)"), "某番 (12)")
    }

    func testQueryPrefillDropsYearButKeepsTitle() {
        let query = DanmakuMediaQuery(
            itemKey: "k", seriesKey: nil, episodeNumber: 1, title: "暗潮之下 (2026)",
            matchFileName: "暗潮之下 (2026) S01E01", fileSize: nil)
        XCTAssertEqual(query.searchKeyword, "暗潮之下")
        XCTAssertEqual(query.title, "暗潮之下 (2026)")
    }
}
