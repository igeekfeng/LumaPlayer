import XCTest
@testable import LumaPlayer

/// 片库根的边界判定。
///
/// 背景:第三方应用能访问的范围是 `/apps/{应用目录名}` **一个目录**(§2.1),
/// 百度授权页**没有**「选文件夹」这一步 —— 所以「选」只能发生在应用目录
/// **内部**(选一个子目录当进来时的起点)。这条边界就是那次选择的护栏:
/// 越界的路径第三方应用访问不到,设了就是个必然打不开的入口。
final class BaiduPanLibraryRootTests: XCTestCase {

    private let root = "/apps/LumaPlayer"

    func testApplicationRootItselfIsAllowed() {
        // 它就是默认起点,允许记下来(等于「没设」,UI 那边靠 canSetLibraryRoot 拦)
        XCTAssertTrue(BaiduPanPath.isInside(root, applicationRoot: root))
    }

    func testSubdirectoryIsAllowed() {
        XCTAssertTrue(BaiduPanPath.isInside("/apps/LumaPlayer/电影", applicationRoot: root))
        XCTAssertTrue(BaiduPanPath.isInside("/apps/LumaPlayer/电影/2024", applicationRoot: root))
    }

    /// ⛔ 这是最要紧的一条:`hasPrefix` 会把「名字相近的另一个应用目录」
    /// 也算进范围内,而那个目录的访问权限属于**另一个应用**。
    func testSiblingDirectoryWithSharedPrefixIsRejected() {
        XCTAssertFalse(BaiduPanPath.isInside("/apps/LumaPlayerXX", applicationRoot: root))
        XCTAssertFalse(BaiduPanPath.isInside("/apps/LumaPlayerXX/电影", applicationRoot: root))
    }

    func testPathsOutsideAppsAreRejected() {
        XCTAssertFalse(BaiduPanPath.isInside("/", applicationRoot: root))
        XCTAssertFalse(BaiduPanPath.isInside("/我的资源/电影", applicationRoot: root))
        XCTAssertFalse(BaiduPanPath.isInside("/apps", applicationRoot: root))
        XCTAssertFalse(BaiduPanPath.isInside("/apps/Other/电影", applicationRoot: root))
    }

    func testEmptyInputIsRejected() {
        XCTAssertFalse(BaiduPanPath.isInside("", applicationRoot: root))
        XCTAssertFalse(BaiduPanPath.isInside("/apps/LumaPlayer/电影", applicationRoot: ""))
    }
}
