import XCTest
@testable import LumaPlayer

/// `BaiduPanConnection` 里**不发网络请求**的那些：授权状态、应用目录、片库根边界、
/// 配置变更对 token 的连带影响。
///
/// 真实的设备码轮询 / 列表 / 播放流需要真网盘账号(本机没有)，按
/// `docs/SOURCE_ABSTRACTION_PLAN.md` §7 的约定标注为「未验证」，不在这里假装覆盖。
final class BaiduPanConnectionTests: XCTestCase {
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var connection: BaiduPanConnection!

    override func setUp() {
        super.setUp()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        connection = BaiduPanConnection(credentials: credentials)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
        connection = nil
        try await super.tearDown()
    }

    // MARK: - 授权状态（读凭据文件，不发网络请求）

    /// 什么都没配 → `.unconfigured`（一屏，不是错误）
    func testAuthorizationIsUnconfiguredWithoutCredentials() async throws {
        let state = try await connection.authorization()

        XCTAssertEqual(state, .unconfigured)
        XCTAssertNil(state.accountName)
    }

    /// 有密钥但没「应用目录名」→ 同样算没配好：第三方应用访问不到任何目录，
    /// 放过去只会让人卡在一个必然打不开的库上。
    func testAuthorizationIsUnconfiguredWhenFolderNameMissing() async throws {
        try await credentials.saveBaiduPanAppConfiguration(
            .init(appKey: "KEY", secretKey: "SECRET", folderName: "  "))

        let state = try await connection.authorization()

        XCTAssertEqual(state, .unconfigured)
    }

    /// 配好了但没 token → 要去扫码
    func testAuthorizationNeedsAuthorizationWithoutToken() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        let state = try await connection.authorization()

        XCTAssertEqual(state, .needsAuthorization(folderName: "LumaPlayer"))
    }

    /// 有 token → 已授权。账号昵称要另发一次 `uinfo` 才有，
    /// 这里**不编占位账号**（`account` 为 nil）。
    func testAuthorizationIsAuthorizedWithToken() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        try await credentials.saveBaiduPanToken(
            BaiduPanTokenBundle(
                accessToken: "AT", refreshToken: "RT",
                expiresAt: Date(timeIntervalSince1970: 1_000_000), scope: nil))

        let state = try await connection.authorization()

        XCTAssertEqual(state, .authorized(account: nil))
    }

    /// 解绑只删 token，**保留** AppKey / SecretKey / 目录名
    /// —— 重新扫码不该逼用户再填一遍密钥。
    func testSignOutKeepsConfiguration() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        try await credentials.saveBaiduPanToken(
            BaiduPanTokenBundle(
                accessToken: "AT", refreshToken: "RT",
                expiresAt: Date(timeIntervalSince1970: 1_000_000), scope: nil))

        try await connection.signOut()

        let state = try await connection.authorization()
        XCTAssertEqual(state, .needsAuthorization(folderName: "LumaPlayer"))
    }

    // MARK: - 应用目录

    func testApplicationDirectoryNormalizesSlashAndWhitespace() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: " /LumaPlayer/ ")

        let directory = try await connection.applicationDirectory()

        XCTAssertEqual(directory, "/apps/LumaPlayer")
    }

    func testApplicationDirectoryThrowsWithoutConfiguration() async throws {
        do {
            _ = try await connection.applicationDirectory()
            XCTFail("没配置时应当抛错")
        } catch let error as BaiduPanError {
            XCTAssertEqual(error, .appCredentialsMissing)
        }
    }

    // MARK: - 配置变更对 token 的连带影响

    /// 只改「应用目录名」不必重新扫码：token 是那对密钥签发的，与目录名无关。
    /// ⛔ 无条件删 token 会让人为了改个笔误再扫一次码。
    func testChangingFolderNameKeepsTokenButDropsLibraryRoot() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "Old")
        try await credentials.saveBaiduPanToken(
            BaiduPanTokenBundle(
                accessToken: "AT", refreshToken: "RT",
                expiresAt: Date(timeIntervalSince1970: 1_000_000), scope: nil))
        try await credentials.saveBaiduPanLibraryRoot(.init(path: "/apps/Old/剧集"))

        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "New")

        let token = try await credentials.baiduPanToken()
        XCTAssertNotNil(token, "改目录名不该作废 token")
        // 旧片库根落在新应用目录之外了，留着是垃圾
        let root = try await credentials.baiduPanLibraryRoot()
        XCTAssertNil(root)
    }

    /// 换了密钥 = 换了一套授权：token 与片库根都必须一起作废。
    func testChangingAppKeyInvalidatesTokenAndLibraryRoot() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        try await credentials.saveBaiduPanToken(
            BaiduPanTokenBundle(
                accessToken: "AT", refreshToken: "RT",
                expiresAt: Date(timeIntervalSince1970: 1_000_000), scope: nil))
        try await credentials.saveBaiduPanLibraryRoot(.init(path: "/apps/LumaPlayer/剧集"))

        try await connection.saveConfiguration(
            appKey: "OTHER", secretKey: "SECRET", folderName: "LumaPlayer")

        let token = try await credentials.baiduPanToken()
        XCTAssertNil(token)
        let root = try await credentials.baiduPanLibraryRoot()
        XCTAssertNil(root)
    }

    // MARK: - 片库根边界

    func testSetLibraryRootAcceptsSubdirectory() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        try await connection.setLibraryRoot("/apps/LumaPlayer/电影")

        let root = try await connection.libraryRoot()
        XCTAssertEqual(root, "/apps/LumaPlayer/电影")
    }

    /// ⛔ 越界的路径直接拒绝，不存、也不静默改写成应用目录。
    func testSetLibraryRootRejectsPathOutsideApplicationDirectory() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        do {
            try await connection.setLibraryRoot("/apps/LumaPlayerXX/电影")
            XCTFail("越界路径应当被拒绝")
        } catch let error as BaiduPanError {
            guard case .configuration = error else {
                return XCTFail("应当是 .configuration，实际 \(error)")
            }
        }
        let stored = try await credentials.baiduPanLibraryRoot()
        XCTAssertNil(stored)
    }

    /// 存下来的路径**每次读都重新校验**：用户回头改了应用目录名之后，
    /// 旧路径整个失效 —— 静默回落到应用目录，⛔ 不报「配置损坏」。
    func testLibraryRootFallsBackWhenStoredPathIsStale() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        // 绕过 setLibraryRoot 直接落一个「另一个应用目录」的值
        try await credentials.saveBaiduPanLibraryRoot(.init(path: "/apps/Other/电影"))

        let root = try await connection.libraryRoot()
        XCTAssertNil(root)
    }

    func testLibraryRootIsNilWhenNeverSet() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        let root = try await connection.libraryRoot()
        XCTAssertNil(root)
    }

    func testClearingLibraryRootRemovesIt() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        try await connection.setLibraryRoot("/apps/LumaPlayer/电影")

        try await connection.setLibraryRoot(nil)

        let root = try await connection.libraryRoot()
        XCTAssertNil(root)
    }

    // MARK: - 直连地址拼接

    /// `dlink` 的查询串必须**原样保留**，只在末尾追加 `access_token`。
    func testAppendingAccessTokenKeepsExistingQueryVerbatim() throws {
        let url = try XCTUnwrap(BaiduPanConnection.appendingAccessToken(
            to: "https://d.pcs.baidu.com/file/x?sign=AbC%2BdEf%3D", token: "TOK"))

        XCTAssertEqual(
            url.absoluteString,
            "https://d.pcs.baidu.com/file/x?sign=AbC%2BdEf%3D&access_token=TOK")
    }

    func testAppendingAccessTokenUsesQuestionMarkWhenNoQuery() throws {
        let url = try XCTUnwrap(BaiduPanConnection.appendingAccessToken(
            to: "https://d.pcs.baidu.com/file/x", token: "TOK"))

        XCTAssertEqual(
            url.absoluteString, "https://d.pcs.baidu.com/file/x?access_token=TOK")
    }

    /// token 里可能出现 `+` 这类字符，必须整体编码 —— 否则签名又对不上。
    func testAppendingAccessTokenPercentEncodesToken() throws {
        let url = try XCTUnwrap(BaiduPanConnection.appendingAccessToken(
            to: "https://d.pcs.baidu.com/file/x", token: "a+b/c"))

        XCTAssertEqual(
            url.absoluteString, "https://d.pcs.baidu.com/file/x?access_token=a%2Bb%2Fc")
    }
}
