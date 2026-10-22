import XCTest
@testable import LumaPlayer

/// 片库根的边界判定(`BaiduPanPath`)。第三方应用只能访问 `/apps/{应用目录名}` 一个目录(`docs/BAIDU_PAN_API.md` §3),
/// 授权页没有选文件夹这一步,所以只能在应用目录内选子目录当起点;越界的路径必然打不开。
final class BaiduPanLibraryRootTests: XCTestCase {

    private let root = "/apps/LumaPlayer"

    func testApplicationRootItselfIsAllowed() {
        // 默认起点,允许记下来(等于「没设」)
        XCTAssertTrue(BaiduPanPath.isInside(root, applicationRoot: root))
    }

    func testSubdirectoryIsAllowed() {
        XCTAssertTrue(BaiduPanPath.isInside("/apps/LumaPlayer/电影", applicationRoot: root))
        XCTAssertTrue(BaiduPanPath.isInside("/apps/LumaPlayer/电影/2024", applicationRoot: root))
    }

    /// ⛔ 最要紧:`hasPrefix` 会把名字相近的另一个应用目录也算进来,那是另一个应用的权限。
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
