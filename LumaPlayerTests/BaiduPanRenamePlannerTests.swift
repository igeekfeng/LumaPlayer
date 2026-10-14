import XCTest
@testable import LumaPlayer

/// 剧集目录 → 标准 TMDB 命名的**计划生成**(纯函数,不联网)。
///
/// 覆盖的是「这会改成什么样」这件事本身:命名规则、跳过判据、冲突与执行顺序。
/// ⛔ 百度侧的提交(执行器)与 TMDB 查询不在这里 —— 它们是另外两层。
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

    /// ★ **执行顺序必须自底向上**:百度 rename 用 path 定位,
    /// 父目录一改,子文件的 path 立刻失效。
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

    /// TMDB **没有**给集标题时,名字里就不带那一段。⛔ 不拿「第 1 集」顶上。
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

    /// TMDB 给了**空串**集标题(真实数据里偶尔有)→ 与「没有」同处置。
    func testTreatsEmptyEpisodeTitleAsMissing() {
        XCTAssertEqual(
            BaiduPanRenamePlanner.episodeStem(prefix: "某剧 (2020)", season: 1, episode: 2, title: ""),
            "某剧 (2020) - S01E02")
        XCTAssertEqual(
            BaiduPanRenamePlanner.episodeStem(prefix: "某剧 (2020)", season: 1, episode: 2, title: "  "),
            "某剧 (2020) - S01E02")
    }

    /// TMDB 没给首播年 → 名字里不带年份段,⛔ 不填 0 或当前年。
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

    /// 剧根下**直接平铺**集文件(一个季文件夹都没有)= 只有一季 → 按第 1 季处理,
    /// 且**不新建** `Season 01` —— 就一季,多一层目录只是添乱。
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

    /// 平铺时集标题要按**第 1 季**去问 TMDB —— 季目录不存在,不能因此什么都不问。
    func testAsksTMDBForSeasonOneWhenFlat() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")
        let entries: [BaiduPanFile] = [
            root,
            video(fsID: 11, path: "/apps/LumaPlayer/一拳超人/01.mp4"),
        ]

        XCTAssertEqual(BaiduPanRenamePlanner.seasonNumbers(in: entries, root: root), [1])
    }

    /// 有季目录时只按季目录问,⛔ 不把「平铺的第 1 季」也算进来。
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

    /// 剧根下一个文件都没有 → 不问 TMDB(那是一次白发的请求)。
    func testAsksTMDBForNothingWhenSeriesDirectoryIsEmpty() {
        let root = directory(fsID: 1, path: "/apps/LumaPlayer/一拳超人")

        XCTAssertEqual(BaiduPanRenamePlanner.seasonNumbers(in: [root], root: root), [])
    }

    /// 剧根下**既有季文件夹、又散着文件** → 散着的那些属于哪一季答不了,跳过。
    /// ⛔ 混放时不能沿用平铺的「按第 1 季」:那种散装文件多半是特别篇 / 花絮。
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

    /// 字幕 / 封面 / `nfo` 不是本功能的对象,不动它。
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

    /// 文件名认不出集号(`花絮.mp4`)→ 跳过,⛔ 不按目录顺序给它编一个集号。
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

    /// 同一季里两个文件算出同一个名字(`01.mp4` 与 `1.mp4`)→ **两个都跳过**。
    /// ⛔ 不保留第一个:数据本身答不了「哪个才是这一集」,挑一个是猜。
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

    /// 改名后撞上**不参与改名**的既有条目(目录里已经有个 `Season 01` 的文件夹)也要跳过。
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

    /// TMDB 集标题里的非法字符要洗掉(`第1集:归来?` → `第1集 归来`)。
    /// ⛔ 不删了事 —— 换成空格更接近原意。
    func testSanitizesIllegalCharactersInEpisodeTitle() {
        let stem = BaiduPanRenamePlanner.episodeStem(
            prefix: "某剧 (2020)", season: 1, episode: 1, title: "第1集:归来?")

        XCTAssertEqual(stem, "某剧 (2020) - S01E01 - 第1集 归来")
    }

    /// 剧名自带非法字符也要洗(标准库命名里 `Show: Name` 很常见)。
    func testSanitizesSeriesTitleInPrefix() {
        let identity = BaiduPanRenamePlanner.SeriesIdentity(
            tmdbID: 5, title: "Star Trek: Voyager", year: 1995)

        XCTAssertEqual(identity.prefix, "Star Trek Voyager (1995)")
    }

    /// 超长集标题按**字节**截断(中文 3 字节/字),不能截出半个字。
    func testTruncatesOversizedNameByBytes() {
        let long = String(repeating: "很长的集标题", count: 40)
        let sanitized = BaiduPanRenamePlanner.sanitize(long)

        XCTAssertLessThanOrEqual(sanitized.utf8.count, 180)
        XCTAssertTrue(sanitized.allSatisfy { $0 != "\u{FFFD}" }, "截断不能切出半个字")
    }

    /// 结尾的点与空格要去掉(网盘 / Windows 系不接受)。
    func testTrimsTrailingDotAndSpaces() {
        XCTAssertEqual(BaiduPanRenamePlanner.sanitize(" 某集标题. "), "某集标题")
    }

    // MARK: - 幂等

    /// 已经是标准名的条目不该重复提交 —— 省请求,也省配额。
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

    /// 集号补零是两位,但**超过 99 不能截断**。
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
