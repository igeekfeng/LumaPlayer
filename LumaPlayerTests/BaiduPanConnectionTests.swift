import XCTest
@testable import LumaPlayer

/// 只覆盖 `BaiduPanConnection` 不发网络请求的部分;设备码轮询 / 列表 / 播放流需要真网盘账号,未验证。
final class BaiduPanConnectionTests: XCTestCase {
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var connection: BaiduPanConnection!
    /// 片库根按来源存,读写要个键。
    private let sourceID = UUID()

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

    /// 一屏引导,不是错误
    func testAuthorizationIsUnconfiguredWithoutCredentials() async throws {
        let state = try await connection.authorization()

        XCTAssertEqual(state, .unconfigured)
        XCTAssertNil(state.accountName)
    }

    /// 没目录名时第三方应用访问不到任何目录,放过去只会卡在必然打不开的库上。
    func testAuthorizationIsUnconfiguredWhenFolderNameMissing() async throws {
        try await credentials.saveBaiduPanAppConfiguration(
            .init(appKey: "KEY", secretKey: "SECRET", folderName: "  "))

        let state = try await connection.authorization()

        XCTAssertEqual(state, .unconfigured)
    }

    func testAuthorizationNeedsAuthorizationWithoutToken() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        let state = try await connection.authorization()

        XCTAssertEqual(state, .needsAuthorization(folderName: "LumaPlayer"))
    }

    /// 昵称要另发 `uinfo` 才有,⛔ 不编占位账号。
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

    /// 重新扫码不该逼用户再填一遍密钥。
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

    /// token 由密钥签发、与目录名无关,⛔ 无条件删 token 会让人为改个笔误再扫码;但旧片库根落在旧应用目录里会失效,由返回值告诉调用方。
    func testChangingFolderNameKeepsTokenButInvalidatesLibraryRoots() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "Old")
        try await credentials.saveBaiduPanToken(
            BaiduPanTokenBundle(
                accessToken: "AT", refreshToken: "RT",
                expiresAt: Date(timeIntervalSince1970: 1_000_000), scope: nil))

        let invalidated = try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "New")

        let token = try await credentials.baiduPanToken()
        XCTAssertNotNil(token, "改目录名不该作废 token")
        XCTAssertTrue(invalidated, "应用目录变了，已有的片库根全部失效")
    }

    func testChangingAppKeyInvalidatesTokenAndLibraryRoots() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        try await credentials.saveBaiduPanToken(
            BaiduPanTokenBundle(
                accessToken: "AT", refreshToken: "RT",
                expiresAt: Date(timeIntervalSince1970: 1_000_000), scope: nil))

        let invalidated = try await connection.saveConfiguration(
            appKey: "OTHER", secretKey: "SECRET", folderName: "LumaPlayer")

        let token = try await credentials.baiduPanToken()
        XCTAssertNil(token)
        XCTAssertTrue(invalidated)
    }

    /// 否则每添加一个来源都会白清一遍片库根。
    func testSavingIdenticalConfigurationDoesNotInvalidateLibraryRoots() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        let invalidated = try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        XCTAssertFalse(invalidated)
    }

    // MARK: - 片库根

    /// 同一个授权下的不同来源各记各的。
    func testSetLibraryRootAcceptsSubdirectory() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        try await connection.setLibraryRoot("/apps/LumaPlayer/电影", for: sourceID)

        let root = try await connection.libraryRoot(for: sourceID)
        XCTAssertEqual(root?.path, "/apps/LumaPlayer/电影")
    }

    /// ⛔ 不存、也不静默改写成应用目录。
    func testSetLibraryRootRejectsPathOutsideApplicationDirectory() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        do {
            try await connection.setLibraryRoot("/apps/LumaPlayerXX/电影", for: sourceID)
            XCTFail("越界路径应当被拒绝")
        } catch let error as BaiduPanError {
            guard case .configuration = error else {
                return XCTFail("应当是 .configuration，实际 \(error)")
            }
        }
        let stored = try await credentials.baiduPanLibraryRoot(for: sourceID)
        XCTAssertNil(stored)
    }

    /// 每次读都重新校验:改了应用目录名后旧路径失效,当作没设,⛔ 不报「配置损坏」。
    func testStaleLibraryRootIsTreatedAsUnset() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        // 绕过 setLibraryRoot 直接落一条「另一个应用目录」的值
        try await credentials.saveBaiduPanLibraryRoot(
            .init(path: "/apps/Other/电影"), for: sourceID)

        let root = try await connection.libraryRoot(for: sourceID)
        XCTAssertNil(root, "越界的那条当作没设")
    }

    func testLibraryRootIsNilWhenNeverSet() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        let root = try await connection.libraryRoot(for: sourceID)
        XCTAssertNil(root)
    }

    func testClearingLibraryRootRemovesIt() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        try await connection.setLibraryRoot("/apps/LumaPlayer/电影", for: sourceID)

        try await connection.setLibraryRoot(nil, for: sourceID)

        let root = try await connection.libraryRoot(for: sourceID)
        XCTAssertNil(root)
    }

    /// 否则用户刚删掉的起点会被旧版全局键 `baidu-library-root` 重新继承回来。
    func testClearedLibraryRootDoesNotReviveFromLegacy() async throws {
        try await connection.saveConfiguration(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        // 旧版是全 App 一份:直接往那个 account 落一条
        try await storage.setValue(
            JSONEncoder().encode(BaiduPanLibraryRoot(path: "/apps/LumaPlayer/旧起点")),
            forAccount: "baidu-library-root")

        // 先确认它确实被继承了,否则这条测试什么都没测到
        let inherited = try await connection.libraryRoot(for: sourceID)
        XCTAssertEqual(inherited?.path, "/apps/LumaPlayer/旧起点")

        try await connection.setLibraryRoot(nil, for: sourceID)

        let root = try await connection.libraryRoot(for: sourceID)
        XCTAssertNil(root, "清掉之后不能再从旧键继承回来")
    }

    // MARK: - 直连地址拼接

    /// 只在末尾追加 `access_token`。
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

    /// token 里可能出现 `+`,不整体编码签名就对不上。
    func testAppendingAccessTokenPercentEncodesToken() throws {
        let url = try XCTUnwrap(BaiduPanConnection.appendingAccessToken(
            to: "https://d.pcs.baidu.com/file/x", token: "a+b/c"))

        XCTAssertEqual(
            url.absoluteString, "https://d.pcs.baidu.com/file/x?access_token=a%2Bb%2Fc")
    }
}
