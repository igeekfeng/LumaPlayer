import XCTest
@testable import LumaPlayer

/// 百度文件名 → 元数据的**本地合成**(纯函数)。
///
/// 这是「百度也有 Emby 观感」的核心一步:百度只给文件名,
/// 标题 / 年份 / 封面全靠本地合成 —— ⛔ 不联网刮削、⛔ 不硬造简介
/// (`docs/SOURCE_ABSTRACTION_PLAN.md` §6.3)。
final class BaiduPanMetadataSynthesizerTests: XCTestCase {

    private let sourceID = UUID()

    // MARK: - 文件名解析

    func testParsesTitleAndYearBeforeReleaseTags() {
        let parsed = BaiduPanMetadataSynthesizer.parse(
            name: "The.Matrix.1999.1080p.BluRay.x264.mkv")

        XCTAssertEqual(parsed.title, "The Matrix")
        XCTAssertEqual(parsed.year, 1999)
        XCTAssertNil(parsed.episode)
    }

    /// ★ 片名里的 4 位数字不能被当成年份。
    /// 判据是「年份后面必须紧跟发布标记」—— `1917` 后面跟的是 `2019`,不是发布标记。
    func testDoesNotMistakeTitleNumberForYear() {
        let parsed = BaiduPanMetadataSynthesizer.parse(
            name: "1917.2019.1080p.WEB-DL.mp4")

        XCTAssertEqual(parsed.title, "1917")
        XCTAssertEqual(parsed.year, 2019)
    }

    func testParsesSeasonEpisode() {
        let parsed = BaiduPanMetadataSynthesizer.parse(name: "Some.Show.S02E07.1080p.mkv")

        XCTAssertEqual(parsed.title, "Some Show")
        XCTAssertEqual(parsed.season, 2)
        XCTAssertEqual(parsed.episode, 7)
    }

    func testParsesChineseEpisodeMarker() {
        let parsed = BaiduPanMetadataSynthesizer.parse(name: "某剧.第12集.1080p.mp4")

        XCTAssertEqual(parsed.title, "某剧")
        XCTAssertEqual(parsed.episode, 12)
    }

    /// 中文字幕 / 语言标记常常**连写成一个 token**(`国语中字`),所以要按「包含」判。
    func testChineseReleaseMarkerStopsTitle() {
        let parsed = BaiduPanMetadataSynthesizer.parse(name: "流浪地球.2019.国语中字.mkv")

        XCTAssertEqual(parsed.title, "流浪地球")
        XCTAssertEqual(parsed.year, 2019)
    }

    /// 没有任何发布标记时,整个文件名都是标题 —— ⛔ 不为了「看起来像个标题」而截断。
    func testTitleWithoutTagsKeepsEverything() {
        let parsed = BaiduPanMetadataSynthesizer.parse(name: "我的电影.mp4")

        XCTAssertEqual(parsed.title, "我的电影")
        XCTAssertNil(parsed.year)
    }

    // MARK: - 目录合成

    func testFoldersBecomeFolderCards() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile("剧集", fsID: 1, isDirectory: true)],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.count, 1)
        XCTAssertEqual(synthesized[0].item.kind, .folder)
        XCTAssertEqual(synthesized[0].item.title, "剧集")
        XCTAssertNil(synthesized[0].cover)
    }

    /// ⛔ 图片与 `.nfo` 不单独成卡 —— 本 App 是播放器不是图库。
    /// 否则一个 1 部片 + 1 张封面的目录会变成两张卡。
    func testImagesAndSidecarsDoNotBecomeCards() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [
                makeFile("movie.mkv", fsID: 1),
                makeFile("movie.jpg", fsID: 2),
                makeFile("movie.nfo", fsID: 3),
                makeFile("movie.srt", fsID: 4),
            ],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.count, 1)
        XCTAssertEqual(synthesized[0].item.title, "movie")
    }

    func testSameNameImageIsPickedAsCover() {
        let poster = makeFile("movie.jpg", fsID: 99)
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile("movie.mkv", fsID: 1), poster],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.first?.cover?.fsID, 99)
    }

    /// 同名图优先于目录级封面(`poster.jpg`)
    func testSameNameImageBeatsDirectoryPoster() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [
                makeFile("movie.mkv", fsID: 1),
                makeFile("poster.jpg", fsID: 50),
                makeFile("movie.jpg", fsID: 99),
            ],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.first?.cover?.fsID, 99)
    }

    func testDirectoryPosterIsUsedWhenNoSameNameImage() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile("movie.mkv", fsID: 1), makeFile("poster.jpg", fsID: 50)],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.first?.cover?.fsID, 50)
    }

    /// 大写的 `Poster.JPG` 也得认 —— 网盘里大小写不受我们控制。
    func testCoverMatchingIsCaseInsensitive() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile("Movie.MKV", fsID: 1), makeFile("Poster.JPG", fsID: 50)],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.first?.cover?.fsID, 50)
    }

    /// 配不到封面就**如实**留空(UI 降级成图标卡),⛔ 不塞一张假的占位图。
    func testNoCoverWhenDirectoryHasNoImage() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile("movie.mkv", fsID: 1), makeFile("other.txt", fsID: 2)],
            sourceID: sourceID)

        XCTAssertNil(synthesized.first?.cover)
        XCTAssertNil(synthesized.first?.item.poster)
    }

    /// 剧集(文件名带 SxxExx)在条目上要标成 `.episode`
    func testEpisodeFileBecomesEpisodeItem() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile("Show.S01E02.1080p.mkv", fsID: 1)],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.first?.item.kind, .episode)
    }

    func testAudioFileBecomesAudioItem() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile("song.mp3", fsID: 1)],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.first?.item.kind, .audio)
    }

    // MARK: - 辅助

    private func makeFile(
        _ name: String,
        fsID: UInt64,
        isDirectory: Bool = false
    ) -> BaiduPanFile {
        BaiduPanFile(
            fsID: fsID,
            path: "/apps/LumaPlayer/\(name)",
            name: name,
            sizeBytes: isDirectory ? nil : 1024,
            isDirectory: isDirectory,
            category: nil,
            modifiedAt: nil,
            thumbnailURL: nil
        )
    }
}
