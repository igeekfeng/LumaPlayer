import XCTest
@testable import LumaPlayer

/// `QuarkConnection` 的不发网络请求部分 + 扫码轮询 / 刷新重试的状态机。
/// 线格式与请求形状由 `QuarkDecodingTests`、`QuarkAPIClientTests` 锁住。
final class QuarkConnectionTests: XCTestCase {
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var connection: QuarkConnection!
    private let sourceID = UUID()

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        connection = QuarkConnection(
            credentials: credentials,
            client: QuarkAPIClient(
                session: MockEmbyURLProtocol.makeSession(),
                limiter: QuarkRateLimiter(minimumInterval: .zero)))
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
        connection = nil
        MockEmbyURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - 授权状态(只读凭据文件)

    /// 没凭据时是一屏引导,不是错误。
    func testAuthorizationNeedsAuthorizationWithoutCredential() async throws {
        let state = try await connection.authorization()
        XCTAssertEqual(state, .needsAuthorization)
        XCTAssertFalse(state.isAuthorized)
        XCTAssertNil(state.account)
    }

    func testAuthorizationIsAuthorizedWithCredential() async throws {
        let credential = QuarkCredential(
            accessToken: "a", refreshToken: "r", deviceID: "d", queryToken: "q")
        try await credentials.saveQuarkCredential(credential)

        let state = try await connection.authorization()
        XCTAssertTrue(state.isAuthorized)
        XCTAssertEqual(state, .authorized(credential: credential, account: nil))
        // ⛔ 不编占位账号:昵称要发 user_info 才有
        XCTAssertNil(state.account)
    }

    /// ⚠️ `device_id` 必须持久化:换一次就要重新扫码(§1)。
    func testDeviceIDIsStableAcrossCalls() async throws {
        let first = try await connection.deviceID()
        let second = try await connection.deviceID()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(first.allSatisfy(\.isHexDigit))
    }

    /// 已登录时沿用凭据里的那一份,⛔ 不生成新的。
    func testDeviceIDReusesStoredCredential() async throws {
        try await credentials.saveQuarkCredential(
            QuarkCredential(accessToken: "a", refreshToken: "r", deviceID: "stored-device"))
        let deviceID = try await connection.deviceID()
        XCTAssertEqual(deviceID, "stored-device")
    }

    // MARK: - 片库根

    func testLibraryRootRoundTrip() async throws {
        let initial = try await connection.libraryRoot(for: sourceID)
        XCTAssertNil(initial)
        try await connection.setLibraryRoot(
            QuarkLibraryRoot(path: "/影视", name: "影视"), for: sourceID)
        let saved = try await connection.libraryRoot(for: sourceID)
        XCTAssertEqual(saved, QuarkLibraryRoot(path: "/影视", name: "影视"))
        // nil = 明确清空
        try await connection.setLibraryRoot(nil, for: sourceID)
        let cleared = try await connection.libraryRoot(for: sourceID)
        XCTAssertNil(cleared)
    }

    /// 退出登录只删凭据,片库根保留(重新扫码即恢复)。
    func testSignOutKeepsLibraryRoot() async throws {
        try await credentials.saveQuarkCredential(
            QuarkCredential(accessToken: "a", refreshToken: "r", deviceID: "d"))
        try await connection.setLibraryRoot(
            QuarkLibraryRoot(path: "/电影", name: "电影"), for: sourceID)

        try await connection.signOut()

        let state = try await connection.authorization()
        XCTAssertEqual(state, .needsAuthorization)
        let root = try await connection.libraryRoot(for: sourceID)
        XCTAssertNotNil(root)
    }

    // MARK: - 扫码轮询(§4 第 2、3 步)

    private func stubCode(_ body: String, statusCode: Int = 400) {
        MockEmbyURLProtocol.stub(
            .json(body, statusCode: statusCode),
            host: QuarkEndpoint.apiHost, path: "/oauth/code")
    }

    private func stubToken(_ body: String) {
        MockEmbyURLProtocol.stub(
            .json(body), host: QuarkEndpoint.codeHost,
            path: QuarkEndpoint.codeBasePath + "/token")
    }

    private func stubUserInfo(_ body: String) {
        MockEmbyURLProtocol.stub(
            .json(body), host: QuarkEndpoint.apiHost, path: "/user")
    }

    /// 轮询到「未确认」继续等,确认后换 token 落盘。
    ///
    /// ⚠️ 这条是接入的关键:夸克没有独立的状态端点,扫码确认只能靠反复调 `/oauth/code`
    /// 并从 `11003` 里判断「还没好」。
    func testAwaitAuthorizationPollsUntilCodeThenStoresCredential() async throws {
        MockEmbyURLProtocol.stub(
            sequence: [
                .json(#"{"status":-1,"errno":11003,"error_info":"用户未确认授权"}"#, statusCode: 400),
                .json(#"{"status":-1,"errno":11003,"error_info":"用户未确认授权"}"#, statusCode: 400),
                .json(#"{"status":0,"errno":0,"code":"auth-code"}"#),
            ],
            host: QuarkEndpoint.apiHost, path: "/oauth/code")
        stubToken(#"{"code":200,"message":"OK","data":{"status":0,"errno":0,"access_token":"at","refresh_token":"rt","expires_in":3600}}"#)
        stubUserInfo(#"{"status":0,"errno":0,"data":{"nickname":"测试"}}"#)

        let session = QuarkQRCodeSession(imageBase64: "img", queryToken: "qt")
        let account = try await connection.awaitAuthorization(
            session, deviceID: "device-1",
            deadline: Date().addingTimeInterval(30))

        XCTAssertEqual(account.nickname, "测试")
        let stored = try await credentials.quarkCredential()
        XCTAssertEqual(stored?.accessToken, "at")
        XCTAssertEqual(stored?.refreshToken, "rt")
        XCTAssertEqual(stored?.deviceID, "device-1")
        XCTAssertEqual(stored?.queryToken, "qt")
    }

    /// 二维码过期要如实报「换一张」,⛔ 不无限轮询。
    func testAwaitAuthorizationStopsOnExpiredQRCode() async throws {
        stubCode(#"{"status":-1,"errno":11002,"error_info":"授权码Code二维码过期"}"#)
        let session = QuarkQRCodeSession(imageBase64: "img", queryToken: "qt")
        do {
            _ = try await connection.awaitAuthorization(
                session, deviceID: "d", deadline: Date().addingTimeInterval(30))
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            XCTAssertEqual(error, .qrCodeExpired)
        }
    }

    /// 授权码换 token 时回 `11004`:⛔ 不重试同一个 code。
    func testAwaitAuthorizationFailsOnInvalidCode() async throws {
        stubCode(#"{"status":0,"errno":0,"code":"auth-code"}"#)
        stubToken(#"{"code":200,"message":"OK","data":{"status":-1,"errno":11004,"error_info":"授权码Code无效"}}"#)
        let session = QuarkQRCodeSession(imageBase64: "img", queryToken: "qt")
        do {
            _ = try await connection.awaitAuthorization(
                session, deviceID: "d", deadline: Date().addingTimeInterval(30))
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            XCTAssertEqual(error, .authorizationCodeInvalid)
            XCTAssertTrue(error.needsAuthorization)
        }
    }

    /// 超时按本项目自己的上限算(夸克不给有效期,§8)。
    func testAwaitAuthorizationTimesOut() async throws {
        stubCode(#"{"status":-1,"errno":11003,"error_info":"用户未确认授权"}"#)
        let session = QuarkQRCodeSession(imageBase64: "img", queryToken: "qt")
        do {
            _ = try await connection.awaitAuthorization(
                session, deviceID: "d", deadline: Date().addingTimeInterval(-1))
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            XCTAssertEqual(error, .authorizationTimedOut)
            XCTAssertTrue(error.needsAuthorization)
        }
    }

    // MARK: - token 刷新(§3)

    /// 撞上 `11001` 时刷新一次并**重试原请求**,新 `refresh_token` 要落盘。
    func testTokenInvalidRefreshesOnceAndRetries() async throws {
        try await credentials.saveQuarkCredential(
            QuarkCredential(accessToken: "old", refreshToken: "r1", deviceID: "d1"))
        MockEmbyURLProtocol.stub(
            sequence: [
                .json(#"{"status":-1,"errno":11001,"error_info":"Access Token无效"}"#, statusCode: 400),
                .json(#"{"status":0,"errno":0,"data":{"total_count":0,"files":[]}}"#),
            ],
            host: QuarkEndpoint.apiHost, path: "/file")
        stubToken(#"{"code":200,"message":"OK","data":{"status":0,"errno":0,"access_token":"new","refresh_token":"r2"}}"#)

        let page = try await connection.listPage(in: QuarkPath.root, pageIndex: 0)
        XCTAssertTrue(page.files.isEmpty)

        let stored = try await credentials.quarkCredential()
        XCTAssertEqual(stored?.accessToken, "new")
        // ⚠️ refresh_token 会被轮换,新值必须落盘
        XCTAssertEqual(stored?.refreshToken, "r2")
        // ⛔ 设备 id 不能被刷新改掉
        XCTAssertEqual(stored?.deviceID, "d1")
    }

    /// 刷新令牌也失效时抛 `refreshTokenInvalid`(UI 据此回扫码屏)。
    func testRefreshTokenInvalidSurfacesForReauthorization() async throws {
        try await credentials.saveQuarkCredential(
            QuarkCredential(accessToken: "old", refreshToken: "bad", deviceID: "d"))
        MockEmbyURLProtocol.stub(
            .json(#"{"status":-1,"errno":11001,"error_info":"Access Token无效"}"#, statusCode: 400),
            host: QuarkEndpoint.apiHost, path: "/file")
        stubToken(#"{"code":200,"message":"OK","data":{"status":-1,"errno":11000,"error_info":"Refresh Token无效"}}"#)

        do {
            _ = try await connection.listPage(in: QuarkPath.root, pageIndex: 0)
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            XCTAssertEqual(error, .refreshTokenInvalid)
            XCTAssertTrue(error.needsAuthorization)
        }
    }

    /// ⚠️ `10001`(签名被拒)⛔ 不能去刷新 token:那不是 token 的问题(实测语义)。
    func testSignatureFailureDoesNotTriggerRefresh() async throws {
        try await credentials.saveQuarkCredential(
            QuarkCredential(accessToken: "a", refreshToken: "r", deviceID: "d"))
        MockEmbyURLProtocol.stub(
            .json(#"{"status":-1,"errno":10001,"error_info":"签名验证失败，禁止访问"}"#,
                  statusCode: 400),
            host: QuarkEndpoint.apiHost, path: "/file")

        do {
            _ = try await connection.listPage(in: QuarkPath.root, pageIndex: 0)
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            XCTAssertEqual(error, .server(code: 10001, message: "签名验证失败，禁止访问"))
        }
        // 一次刷新请求都不该发出去(路径不对会落到 404,而这里断言的是「没请求」)
        XCTAssertNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/quarkdrive/token"))
    }

    // MARK: - 路径 ↔ fid

    /// 列目录时顺手记住每一层:进子目录 / 起播就不用再按路径走一遍。
    func testListingRemembersChildFids() async throws {
        try await credentials.saveQuarkCredential(
            QuarkCredential(accessToken: "a", refreshToken: "r", deviceID: "d"))
        MockEmbyURLProtocol.stub(
            .json(#"{"status":0,"errno":0,"data":{"total_count":1,"files":[{"fid":"child-fid","filename":"影视","isdir":1}]}}"#),
            host: QuarkEndpoint.apiHost, path: "/file")

        _ = try await connection.listPage(in: QuarkPath.root, pageIndex: 0)
        // 索引命中后不再发请求:把 /file 的桩清掉,再问一次仍然能拿到 fid
        MockEmbyURLProtocol.reset()
        let fid = try await connection.fid(forPath: "/影视")
        XCTAssertEqual(fid, "child-fid")
        XCTAssertNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/file"))
    }

    /// 根目录的 fid 是 `"0"`,不需要发请求。
    func testRootPathMapsToRootFidWithoutRequest() async throws {
        let fid = try await connection.fid(forPath: "/")
        XCTAssertEqual(fid, QuarkEndpoint.rootFid)
        XCTAssertNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/file"))
    }

    /// 路径解析要翻完整个目录:目标在第 2 页时不能误判成「不存在」。
    func testPathResolutionPagesThroughUntilFound() async throws {
        try await credentials.saveQuarkCredential(
            QuarkCredential(accessToken: "a", refreshToken: "r", deviceID: "d"))
        let firstPage = #"{"status":0,"errno":0,"data":{"total_count":150,"files":[{"fid":"a","filename":"别的","isdir":1}]}}"#
        let secondPage = #"{"status":0,"errno":0,"data":{"total_count":150,"files":[{"fid":"target","filename":"影视","isdir":1}]}}"#
        MockEmbyURLProtocol.stub(
            sequence: [.json(firstPage), .json(secondPage)],
            host: QuarkEndpoint.apiHost, path: "/file")

        let fid = try await connection.fid(forPath: "/影视")
        XCTAssertEqual(fid, "target")
    }

    /// 找不到就是 `directoryNotFound`,上层据此静默回落网盘根。
    func testMissingDirectorySurfacesDirectoryNotFound() async throws {
        try await credentials.saveQuarkCredential(
            QuarkCredential(accessToken: "a", refreshToken: "r", deviceID: "d"))
        MockEmbyURLProtocol.stub(
            .json(#"{"status":0,"errno":0,"data":{"total_count":0,"files":[]}}"#),
            host: QuarkEndpoint.apiHost, path: "/file")

        do {
            _ = try await connection.fid(forPath: "/不存在的目录")
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            XCTAssertTrue(error.isDirectoryUnavailable)
            if case .directoryNotFound(let path) = error {
                XCTAssertEqual(path, "/不存在的目录")
            } else {
                XCTFail("错误的错误档:\(error)")
            }
        }
    }

    // MARK: - 取直链

    /// 播放按**虚拟路径**取链(条目 id 是路径派生的哈希,反推不回 fid)。
    func testPlaybackLinkResolvesPathThenAsksForURL() async throws {
        try await credentials.saveQuarkCredential(
            QuarkCredential(accessToken: "a", refreshToken: "r", deviceID: "d"))
        MockEmbyURLProtocol.reset()
        // 先列根记住子目录,再取链
        MockEmbyURLProtocol.stub(
            sequence: [
                .json(#"{"status":0,"errno":0,"data":{"total_count":1,"files":[{"fid":"dir","filename":"影视","isdir":1}]}}"#),
                .json(#"{"status":0,"errno":0,"data":{"total_count":0,"files":[]}}"#),
            ],
            host: QuarkEndpoint.apiHost, path: "/file")
        _ = try await connection.listPage(in: QuarkPath.root, pageIndex: 0)

        MockEmbyURLProtocol.stub(
            .json(#"{"status":0,"errno":0,"data":{"fid":"dir","size":99,"download_url":"https://cdn.example.com/v"}}"#),
            host: QuarkEndpoint.apiHost, path: "/file")
        let link = try await connection.playbackLink(forPath: "/影视")
        XCTAssertEqual(link.url.absoluteString, "https://cdn.example.com/v")
        XCTAssertEqual(link.sizeBytes, 99)

        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/file"))
        let items = try XCTUnwrap(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(map["method"], "download")
        XCTAssertEqual(map["fid"], "dir")
    }
}
