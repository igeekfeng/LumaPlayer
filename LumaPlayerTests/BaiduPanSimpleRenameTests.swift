import XCTest
@testable import LumaPlayer

/// 右键「重命名…」的输入规则:只改最后一段(`docs/BAIDU_PAN_API.md` §2.5),所以只拦空 / 带 `/` / 没改。
final class BaiduPanSimpleRenameTests: XCTestCase {

    private let original = "琅琊榜.S01E01.mkv"

    func testAcceptsAPlainNewName() {
        XCTAssertNil(BaiduPanSimpleRename.issue(name: "第一集", original: original))
        XCTAssertNil(BaiduPanSimpleRename.issue(name: "琅琊榜 S01E02.mkv", original: original))
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(BaiduPanSimpleRename.cleaned("  第一集  "), "第一集")
        // ⛔ 不动中间的空格:那是名字的一部分
        XCTAssertEqual(BaiduPanSimpleRename.cleaned(" 琅琊榜 第一集 "), "琅琊榜 第一集")
    }

    /// 首尾空白不算改:去完与原名一样就是「没改」。
    func testWhitespaceOnlyDifferenceIsUnchanged() {
        XCTAssertEqual(
            BaiduPanSimpleRename.issue(name: "  \(original)\n", original: original), .unchanged)
    }

    func testRejectsEmptyName() {
        XCTAssertEqual(BaiduPanSimpleRename.issue(name: "", original: original), .empty)
        XCTAssertEqual(BaiduPanSimpleRename.issue(name: "   ", original: original), .empty)
    }

    /// `opera=rename` 只改最后一段,带 `/` 会被服务端当成非法名字 —— 提交前就说清楚。
    func testRejectsSlash() {
        XCTAssertEqual(
            BaiduPanSimpleRename.issue(name: "第一季/01.mkv", original: original), .containsSlash)
    }

    func testRejectsUnchangedName() {
        XCTAssertEqual(BaiduPanSimpleRename.issue(name: original, original: original), .unchanged)
    }

    /// 扩展名变化是允许的(用户改的就是名字),提示由界面那层给,⛔ 不在这里拦。
    func testAllowsChangingTheExtension() {
        XCTAssertNil(BaiduPanSimpleRename.issue(name: "琅琊榜.S01E01.mp4", original: original))
        XCTAssertNil(BaiduPanSimpleRename.issue(name: "琅琊榜.S01E01", original: original))
    }

    /// 只有 `/` 是非法:Windows 那套 `?*:"<>|` 在百度上不是我们自己定的规矩,⛔ 不自己加。
    func testDoesNotInventExtraForbiddenCharacters() {
        XCTAssertNil(BaiduPanSimpleRename.issue(name: "第 1 集:开场?", original: original))
    }

    // MARK: - 本地路径换算

    /// 改名后的路径只换最后一段,⛔ 不动父目录(那是 `opera=move` 的事)。
    func testRenamedPathKeepsParentAndSwapsLastComponent() {
        let operation = BaiduPanRenameOperation(
            path: "/apps/LumaPlayer/琅琊榜/琅琊榜.S01E01.mkv", newName: "第一集.mkv")
        XCTAssertEqual(operation.renamedPath, "/apps/LumaPlayer/琅琊榜/第一集.mkv")
    }

    /// `fs_id` 不变是本项目的既有假设(§2.7 第 4 条):进度 / 已看 / 刮削缓存都按它存。
    func testRenamedFileKeepsFSIDAndMetadata() {
        let file = BaiduPanFile(
            fsID: 42, path: "/apps/LumaPlayer/剧/01.mp4", name: "01.mp4",
            sizeBytes: 1234, isDirectory: false, category: 1,
            modifiedAt: Date(timeIntervalSince1970: 100), thumbnailURL: nil)

        let renamed = file.renamed(
            to: "/apps/LumaPlayer/剧/第一集.mp4", name: "第一集.mp4")

        XCTAssertEqual(renamed.fsID, 42)
        XCTAssertEqual(renamed.path, "/apps/LumaPlayer/剧/第一集.mp4")
        XCTAssertEqual(renamed.name, "第一集.mp4")
        XCTAssertEqual(renamed.sizeBytes, 1234)
        XCTAssertEqual(renamed.category, 1)
        XCTAssertEqual(renamed.modifiedAt, file.modifiedAt)
        XCTAssertFalse(renamed.isDirectory)
    }
}
