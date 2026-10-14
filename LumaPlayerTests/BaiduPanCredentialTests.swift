import XCTest
@testable import LumaPlayer

/// 百度凭据在凭据文件里的往返(docs/SOURCE_ABSTRACTION_PLAN.md §4.1:
/// 密钥与 token 一律进凭据文件,不进 `SourceProfile`)。
final class BaiduPanCredentialTests: XCTestCase {
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() {
        super.setUp()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
        try await super.tearDown()
    }

    func testAppConfigurationRoundTrip() async throws {
        let configuration = CredentialStore.BaiduPanAppConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        try await credentials.saveBaiduPanAppConfiguration(configuration)

        let loaded = try await credentials.baiduPanAppConfiguration()
        XCTAssertEqual(loaded, configuration)
    }

    func testTokenRoundTrip() async throws {
        let bundle = BaiduPanTokenBundle(
            accessToken: "AT", refreshToken: "RT",
            expiresAt: Date(timeIntervalSince1970: 1_000_000), scope: "basic netdisk")
        try await credentials.saveBaiduPanToken(bundle)

        let loaded = try await credentials.baiduPanToken()
        XCTAssertEqual(loaded, bundle)
    }

    /// 解绑只删 token,**保留** AppKey / SecretKey / 目录名
    /// —— 重新扫码不该逼用户再填一遍密钥。
    func testDeletingTokenKeepsAppConfiguration() async throws {
        try await credentials.saveBaiduPanAppConfiguration(
            .init(appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer"))
        try await credentials.saveBaiduPanToken(
            BaiduPanTokenBundle(
                accessToken: "AT", refreshToken: "RT",
                expiresAt: Date(timeIntervalSince1970: 1_000_000), scope: nil))

        try await credentials.deleteBaiduPanToken()

        let token = try await credentials.baiduPanToken()
        XCTAssertNil(token)
        let configuration = try await credentials.baiduPanAppConfiguration()
        XCTAssertNotNil(configuration)
    }

    func testLibraryRootRoundTripAndClear() async throws {
        let sourceID = UUID()
        let initial = try await credentials.baiduPanLibraryRoot(for: sourceID)
        XCTAssertNil(initial)

        try await credentials.saveBaiduPanLibraryRoot(
            .init(path: "/apps/LumaPlayer/电影"), for: sourceID)
        let saved = try await credentials.baiduPanLibraryRoot(for: sourceID)
        XCTAssertEqual(saved?.path, "/apps/LumaPlayer/电影")

        try await credentials.saveBaiduPanLibraryRoot(nil, for: sourceID)
        let cleared = try await credentials.baiduPanLibraryRoot(for: sourceID)
        XCTAssertNil(cleared)
    }

    /// 片库根**按来源分**:一个来源配的片库根不会串到另一个来源。
    func testLibraryRootIsScopedPerSource() async throws {
        let a = UUID()
        let b = UUID()
        try await credentials.saveBaiduPanLibraryRoot(
            .init(path: "/apps/LumaPlayer/电影"), for: a)

        let forB = try await credentials.baiduPanLibraryRoot(for: b)
        XCTAssertNil(forB, "另一个来源不该看到这份片库根")
    }

    /// 兼容旧版:片库根曾经是**全 App 一份**的单个值(account `baidu-library-root`)。
    /// 第一次读新键时把它继承过来;写过新键之后就不再回看旧键
    /// —— 于是用户清掉它也不会被「复活」。
    func testLegacyGlobalLibraryRootIsInheritedOnce() async throws {
        let legacy = try JSONEncoder().encode(BaiduPanLibraryRoot(path: "/apps/LumaPlayer/剧集"))
        try await storage.setValue(legacy, forAccount: "baidu-library-root")

        let fresh = UUID()
        let inherited = try await credentials.baiduPanLibraryRoot(for: fresh)
        XCTAssertEqual(inherited?.path, "/apps/LumaPlayer/剧集")

        try await credentials.saveBaiduPanLibraryRoot(nil, for: fresh)
        let afterClear = try await credentials.baiduPanLibraryRoot(for: fresh)
        XCTAssertNil(afterClear, "清掉之后不能再继承旧键")
    }

    /// 删来源时连键一起抹掉(`deleteBaiduPanLibraryRoot`)。
    /// ⚠️ 它与「清空片库根」是两件事:后者必须**留一个「没有」**,见上一条。
    func testDeletingLibraryRootRemovesTheKey() async throws {
        let sourceID = UUID()
        try await credentials.saveBaiduPanLibraryRoot(
            .init(path: "/apps/LumaPlayer/电影"), for: sourceID)

        try await credentials.deleteBaiduPanLibraryRoot(for: sourceID)

        let deleted = try await credentials.baiduPanLibraryRoot(for: sourceID)
        XCTAssertNil(deleted)
    }
}
