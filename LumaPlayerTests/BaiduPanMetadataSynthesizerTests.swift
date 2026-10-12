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

    /// `高码率` 这类中文清晰度词也算发布标记 → 标题在它前面截断。
    func testHighBitrateMarkerStopsTitle() {
        let parsed = BaiduPanMetadataSynthesizer.parse(name: "某剧.高码率.1080p.mkv")

        XCTAssertEqual(parsed.title, "某剧")
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

    // MARK: - 剧集文件夹结构(目录名是剧名,文件名只是集号)

    /// ★ `琅琊榜/01.mp4` 这类存法:标题取目录名,集号单独记。
    /// 否则「01」会被当电影名拿去搜 TMDB,配回来的必然是别的片。
    func testNumberedFilesInFolderAdoptFolderNameAsSeries() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [
                makeFile("01.mp4", fsID: 1, inDirectory: "琅琊榜"),
                makeFile("02.mp4", fsID: 2, inDirectory: "琅琊榜"),
            ],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.map(\.item.title), ["琅琊榜", "琅琊榜"])
        XCTAssertEqual(synthesized.map(\.item.kind), [.episode, .episode])
        XCTAssertEqual(synthesized.map(\.item.episodeNumber), [1, 2])
        // 从目录结构解析出来的,照样算「有元数据」,刮削才会去问 TMDB
        XCTAssertEqual(synthesized.first?.item.metadataOrigin, .filename)
    }

    /// ⛔ 孤零零一个 `300.mp4` 不能变成「《Movies》第 300 集」—— 那是配错片。
    /// 目录里**成串**的数字才是剧集的特征。
    func testSingleNumberedFileKeepsItsOwnTitle() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile("300.mp4", fsID: 1, inDirectory: "Movies")],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.first?.item.title, "300")
        XCTAssertEqual(synthesized.first?.item.kind, .video)
        XCTAssertNil(synthesized.first?.item.episodeNumber)
    }

    /// 文件名带明确集标记但没带标题(`E01.mp4` / `第02集.mp4`)也借目录名。
    func testEpisodeMarkerWithoutTitleAdoptsFolderName() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [
                makeFile("E01.mp4", fsID: 1, inDirectory: "某剧"),
                makeFile("第02集.mp4", fsID: 2, inDirectory: "某剧"),
            ],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.map(\.item.title), ["某剧", "某剧"])
        XCTAssertEqual(synthesized.map(\.item.episodeNumber), [1, 2])
    }

    /// ★ `47-4K.高码率.mkv` 这类「集号-发布标记」存法:同目录成串时借目录名当剧名,
    /// 集号单独记。⛔ 否则「47」会被当电影名拿去搜 TMDB,配回来的必然是别的片。
    func testEpisodeWithReleaseTagsAdoptsFolderName() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [
                makeFile("01-4K.高码率.mkv", fsID: 1, inDirectory: "庆余年"),
                makeFile("02-4K.高码率.mkv", fsID: 2, inDirectory: "庆余年"),
            ],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.map(\.item.title), ["庆余年", "庆余年"])
        XCTAssertEqual(synthesized.map(\.item.kind), [.episode, .episode])
        XCTAssertEqual(synthesized.map(\.item.episodeNumber), [1, 2])
        XCTAssertEqual(synthesized.first?.item.metadataOrigin, .filename)
    }

    /// ⛔ 孤零零一个 `300.1080p.BluRay.mkv` 不能变成「第 300 集」——
    /// 它与 `47-4K.高码率.mkv` 结构一样,靠**同目录成串**区分(见 `bareEpisodeNumber`)。
    func testSingleEpisodeWithReleaseTagsStaysMovie() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile("300.1080p.BluRay.mkv", fsID: 1, inDirectory: "Movies")],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.first?.item.kind, .video)
        XCTAssertEqual(synthesized.first?.item.title, "300")
        XCTAssertNil(synthesized.first?.item.episodeNumber)
    }

    /// 文件名自己认得出剧名时**以文件名为准**,⛔ 不拿目录名盖掉它。
    func testFileWithOwnTitleKeepsItInsideEpisodeFolder() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [
                makeFile("01.mp4", fsID: 1, inDirectory: "琅琊榜"),
                makeFile("02.mp4", fsID: 2, inDirectory: "琅琊榜"),
                makeFile("Show.S01E09.mkv", fsID: 3, inDirectory: "琅琊榜"),
            ],
            sourceID: sourceID)

        XCTAssertEqual(synthesized[2].item.title, "Show")
        XCTAssertEqual(synthesized[2].item.episodeNumber, 9)
    }

    /// 集号只认 1–3 位纯数字:4 位是年份的形状(`2012.mp4` 是一部电影)。
    func testBareEpisodeNumberOnlyAcceptsShortDigits() {
        XCTAssertEqual(BaiduPanMetadataSynthesizer.bareEpisodeNumber("01.mp4"), 1)
        XCTAssertEqual(BaiduPanMetadataSynthesizer.bareEpisodeNumber("12.mkv"), 12)
        XCTAssertNil(BaiduPanMetadataSynthesizer.bareEpisodeNumber("2012.mp4"))
        XCTAssertNil(BaiduPanMetadataSynthesizer.bareEpisodeNumber("movie.mp4"))
    }

    /// ★ 「集号 + 发布标记」也当「整个文件名就是集号」:`47-4K.高码率.mkv` → 47。
    /// 判据是集号后面**紧跟**发布标记(与 `parse` 一致),所以连写的 `WEB-DL` 也不影响。
    func testBareEpisodeNumberAcceptsEpisodeFollowedByReleaseTags() {
        XCTAssertEqual(BaiduPanMetadataSynthesizer.bareEpisodeNumber("47-4K.高码率.mkv"), 47)
        XCTAssertEqual(BaiduPanMetadataSynthesizer.bareEpisodeNumber("01-4K.高码率.mkv"), 1)
        XCTAssertEqual(BaiduPanMetadataSynthesizer.bareEpisodeNumber("12.1080p.WEB-DL.mkv"), 12)

        // ⛔ 集号后面不是发布标记 → 那是标题,不是集号
        XCTAssertNil(BaiduPanMetadataSynthesizer.bareEpisodeNumber("47-收藏版.mkv"))
        XCTAssertNil(BaiduPanMetadataSynthesizer.bareEpisodeNumber("某剧.01.1080p.mkv"))
        // ⛔ 4 位数字仍是年份形状
        XCTAssertNil(BaiduPanMetadataSynthesizer.bareEpisodeNumber("2012.1080p.mkv"))
    }

    // MARK: - 季文件夹(剧名取祖父目录,季号取父目录)

    /// ★ `琅琊榜/第13季/01.mp4`:剧名取**祖父**目录,季号取**父**目录。
    /// 这部剧有 13 季,季号判错就会拿第 1 季的分集剧照去配第 13 季的文件。
    func testSeasonFolderTakesGrandparentAsSeriesAndParentAsSeason() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [
                makeFile("01.mp4", fsID: 1, inDirectory: "琅琊榜/第13季"),
                makeFile("02.mp4", fsID: 2, inDirectory: "琅琊榜/第13季"),
            ],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.map(\.item.title), ["琅琊榜", "琅琊榜"])
        XCTAssertEqual(synthesized.map(\.item.kind), [.episode, .episode])
        XCTAssertEqual(synthesized.map(\.item.seasonNumber), [13, 13])
        XCTAssertEqual(synthesized.map(\.item.episodeNumber), [1, 2])
    }

    /// 「集号-发布标记」与季文件夹叠加:`剧名/第13季/01-4K.高码率.mkv`
    /// → 剧名取祖父目录、季号取父目录、集号取文件名。
    func testEpisodeWithReleaseTagsInsideSeasonFolder() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [
                makeFile("01-4K.高码率.mkv", fsID: 1, inDirectory: "剧名/第13季"),
                makeFile("02-4K.高码率.mkv", fsID: 2, inDirectory: "剧名/第13季"),
            ],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.map(\.item.title), ["剧名", "剧名"])
        XCTAssertEqual(synthesized.map(\.item.seasonNumber), [13, 13])
        XCTAssertEqual(synthesized.map(\.item.episodeNumber), [1, 2])
    }

    /// `Season 13` 这种英文写法同样识别,剧名照取祖父目录。
    func testEnglishSeasonFolderIsRecognized() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [
                makeFile("01.mp4", fsID: 1, inDirectory: "Some Show/Season 13"),
                makeFile("02.mp4", fsID: 2, inDirectory: "Some Show/Season 13"),
            ],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.map(\.item.title), ["Some Show", "Some Show"])
        XCTAssertEqual(synthesized.map(\.item.seasonNumber), [13, 13])
    }

    /// 平铺存法(没有季文件夹、文件名也没写季号)→ 季号**留 nil**,
    /// ⛔ 不在合成器里填 1 冒充(拿哪一季去问由刮削层决定)。
    func testFlatFolderLeavesSeasonUnknown() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [
                makeFile("01.mp4", fsID: 1, inDirectory: "琅琊榜"),
                makeFile("02.mp4", fsID: 2, inDirectory: "琅琊榜"),
            ],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.map(\.item.seasonNumber), [nil, nil])
        XCTAssertEqual(synthesized.map(\.item.episodeNumber), [1, 2])
    }

    /// 文件名里的 `SxxExx` 自己带季号 → 直接用它(⛔ 不因为父目录不是季文件夹就丢掉)。
    func testSeasonNumberFromFileNameIsKept() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile("Show.S02E07.1080p.mkv", fsID: 1, inDirectory: "剧集")],
            sourceID: sourceID)

        XCTAssertEqual(synthesized.first?.item.seasonNumber, 2)
        XCTAssertEqual(synthesized.first?.item.episodeNumber, 7)
    }

    /// 季文件夹名识别:只认**整个目录名就是季标记**的写法。
    func testSeasonNumberFromDirectoryNameFormats() {
        // 中文
        XCTAssertEqual(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "第13季"), 13)
        XCTAssertEqual(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "第2季"), 2)
        // 英文:空格 / 无空格 / `.` `_` `-` 都当分隔符
        XCTAssertEqual(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "Season 13"), 13)
        XCTAssertEqual(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "season13"), 13)
        XCTAssertEqual(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "Season.13"), 13)
        XCTAssertEqual(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "season_13"), 13)
        XCTAssertEqual(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "Season-13"), 13)
        // 简写
        XCTAssertEqual(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "S13"), 13)
        XCTAssertEqual(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "s2"), 2)

        // ⛔ 剧名与季号挤在一起的目录名不认(无法可靠切分);中文数字不认
        XCTAssertNil(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "琅琊榜 第13季"))
        XCTAssertNil(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "第十三季"))
        XCTAssertNil(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "琅琊榜"))
        XCTAssertNil(BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: "Season"))
    }

    // MARK: - 显式 TMDB id(`{tmdbid-63926}`)

    /// 认标准命名里的 `{tmdbid-N}` / `[tmdbid-N]` / 裸写,键名 `tmdbid` 与 `tmdb`,
    /// 分隔符 `-` 与 `=` —— 并把该标签从名称里剥掉。
    func testExtractsAndStripsExplicitTMDBID() {
        let braced = BaiduPanMetadataSynthesizer.extractExplicitTMDBID(
            in: "一拳超人 (2015) {tmdbid-63926}")
        XCTAssertEqual(braced?.id, 63926)
        XCTAssertEqual(braced?.cleaned, "一拳超人 (2015)")

        XCTAssertEqual(
            BaiduPanMetadataSynthesizer.extractExplicitTMDBID(in: "[tmdbid-550] Fight Club")?.id, 550)
        XCTAssertEqual(
            BaiduPanMetadataSynthesizer.extractExplicitTMDBID(in: "Fight Club (1999) {tmdb=550}")?.id,
            550)
        XCTAssertEqual(
            BaiduPanMetadataSynthesizer.extractExplicitTMDBID(in: "Show.TMDBID-1234")?.id, 1234)

        // 没有标签 / 数字读不出 → 都没有
        XCTAssertNil(BaiduPanMetadataSynthesizer.extractExplicitTMDBID(in: "Fight Club (1999)"))
        XCTAssertNil(BaiduPanMetadataSynthesizer.extractExplicitTMDBID(in: "{tmdbid-}"))
    }

    /// 文件名里的标签不参与标题,id 被解析出来。
    func testParseStripsTagFromFileName() {
        let parsed = BaiduPanMetadataSynthesizer.parse(
            name: "Fight.Club.1999.{tmdbid-550}.1080p.BluRay.mkv")

        XCTAssertEqual(parsed.tmdbID, 550)
        XCTAssertEqual(parsed.title, "Fight Club")
        XCTAssertEqual(parsed.year, 1999)
    }

    /// 目录卡片:目录名里的 id 进 `tmdbID`,展示名剥掉标签(标签是元数据,不是片名)。
    func testFolderCardCarriesExplicitTMDBID() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile("一拳超人 (2015) {tmdbid-63926}", fsID: 1, isDirectory: true)],
            sourceID: sourceID)

        let item = synthesized.first?.item
        XCTAssertEqual(item?.kind, .folder)
        XCTAssertEqual(item?.tmdbID, 63926)
        XCTAssertEqual(item?.title, "一拳超人 (2015)")
    }

    /// ★ 剧集文件:文件名自己认不出干净剧名(中英混排 + 年份),但**祖先目录**带显式 id
    /// → 剧名与 id 都取自那个目录,季集仍按文件名。
    func testEpisodeBorrowsExplicitIDFromAnnotatedAncestor() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile(
                "一拳超人.ONE PUNCH MAN.2015.S01E12.2160p.BDRip.HEVC.FLAC.AACx2.ASSx2-NoxiaAI.mkv",
                fsID: 1,
                inDirectory: "一拳超人 (2015) {tmdbid-63926}/Season 1")],
            sourceID: sourceID)

        let item = synthesized.first?.item
        XCTAssertEqual(item?.kind, .episode)
        XCTAssertEqual(item?.tmdbID, 63926)
        XCTAssertEqual(item?.title, "一拳超人 (2015)")
        XCTAssertEqual(item?.seasonNumber, 1)
        XCTAssertEqual(item?.episodeNumber, 12)
    }

    /// 文件名没写季号时,季号从祖先目录与文件之间的**季文件夹**(`Season 1`)取。
    func testAnnotatedAncestorSeasonFromSeasonFolder() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile(
                "01.mkv", fsID: 1,
                inDirectory: "一拳超人 (2015) {tmdbid-63926}/Season 1")],
            sourceID: sourceID)

        let item = synthesized.first?.item
        XCTAssertEqual(item?.tmdbID, 63926)
        XCTAssertEqual(item?.title, "一拳超人 (2015)")
        XCTAssertEqual(item?.seasonNumber, 1)
        XCTAssertEqual(item?.episodeNumber, 1)
    }

    /// ⛔ 带标签的祖先目录只对**剧集文件**生效:认不出集号的普通视频不借它的 id,
    /// 免得把预告片 / 花絮当成正片配上那部剧的海报。
    func testAnnotatedAncestorDoesNotApplyToNonEpisode() {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: [makeFile(
                "Some.Movie.2019.1080p.mkv", fsID: 1,
                inDirectory: "一拳超人 (2015) {tmdbid-63926}")],
            sourceID: sourceID)

        let item = synthesized.first?.item
        XCTAssertNil(item?.tmdbID)
        XCTAssertEqual(item?.kind, .video)
        XCTAssertEqual(item?.title, "Some Movie")
    }

    // MARK: - 辅助

    private func makeFile(
        _ name: String,
        fsID: UInt64,
        inDirectory directory: String? = nil,
        isDirectory: Bool = false
    ) -> BaiduPanFile {
        let folder = directory.map { "/\($0)" } ?? ""
        return BaiduPanFile(
            fsID: fsID,
            path: "/apps/LumaPlayer\(folder)/\(name)",
            name: name,
            sizeBytes: isDirectory ? nil : 1024,
            isDirectory: isDirectory,
            category: nil,
            modifiedAt: nil,
            thumbnailURL: nil
        )
    }
}
