import XCTest
@testable import LumaPlayer

/// 剧集目录 → 标准 TMDB 命名的计划生成(纯函数)。百度侧提交与 TMDB 查询是另外两层,不在这里。
final class BaiduPanRenamePlannerTests: XCTestCase {

    private let identity = BaiduPanRenamePlanner.SeriesIdentity(
        tmdbID: 63926, title: "一拳超人", year: 2015)

    // MARK: - 典型场景

    /// 用户实际的存法:剧名目录 + `S0` / `S1` 季目录 + 集号文件名。
    func testPlansStandardNamesForSeasonDirectories() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/一拳超人/S0"),
            directory(fsID: 3, path: "/apps/LumaPlayer/一拳超人/S1"),
            video(fsID: 10, path: "/apps/LumaPlayer/一拳超人/S0/01.mp4"),
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人/S1/01.mp4"),
            video(fsID: 12, path: "/apps/LumaPlayer/一拳超人/S1/02.mp4"),
        ]

        let plan = BaiduPanRenamePlanner.makePlan(
            root: root,
            entries: entries,
            identity: identity,
            episodeTitles: [
                0: [1: "某个特别篇"],
                1: [1: "最强之人", 2: "孤独的英雄"],
            ])

        XCTAssertEqual(name(plan, fsID: 10), "一拳超人 (2015) - S00E01 - 某个特别篇.mp4")
        XCTAssertEqual(name(plan, fsID: 11), "一拳超人 (2015) - S01E01 - 最强之人.mp4")
        XCTAssertEqual(name(plan, fsID: 12), "一拳超人 (2015) - S01E02 - 孤独的英雄.mp4")
        XCTAssertEqual(name(plan, fsID: 2), "Season 00")
        XCTAssertEqual(name(plan, fsID: 3), "Season 01")
        XCTAssertEqual(name(plan, fsID: 1), "一拳超人 (2015) {tmdbid-63926}")
        XCTAssertTrue(plan.skipped.isEmpty, "这个场景不该有跳过项:\(plan.skipped)")
    }

    /// 百度 rename 用 path 定位,父目录一改子文件的 path 立刻失效。
    func testOrdersItemsBottomUp() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/一拳超人/S1"),
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人/S1/01.mp4"),
        ]

        let plan = BaiduPanRenamePlanner.makePlan(root: root, entries: entries, identity: identity)

        XCTAssertEqual(plan.items.map(\.fsID), [11, 2, 1])
    }

    // MARK: - 不伪造

    /// ⛔ 不拿「第 1 集」顶上。
    func testOmitsEpisodeTitleWhenTMDBHasNone() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/一拳超人/S1"),
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人/S1/01.mp4"),
        ]

        let plan = BaiduPanRenamePlanner.makePlan(root: root, entries: entries, identity: identity)

        XCTAssertEqual(name(plan, fsID: 11), "一拳超人 (2015) - S01E01.mp4")
    }

    /// 真实数据里偶尔有空串集标题。
    func testTreatsEmptyEpisodeTitleAsMissing() {
        XCTAssertEqual(
            BaiduPanRenamePlanner.episodeStem(prefix: "某剧 (2020)", season: 1, episode: 2, title: ""),
            "某剧 (2020) - S01E02")
        XCTAssertEqual(
            BaiduPanRenamePlanner.episodeStem(prefix: "某剧 (2020)", season: 1, episode: 2, title: "  "),
            "某剧 (2020) - S01E02")
    }

    /// ⛔ 不填 0 或当前年。
    func testOmitsYearWhenTMDBHasNone() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/某剧")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/某剧/S2"),
            video(fsID: 11, path: "/apps/LumaPlayer/某剧/S2/03.mp4"),
        ]

        let plan = BaiduPanRenamePlanner.makePlan(
            root: root, entries: entries,
            identity: .init(tmdbID: 7, title: "某剧", year: nil))

        XCTAssertEqual(name(plan, fsID: 11), "某剧 - S02E03.mp4")
        XCTAssertEqual(name(plan, fsID: 1), "某剧 {tmdbid-7}")
    }

    // MARK: - 跳过(每一条都要有原因)

    /// 没有季文件夹 = 只有一季:按第 1 季处理,⛔ 不新建 `Season 01`(多一层目录只是添乱)。
    func testTreatsFlatEpisodeFilesAsSeasonOne() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人/01.mp4"),
            video(fsID: 12, path: "/apps/LumaPlayer/一拳超人/02.mp4"),
        ]

        let plan = BaiduPanRenamePlanner.makePlan(
            root: root, entries: entries, identity: identity,
            episodeTitles: [1: [1: "最强之人", 2: "孤独的英雄"]])

        XCTAssertEqual(name(plan, fsID: 11), "一拳超人 (2015) - S01E01 - 最强之人.mp4")
        XCTAssertEqual(name(plan, fsID: 12), "一拳超人 (2015) - S01E02 - 孤独的英雄.mp4")
        XCTAssertEqual(name(plan, fsID: 1), "一拳超人 (2015) {tmdbid-63926}")
        XCTAssertTrue(plan.isFlat)
        XCTAssertFalse(
            plan.items.contains { $0.target == .seasonDirectory },
            "就一季,不该新建季目录:\(plan.items.map(\.newName))")
        XCTAssertTrue(plan.skipped.isEmpty, "这个场景不该有跳过项:\(plan.skipped)")
    }

    func testAsksTMDBForSeasonOneWhenFlat() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人/01.mp4"),
        ]

        XCTAssertEqual(BaiduPanRenamePlanner.seasonNumbers(in: entries, root: root), [1])
    }

    /// ⛔ 不把「平铺的第 1 季」也算进来。
    func testAsksTMDBForSeasonDirectoriesOnly() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/一拳超人/S0"),
            directory(fsID: 3, path: "/apps/LumaPlayer/一拳超人/S2"),
            video(fsID: 10, path: "/apps/LumaPlayer/一拳超人/S0/01.mp4"),
        ]

        XCTAssertEqual(BaiduPanRenamePlanner.seasonNumbers(in: entries, root: root), [0, 2])
    }

    func testAsksTMDBForNothingWhenSeriesDirectoryIsEmpty() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")

        XCTAssertEqual(BaiduPanRenamePlanner.seasonNumbers(in: [root], root: root), [])
    }

    /// 散着的文件属于哪一季答不了。⛔ 不沿用平铺的「按第 1 季」:混放的散装文件多半是特别篇 / 花絮。
    func testSkipsFlatFilesWhenSeasonDirectoriesExist() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/一拳超人/S1"),
            video(fsID: 10, path: "/apps/LumaPlayer/一拳超人/S1/01.mp4"),
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人/13.mp4"),
        ]

        let plan = BaiduPanRenamePlanner.makePlan(root: root, entries: entries, identity: identity)

        XCTAssertNil(plan.items.first { $0.fsID == 11 })
        XCTAssertEqual(plan.skipped.first?.reason, .seasonAmbiguous)
        XCTAssertFalse(plan.isFlat)
        // 季目录里的照改
        XCTAssertEqual(name(plan, fsID: 10), "一拳超人 (2015) - S01E01.mp4")
    }

    /// 字幕 / 封面 / `nfo` 不是本功能的对象。
    func testSkipsNonPlayableFiles() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/一拳超人/S1"),
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人/S1/01.mp4"),
            other(fsID: 12, path: "/apps/LumaPlayer/一拳超人/S1/01.srt"),
        ]

        let plan = BaiduPanRenamePlanner.makePlan(root: root, entries: entries, identity: identity)

        XCTAssertNil(plan.items.first { $0.fsID == 12 })
        XCTAssertEqual(plan.skipped.first?.reason, .notPlayable)
    }

    /// ⛔ 不按目录顺序给它编一个集号。
    func testSkipsFileWithoutEpisodeNumber() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/一拳超人/S1"),
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人/S1/花絮.mp4"),
        ]

        let plan = BaiduPanRenamePlanner.makePlan(root: root, entries: entries, identity: identity)

        XCTAssertNil(plan.items.first { $0.fsID == 11 })
        XCTAssertEqual(plan.skipped.first?.reason, .episodeNumberUnknown)
    }

    // MARK: - 冲突

    /// `01.mp4` 与 `1.mp4` 撞名:⛔ 不保留第一个,挑一个是猜。
    func testSkipsBothSidesOfDuplicateTargetName() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/一拳超人/S1"),
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人/S1/01.mp4"),
            video(fsID: 12, path: "/apps/LumaPlayer/一拳超人/S1/1.mp4"),
        ]

        let plan = BaiduPanRenamePlanner.makePlan(root: root, entries: entries, identity: identity)

        XCTAssertNil(plan.items.first { $0.fsID == 11 })
        XCTAssertNil(plan.items.first { $0.fsID == 12 })
        XCTAssertEqual(
            plan.skipped.filter { $0.reason == .duplicateTargetName }.count, 2,
            "撞名的两边都要报出来,不能只报一条")
    }

    /// 目录里已有个不参与改名的 `Season 01` 文件夹。
    func testDetectsCollisionWithUntouchedSibling() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/一拳超人/S1"),
            directory(fsID: 3, path: "/apps/LumaPlayer/一拳超人/Season 01"),
        ]

        let plan = BaiduPanRenamePlanner.makePlan(root: root, entries: entries, identity: identity)

        XCTAssertNil(plan.items.first { $0.fsID == 2 })
        XCTAssertTrue(plan.skipped.contains { $0.fsID == 2 && $0.reason == .duplicateTargetName })
    }

    // MARK: - 清洗

    /// `第1集:归来?` → `第1集 归来`:换成空格而不是删掉,更接近原意。
    func testSanitizesIllegalCharactersInEpisodeTitle() {
        let stem = BaiduPanRenamePlanner.episodeStem(
            prefix: "某剧 (2020)", season: 1, episode: 1, title: "第1集:归来?")

        XCTAssertEqual(stem, "某剧 (2020) - S01E01 - 第1集 归来")
    }

    /// 标准库命名里 `Show: Name` 很常见。
    func testSanitizesSeriesTitleInPrefix() {
        let identity = BaiduPanRenamePlanner.SeriesIdentity(
            tmdbID: 5, title: "Star Trek: Voyager", year: 1995)

        XCTAssertEqual(identity.prefix, "Star Trek Voyager (1995)")
    }

    /// 中文 3 字节/字,不能截出半个字。
    func testTruncatesOversizedNameByBytes() {
        let long = String(repeating: "很长的集标题", count: 40)
        let sanitized = BaiduPanRenamePlanner.sanitize(long)

        XCTAssertLessThanOrEqual(sanitized.utf8.count, 180)
        XCTAssertTrue(sanitized.allSatisfy { $0 != "\u{FFFD}" }, "截断不能切出半个字")
    }

    /// 网盘 / Windows 系不接受。
    func testTrimsTrailingDotAndSpaces() {
        XCTAssertEqual(BaiduPanRenamePlanner.sanitize(" 某集标题. "), "某集标题")
    }

    // MARK: - 幂等

    /// 省请求,也省配额。
    func testMarksAlreadyStandardNamesAsUnchanged() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人 (2015) {tmdbid-63926}")
        let entries: [BaiduPanFile] = [
            root,
            directory(fsID: 2, path: "/apps/LumaPlayer/一拳超人 (2015) {tmdbid-63926}/Season 01"),
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人 (2015) {tmdbid-63926}/Season 01/一拳超人 (2015) - S01E01 - 最强之人.mp4"),
        ]

        let plan = BaiduPanRenamePlanner.makePlan(
            root: root, entries: entries, identity: identity,
            episodeTitles: [1: [1: "最强之人"]])

        XCTAssertEqual(plan.actionableCount, 0, "全是标准名时不该还要提交:\(plan.items)")
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    func testPadsToTwoDigitsWithoutTruncating() {
        XCTAssertEqual(BaiduPanRenamePlanner.padded(0), "00")
        XCTAssertEqual(BaiduPanRenamePlanner.padded(1), "01")
        XCTAssertEqual(BaiduPanRenamePlanner.padded(13), "13")
        XCTAssertEqual(BaiduPanRenamePlanner.padded(100), "100")
    }

    // MARK: - 工具

    private func name(_ plan: BaiduPanRenamePlanner.Plan, fsID: UInt64) -> String? {
        plan.items.first { $0.fsID == fsID }?.newName
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

    private func other(fsID: UInt64, path: String) -> BaiduPanFile {
        BaiduPanFile(
            fsID: fsID, path: path, name: (path as NSString).lastPathComponent,
            sizeBytes: 1024, isDirectory: false, category: 4, modifiedAt: nil, thumbnailURL: nil)
    }
}
