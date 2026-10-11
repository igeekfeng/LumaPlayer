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

    func testLibraryRootRoundTripAndDelete() async throws {
        let initial = try await credentials.baiduPanLibraryRoot()
        XCTAssertNil(initial)

        try await credentials.saveBaiduPanLibraryRoot(.init(path: "/apps/LumaPlayer/剧集"))
        let saved = try await credentials.baiduPanLibraryRoot()
        XCTAssertEqual(saved?.path, "/apps/LumaPlayer/剧集")

        try await credentials.deleteBaiduPanLibraryRoot()
        let deleted = try await credentials.baiduPanLibraryRoot()
        XCTAssertNil(deleted)
    }
}
