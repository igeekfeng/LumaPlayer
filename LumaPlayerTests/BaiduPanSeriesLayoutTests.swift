import XCTest
@testable import LumaPlayer

/// 目录形态判定与季结构(`BaiduPanSeriesLayout`,纯函数)。
///
/// 这块判定的分量在于:**判错一次,整个片库的观感就崩了** ——
/// 片库里的「电影」「纪录片」这类分类目录下面全是子目录,一旦被当成剧集,
/// 点进去就是一张莫名其妙的详情页;反过来,`琅琊榜/第1季/` 判不出来,
/// 用户就只能看到一层文件夹,拿不到与 Emby 对齐的观感。
final class BaiduPanSeriesLayoutTests: XCTestCase {

    private let sourceID = UUID()
    private var nextFsID: UInt64 = 5000

    // MARK: - 工具

    private func item(
        _ title: String,
        kind: SourceItemKind,
        episode: Int? = nil,
        season: Int? = nil,
        episodeTitle: String? = nil
    ) -> SourceItem {
        nextFsID += 1
        return SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: nextFsID),
            title: title,
            kind: kind,
            overview: nil,
            year: nil,
            tmdbID: nil,
            episodeNumber: episode,
            seasonNumber: season,
            episodeTitle: episodeTitle,
            durationSeconds: nil,
            poster: nil,
            metadataOrigin: .none
        )
    }

    private func file(
        _ name: String,
        directory: String = "/apps/LumaPlayer/琅琊榜",
        isDirectory: Bool = false
    ) -> BaiduPanFile {
        nextFsID += 1
        return BaiduPanFile(
            fsID: nextFsID,
            path: "\(directory)/\(name)",
            name: name,
            sizeBytes: isDirectory ? nil : 1_000,
            isDirectory: isDirectory,
            category: isDirectory ? nil : BaiduPanCategory.video,
            modifiedAt: nil,
            thumbnailURL: nil
        )
    }

    // MARK: - 普通目录

    func testEmptyDirectoryStaysDirectory() {
        XCTAssertEqual(BaiduPanSeriesLayout.shape(of: []), .directory)
    }

    /// 片库里的分类目录:下面全是**别的片名**的子目录,⛔ 一个都不许当季。
    func testCategoryDirectoryWithNamedSubfoldersStaysDirectory() {
        let items = [
            item("肖申克的救赎", kind: .folder),
            item("教父", kind: .folder),
            item("盗梦空间", kind: .folder),
        ]
        XCTAssertEqual(BaiduPanSeriesLayout.shape(of: items), .directory)
    }

    /// 平铺的电影:合成器给的是 `.video`(不是 `.episode`),不构成剧集。
    func testDirectoryOfMoviesStaysDirectory() {
        let items = [
            item("肖申克的救赎", kind: .video),
            item("教父", kind: .video),
        ]
        XCTAssertEqual(BaiduPanSeriesLayout.shape(of: items), .directory)
    }

    // MARK: - 平铺存法:剧目录下直接是集文件

    func testFlatEpisodesBecomeFirstSeason() {
        let items = [
            item("琅琊榜", kind: .episode, episode: 1),
            item("琅琊榜", kind: .episode, episode: 2),
            item("琅琊榜", kind: .episode, episode: 3),
        ]
        guard let structure = BaiduPanSeriesLayout.shape(of: items).seriesStructure else {
            return XCTFail("平铺的集文件应当判成一部剧")
        }
        XCTAssertEqual(structure.seasons.count, 1)
        XCTAssertEqual(structure.seasons.first?.number, 1)
        XCTAssertEqual(structure.seasons.first?.title, "第 1 季")
        XCTAssertTrue(structure.isSingleSeason)
        guard case .flatFiles(let episodes)? = structure.seasons.first?.source else {
            return XCTFail("平铺存法的季应当直接拿着条目")
        }
        XCTAssertEqual(episodes.count, 3)
    }

    // MARK: - 季文件夹存法

    func testSeasonFoldersBecomeSeasons() {
        let items = [
            item("第2季", kind: .folder, season: 2),
            item("第1季", kind: .folder, season: 1),
        ]
        guard let structure = BaiduPanSeriesLayout.shape(of: items).seriesStructure else {
            return XCTFail("季文件夹应当判成一部剧")
        }
        XCTAssertEqual(structure.seasons.map(\.number), [1, 2])
        XCTAssertEqual(structure.seasons.map(\.title), ["第 1 季", "第 2 季"])
        XCTAssertFalse(structure.isSingleSeason)
    }

    /// 季文件夹是**自己就成立**的判据:一季只有一集(特别篇季)也照样认。
    func testSingleSeasonFolderIsStillSeries() {
        let items = [item("S0", kind: .folder, season: 0)]
        guard let structure = BaiduPanSeriesLayout.shape(of: items).seriesStructure else {
            return XCTFail("单个季文件夹也应当判成一部剧")
        }
        // 第 0 季是 TMDB 口径的特别篇,不是「没解析出来」
        XCTAssertEqual(structure.seasons.first?.title, "特别篇")
    }

    func testEnglishSeasonFolderTitles() {
        let items = [
            item("Season 1", kind: .folder, season: 1),
            item("Season 2", kind: .folder, season: 2),
        ]
        XCTAssertEqual(
            BaiduPanSeriesLayout.shape(of: items).seriesStructure?.seasons.map(\.title),
            ["第 1 季", "第 2 季"])
    }

    /// 季文件夹与平铺文件并存(罕见存法):平铺的那批**单列一季**,⛔ 不静默吞掉。
    func testFlatEpisodesAlongsideSeasonFoldersGetTheirOwnSeason() {
        let items = [
            item("第1季", kind: .folder, season: 1),
            item("琅琊榜", kind: .episode, episode: 1),
            item("琅琊榜", kind: .episode, episode: 2),
        ]
        guard let structure = BaiduPanSeriesLayout.shape(of: items).seriesStructure else {
            return XCTFail("应当判成一部剧")
        }
        XCTAssertEqual(structure.seasons.count, 2)
        XCTAssertEqual(structure.seasons.first?.number, 1)
        // 没有季号的那一季排最后,标题如实写「未分季」
        XCTAssertNil(structure.seasons.last?.number)
        XCTAssertEqual(structure.seasons.last?.title, "未分季")
    }

    // MARK: - 分集排序

    func testEpisodesSortByNumberNotByString() {
        let items = [
            item("剧", kind: .episode, episode: 10),
            item("剧", kind: .episode, episode: 2),
            item("剧", kind: .episode, episode: 1),
        ]
        let sorted = BaiduPanSeriesLayout.sortedEpisodes(items)
        XCTAssertEqual(sorted.compactMap(\.episodeNumber), [1, 2, 10])
    }

    func testEpisodesWithoutNumberGoLast() {
        let items = [
            item("番外", kind: .episode),
            item("剧", kind: .episode, episode: 2),
            item("剧", kind: .episode, episode: 1),
        ]
        let sorted = BaiduPanSeriesLayout.sortedEpisodes(items)
        XCTAssertEqual(sorted.compactMap(\.episodeNumber), [1, 2])
        XCTAssertEqual(sorted.last?.title, "番外")
    }

    // MARK: - 与合成器的联动

    /// 合成器要把**目录名整个是季标记**的目录的季号填进条目 ——
    /// 那是形态判定与详情页季列表的唯一线索。
    func testSynthesizerFillsSeasonNumberForSeasonFolder() {
        let result = BaiduPanMetadataSynthesizer.synthesize(
            files: [file("第13季", isDirectory: true)], sourceID: sourceID)
        XCTAssertEqual(result.first?.item.seasonNumber, 13)
    }

    func testSynthesizerLeavesSeasonNumberNilForOrdinaryFolder() {
        let result = BaiduPanMetadataSynthesizer.synthesize(
            files: [file("电影", isDirectory: true)], sourceID: sourceID)
        XCTAssertNil(result.first?.item.seasonNumber)
    }

    /// 端到端:网盘里的 `琅琊榜/第1季/`、`琅琊榜/第2季/` 这一层要判成一部剧。
    func testSynthesizedSeasonFoldersFormASeries() {
        let files = [
            file("第1季", directory: "/apps/LumaPlayer/琅琊榜", isDirectory: true),
            file("第2季", directory: "/apps/LumaPlayer/琅琊榜", isDirectory: true),
        ]
        let items = BaiduPanMetadataSynthesizer.synthesize(files: files, sourceID: sourceID)
            .map(\.item)
        let structure = BaiduPanSeriesLayout.shape(of: items).seriesStructure
        XCTAssertEqual(structure?.seasons.map(\.number), [1, 2])
    }

    /// 端到端:网盘里的 `琅琊榜/01.mp4`、`琅琊榜/02.mp4` 要判成第 1 季。
    func testSynthesizedFlatEpisodesFormFirstSeason() {
        let files = [
            file("01.mp4", directory: "/apps/LumaPlayer/琅琊榜"),
            file("02.mp4", directory: "/apps/LumaPlayer/琅琊榜"),
        ]
        let items = BaiduPanMetadataSynthesizer.synthesize(files: files, sourceID: sourceID)
            .map(\.item)
        let structure = BaiduPanSeriesLayout.shape(of: items).seriesStructure
        XCTAssertEqual(structure?.seasons.count, 1)
        XCTAssertEqual(structure?.seasons.first?.number, 1)
    }

    /// 端到端:片库分类目录(子目录名不是季标记)⛔ 不许判成剧集。
    func testSynthesizedCategoryFoldersStayDirectory() {
        let files = [
            file("肖申克的救赎", directory: "/apps/LumaPlayer/电影", isDirectory: true),
            file("教父", directory: "/apps/LumaPlayer/电影", isDirectory: true),
        ]
        let items = BaiduPanMetadataSynthesizer.synthesize(files: files, sourceID: sourceID)
            .map(\.item)
        XCTAssertEqual(BaiduPanSeriesLayout.shape(of: items), .directory)
    }
}
