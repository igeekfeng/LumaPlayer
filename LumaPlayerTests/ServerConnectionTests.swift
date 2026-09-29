import XCTest
@testable import LumaPlayer

/// 与 `authenticate_success_synthetic.json` 里的 `User.Id` 一致。
private let fixtureUserID = "00000000-0000-0000-0000-000000000003"

/// 探测(`/emby` 前缀 + 局域网 http 回退)、登录、登出,以及**多服务器隔离**
/// (API_CONTRACT.md 1.4、2.5;ARCHITECTURE.md 10.2)。
///
/// 全部走 `MockEmbyURLProtocol`,零真实网络依赖。
/// `public_info.json` 是**真实响应脱敏**后的 fixture(4.7.11.0,2026-09-22);
/// 登录与 Views 仍是 `_synthetic` 构造数据 —— 它们的响应含 token,只能靠结构推断
/// (API_CONTRACT.md 9.4),见 docs/KNOWN_ISSUES.md Q11。
final class ServerConnectionTests: XCTestCase {
    private var session: URLSession!
    private var credentialsFile: URL!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var cacheDirectory: URL!
    private var responseCache: EmbyResponseCache!

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
        credentialsFile = .temporaryCredentialsFile()
        storage = CredentialFileStore(fileURL: credentialsFile)
        credentials = CredentialStore(storage: storage)
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaPlayerConnectionCacheTests-\(UUID().uuidString)", isDirectory: true)
        responseCache = EmbyResponseCache(directory: cacheDirectory)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentialsFile = nil
        credentials = nil
        session = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        cacheDirectory = nil
        responseCache = nil
        try await super.tearDown()
    }

    // MARK: - 探测:前缀判定(API_CONTRACT.md 1.4)

    func testProbePrefersEmbyPrefix() async throws {
        try stubPublicInfo(path: "/emby/System/Info/Public")
        let result = try await makeConnection(host: "emby.test").probeServer()
        XCTAssertEqual(result.compatibility.apiPathPrefix, "/emby")
        XCTAssertEqual(result.compatibility.serverVersion, "4.7.11.0")
        XCTAssertFalse(result.compatibility.schemeFellBackToHTTP)
        XCTAssertEqual(result.serverID, "00000000-0000-0000-0000-000000000001")
    }

    func testProbeFallsBackToRootPath() async throws {
        // 只有根路径通(反向代理已经把 /emby 剥掉了)
        try stubPublicInfo(path: "/System/Info/Public")
        let result = try await makeConnection(host: "emby.test").probeServer()
        XCTAssertEqual(result.compatibility.apiPathPrefix, "")
    }

    func testProbeThrowsWhenNoPathResponds() async throws {
        do {
            _ = try await makeConnection(host: "emby.test").probeServer()
            XCTFail("两条前缀都不通时应抛 unreachable")
        } catch let error as ServerLoginError {
            guard case .unreachable(let host) = error else {
                return XCTFail("期望 .unreachable,实际 \(error)")
            }
            XCTAssertEqual(host, "emby.test")
        }
    }

    func testProbeTriesBothPrefixesBeforeGivingUp() async throws {
        _ = try? await makeConnection(host: "emby.test").probeServer()
        let paths = MockEmbyURLProtocol.recordedRequests().map(\.url.path)
        XCTAssertEqual(paths, ["/emby/System/Info/Public", "/System/Info/Public"])
    }

    // MARK: - 探测:局域网 http 回退(API_CONTRACT.md 1.4)

    func testProbeFallsBackToHTTPForPrivateHost() async throws {
        try stubPublicInfo(scheme: "http", host: "192.168.1.10", path: "/emby/System/Info/Public")
        let connection = makeConnection(host: "192.168.1.10", port: 8096, schemeWasInferred: true)
        let result = try await connection.probeServer()
        XCTAssertEqual(result.baseURL.absoluteString, "http://192.168.1.10:8096")
        XCTAssertTrue(result.compatibility.schemeFellBackToHTTP)
    }

    func testProbeDoesNotDowngradeExplicitHTTPS() async throws {
        // 用户明确写了 https:// —— 即使是局域网也不得降级(1.4 的禁止项)
        try stubPublicInfo(scheme: "http", host: "192.168.1.10", path: "/emby/System/Info/Public")
        let connection = makeConnection(host: "192.168.1.10", port: 8096, schemeWasInferred: false)
        do {
            _ = try await connection.probeServer()
            XCTFail("明确写 https 时不得回退到 http")
        } catch let error as ServerLoginError {
            guard case .unreachable = error else { return XCTFail("期望 .unreachable,实际 \(error)") }
        }
        let schemes = Set(MockEmbyURLProtocol.recordedRequests().compactMap(\.url.scheme))
        XCTAssertEqual(schemes, ["https"], "一次 http 请求都不该发出去")
    }

    func testProbeDoesNotFallbackForPublicHost() async throws {
        // 公网 host 即使没写 scheme 也不做 http 回退(1.4 的禁止项)
        try stubPublicInfo(scheme: "http", host: "emby.test", path: "/emby/System/Info/Public")
        let connection = makeConnection(host: "emby.test", schemeWasInferred: true)
        do {
            _ = try await connection.probeServer()
            XCTFail("公网 host 不得回退到 http")
        } catch let error as ServerLoginError {
            guard case .unreachable = error else { return XCTFail("期望 .unreachable,实际 \(error)") }
        }
    }

    func testFallbackResultIsPersistedAsHTTP() async throws {
        // 1.4:baseURL 存**回退后**的 http,不要存原来的 https
        try stubPublicInfo(scheme: "http", host: "192.168.1.10", path: "/emby/System/Info/Public")
        try stubAuth(scheme: "http", host: "192.168.1.10")
        try stubViews(scheme: "http", host: "192.168.1.10")
        let connection = makeConnection(host: "192.168.1.10", port: 8096, schemeWasInferred: true)
        let result = try await connection.login(username: "alice", password: "secret")
        XCTAssertEqual(result.profile.baseURL.scheme, "http")
        XCTAssertTrue(result.compatibility.schemeFellBackToHTTP)
    }

    // MARK: - 登录

    func testLoginSavesTokenAndFillsProfile() async throws {
        try stubHappyPath()
        let connection = makeConnection(host: "emby.test")

        let result = try await connection.login(username: "alice", password: "secret")

        XCTAssertEqual(result.profile.apiPathPrefix, "/emby")
        XCTAssertEqual(result.profile.userID, fixtureUserID)
        XCTAssertEqual(result.profile.username, "alice")
        XCTAssertEqual(result.profile.serverVersion, "4.7.11.0")
        XCTAssertEqual(result.profile.serverID, "00000000-0000-0000-0000-000000000002")
        XCTAssertNotNil(result.profile.compatibility)

        let saved = try await credentials.token(forServer: result.profile.id)
        XCTAssertEqual(saved, "FAKE_TOKEN_0123456789")
    }

    func testLoginSendsCredentialsInBody() async throws {
        try stubHappyPath()
        _ = try await makeConnection(host: "emby.test").login(username: "alice", password: "secret")

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "AuthenticateByName")
        )
        let body = try XCTUnwrap(request.body)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object["Username"], "alice")
        XCTAssertEqual(object["Pw"], "secret")
        // 登录请求本身没有 UserId(此时还不知道,API_CONTRACT.md 2.1)
        XCTAssertFalse(request.header("Authorization")?.contains("UserId") == true)
    }

    func testLoginValidatesAccessWithAuthenticatedRequest() async throws {
        try stubHappyPath()
        _ = try await makeConnection(host: "emby.test").login(username: "alice", password: "secret")

        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/Views"))
        // 验证请求必须带 token 与 UserId(后续所有鉴权请求都靠这一套头)
        XCTAssertEqual(request.header("X-Emby-Token"), "FAKE_TOKEN_0123456789")
        XCTAssertTrue(request.header("Authorization")?.contains("UserId=\"\(fixtureUserID)\"") == true)
    }

    func testLogin401IsInvalidCredentialsAndStoresNothing() async throws {
        // 登录请求本身的 401 = 密码错,**不是**「token 失效」
        try stubPublicInfo(path: "/emby/System/Info/Public")
        MockEmbyURLProtocol.stub(.status(401), path: "/emby/Users/AuthenticateByName")
        let profile = makeProfile(host: "emby.test")

        do {
            _ = try await makeConnection(profile: profile).login(username: "alice", password: "wrong")
            XCTFail("401 应抛 invalidCredentials")
        } catch let error as ServerLoginError {
            XCTAssertEqual(error, .invalidCredentials)
        }

        let token = try await credentials.token(forServer: profile.id)
        XCTAssertNil(token, "登录失败不得留下 token")
    }

    func testAccessDeniedRollsBackToken() async throws {
        // 登录成功但读不到媒体库:这次登录没成功,不该留下孤立凭证
        try stubPublicInfo(path: "/emby/System/Info/Public")
        try stubAuth()
        MockEmbyURLProtocol.stub(.status(403), path: "/emby/Users/\(fixtureUserID)/Views")
        let profile = makeProfile(host: "emby.test")

        do {
            _ = try await makeConnection(profile: profile).login(username: "alice", password: "secret")
            XCTFail("鉴权请求 403 应抛 accessDenied")
        } catch let error as ServerLoginError {
            guard case .accessDenied(let underlying) = error else {
                return XCTFail("期望 .accessDenied,实际 \(error)")
            }
            XCTAssertEqual(underlying, .forbidden)
        }

        let token = try await credentials.token(forServer: profile.id)
        XCTAssertNil(token)
    }

    // MARK: - 401 只影响这一台(API_CONTRACT.md 2.5)

    func testUnauthorizedClearsOnlyThatServersToken() async throws {
        let (connectionA, profileA, profileB) = try await loginTwoServers()

        // A 的 token 突然失效
        MockEmbyURLProtocol.stub(.status(401), host: "a.test", path: "/emby/Users/USER-A/Views")
        do {
            _ = try await connectionA.userViews()
            XCTFail("401 应抛 unauthorized")
        } catch let error as EmbyAPIError {
            XCTAssertEqual(error, .unauthorized)
        }

        let tokenA = try await credentials.token(forServer: profileA.id)
        XCTAssertNil(tokenA, "401 必须清掉**这台**服务器的 token")
        let tokenB = try await credentials.token(forServer: profileB.id)
        XCTAssertEqual(tokenB, "FAKE_TOKEN_B", "另一台不得受影响")
    }

    func testUnauthorizedDoesNotRetryOrRelogin() async throws {
        let (connectionA, _, _) = try await loginTwoServers()
        MockEmbyURLProtocol.stub(.status(401), host: "a.test", path: "/emby/Users/USER-A/Views")

        let viewsBefore = viewRequests(host: "a.test").count
        let authBefore = authRequests(host: "a.test").count
        _ = try? await connectionA.userViews()

        // 密码不存 = 没有重新拿 token 的办法:重试只会再 401(API_CONTRACT.md 2.5)
        XCTAssertEqual(viewRequests(host: "a.test").count - viewsBefore, 1)
        XCTAssertEqual(authRequests(host: "a.test").count - authBefore, 0, "不得静默重新登录")
    }

    // MARK: - 密码不落盘(docs/DECISIONS/credentials-file-storage.md)

    func testLoginDoesNotPersistPassword() async throws {
        try stubHappyPath()
        _ = try await makeConnection(host: "emby.test").login(username: "alice", password: "secret")

        let raw = try String(decoding: Data(contentsOf: credentialsFile), as: UTF8.self)
        XCTAssertTrue(raw.contains(Data("FAKE_TOKEN_0123456789".utf8).base64EncodedString()), "token 应已落盘")
        XCTAssertFalse(raw.contains("secret"))
        XCTAssertFalse(raw.contains(Data("secret".utf8).base64EncodedString()), "密码不得以任何形式落盘")
    }

    func testMissingTokenRequiresManualLogin() async throws {
        try stubHappyPath()
        let loginConnection = makeConnection(host: "emby.test")
        let profile = try await loginConnection.login(username: "alice", password: "secret").profile
        try await credentials.deleteToken(forServer: profile.id)

        // 新实例 = 重启 App 后的状态:本地没有 token
        let restored = makeConnection(profile: profile)
        let hasToken = try await restored.hasStoredToken()
        XCTAssertFalse(hasToken)
        let authBefore = authRequests(host: "emby.test").count
        do {
            _ = try await restored.userViews()
            XCTFail("没有 token 应抛 unauthorized,让 UI 回登录页")
        } catch let error as EmbyAPIError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertEqual(authRequests(host: "emby.test").count - authBefore, 0)
    }

    func testLate401DoesNotDeleteNewerToken() async throws {
        try stubHappyPath()
        let connection = makeConnection(host: "emby.test")
        let profile = try await connection.login(username: "alice", password: "secret").profile
        // 另一个连接实例(重新登录面板)已经存好了新 token,这个实例手上还是旧的
        try await credentials.saveToken("FAKE_TOKEN_FROM_LOGIN_SHEET", forServer: profile.id)
        MockEmbyURLProtocol.stub(.status(401), path: "/emby/Users/\(fixtureUserID)/Views")

        _ = try? await connection.userViews()

        let token = try await credentials.token(forServer: profile.id)
        XCTAssertEqual(token, "FAKE_TOKEN_FROM_LOGIN_SHEET", "旧 token 的 401 不得删掉别处刚存的新 token")
    }

    // MARK: - 登出

    func testLogoutClearsLocalTokenDespiteRemoteFailure() async throws {
        try stubHappyPath()
        let profile = makeProfile(host: "emby.test")
        let connection = makeConnection(profile: profile)
        _ = try await connection.login(username: "alice", password: "secret")
        // 远程吊销失败(500)也必须清本地 token
        MockEmbyURLProtocol.stub(.status(500), path: "/emby/Sessions/Logout")

        try await connection.logout()

        let token = try await credentials.token(forServer: profile.id)
        XCTAssertNil(token)
    }

    func testHasStoredTokenReflectsStorage() async throws {
        try stubHappyPath()
        let profile = makeProfile(host: "emby.test")
        let connection = makeConnection(profile: profile)
        let beforeLogin = try await connection.hasStoredToken()
        XCTAssertFalse(beforeLogin)

        _ = try await connection.login(username: "alice", password: "secret")
        let afterLogin = try await connection.hasStoredToken()
        XCTAssertTrue(afterLogin)

        try await connection.logout()
        let afterLogout = try await connection.hasStoredToken()
        XCTAssertFalse(afterLogout)
    }

    // MARK: - 接口响应缓存

    func testCachedViewsSecondCallMakesNoRequest() async throws {
        try stubHappyPath()
        let connection = makeCachedConnection(profile: makeProfile(host: "emby.test"))
        _ = try await connection.login(username: "alice", password: "secret")

        // login 的验证请求之后整台作废,先再取一次制造缓存
        _ = try await connection.userViews()
        let before = viewRequests(host: "emby.test").count

        let views = try await connection.userViews()

        XCTAssertEqual(viewRequests(host: "emby.test").count, before, "fresh 命中必须零网络请求")
        XCTAssertEqual(views.count, 3, "缓存命中返回的数据与网络路径一致")
    }

    func testSetPlayedInvalidatesCache() async throws {
        try stubHappyPath()
        let connection = makeCachedConnection(profile: makeProfile(host: "emby.test"))
        _ = try await connection.login(username: "alice", password: "secret")
        _ = try await connection.userViews()

        MockEmbyURLProtocol.stub(
            .json(#"{"Played":true,"PlayCount":1}"#),
            path: "/emby/Users/\(fixtureUserID)/PlayedItems/ITEM-1"
        )
        _ = try await connection.setPlayed(itemID: "ITEM-1", played: true)

        let before = viewRequests(host: "emby.test").count
        _ = try await connection.userViews()

        XCTAssertEqual(viewRequests(host: "emby.test").count - before, 1, "写操作后缓存必须作废,重新走网络")
    }

    func testProgressReportDoesNotInvalidateButPlayingDoes() async throws {
        try stubHappyPath()
        let connection = makeCachedConnection(profile: makeProfile(host: "emby.test"))
        _ = try await connection.login(username: "alice", password: "secret")
        _ = try await connection.userViews()

        // Progress tick(每 10 秒一次):不得失效,否则播放期间永远打不到缓存
        MockEmbyURLProtocol.stub(.status(200), path: "/emby/Sessions/Playing/Progress")
        try await connection.reportPlayback(
            .sessionsPlayingProgress(makeReportBody(eventName: "timeupdate"))
        )
        var before = viewRequests(host: "emby.test").count
        _ = try await connection.userViews()
        XCTAssertEqual(viewRequests(host: "emby.test").count, before, "Progress tick 不得让缓存失效")

        // Playing 上报:播放位置与续播列表变了,必须失效
        MockEmbyURLProtocol.stub(.status(200), path: "/emby/Sessions/Playing")
        try await connection.reportPlayback(.sessionsPlaying(makeReportBody(eventName: nil)))
        before = viewRequests(host: "emby.test").count
        _ = try await connection.userViews()
        XCTAssertEqual(viewRequests(host: "emby.test").count - before, 1, "Playing 上报后缓存必须作废")
    }

    func testLoginVerificationBypassesCache() async throws {
        try stubHappyPath()
        let profile = makeProfile(host: "emby.test")
        let first = makeCachedConnection(profile: profile)
        _ = try await first.login(username: "alice", password: "secret")
        // 制造一份 Views 缓存:如果 login 验证吃缓存,下面的登录会假装成功
        _ = try await first.userViews()

        // 服务端开始拒绝这台:Views 全部 401(密码没错,是访问权没了)
        MockEmbyURLProtocol.stub(.status(401), path: "/emby/Users/\(fixtureUserID)/Views")

        do {
            _ = try await makeCachedConnection(profile: profile).login(username: "alice", password: "secret")
            XCTFail("验证请求 401 时登录必须失败,缓存不得掩盖")
        } catch let error as ServerLoginError {
            guard case .accessDenied = error else {
                return XCTFail("期望 .accessDenied,实际 \(error)")
            }
        }
        let token = try await credentials.token(forServer: profile.id)
        XCTAssertNil(token, "失败的登录不得留下 token")
    }

    // MARK: - 媒体库入口

    func testUserViewsDecodesCollectionTypes() async throws {
        try stubHappyPath()
        let connection = makeConnection(host: "emby.test")
        _ = try await connection.login(username: "alice", password: "secret")

        let views = try await connection.userViews()
        XCTAssertEqual(views.count, 3)
        XCTAssertEqual(views[0].collectionType, "movies")
        // CollectionType 为 null 的混合媒体库:不得崩溃、不得当必填(3.2)
        XCTAssertNil(views[2].collectionType)
        XCTAssertEqual(views[2].name, "混合媒体库")
    }

    func testUserViewsWithoutTokenThrowsUnauthorized() async throws {
        let connection = makeConnection(host: "emby.test")
        do {
            _ = try await connection.userViews()
            XCTFail("没有 token 时应抛 unauthorized")
        } catch let error as EmbyAPIError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    // MARK: - 辅助

    /// 带响应缓存的连接(缓存集成测试用;目录每个测试一份,互不串)。
    private func makeCachedConnection(profile: ServerProfile) -> ServerConnection {
        ServerConnection(
            profile: profile,
            credentials: credentials,
            schemeWasInferred: false,
            session: session,
            responseCache: responseCache
        )
    }

    /// 播放上报的请求体(字段值对失效测试无关紧要,合法即可)。
    private func makeReportBody(eventName: String?) -> PlaybackReportBody {
        PlaybackReportBody(
            itemID: "ITEM-1",
            mediaSourceID: "ITEM-1",
            playSessionID: "SESSION-1",
            playMethod: "DirectStream",
            positionTicks: 1_000,
            isPaused: false,
            isMuted: false,
            volumeLevel: 100,
            canSeek: true,
            audioStreamIndex: nil,
            subtitleStreamIndex: nil,
            eventName: eventName
        )
    }

    private func makeProfile(host: String, port: Int? = nil) -> ServerProfile {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        if let port { components.port = port }
        return ServerProfile(
            displayName: host,
            baseURL: components.url ?? URL(fileURLWithPath: "/"),
            deviceID: "DEVICE-UUID-1"
        )
    }

    private func makeConnection(
        host: String,
        port: Int? = nil,
        schemeWasInferred: Bool = false
    ) -> ServerConnection {
        makeConnection(profile: makeProfile(host: host, port: port), schemeWasInferred: schemeWasInferred)
    }

    private func makeConnection(
        profile: ServerProfile,
        schemeWasInferred: Bool = false
    ) -> ServerConnection {
        ServerConnection(
            profile: profile,
            credentials: credentials,
            schemeWasInferred: schemeWasInferred,
            session: session
        )
    }

    /// 一条龙:公开信息 + 登录 + Views,全部 200。
    private func stubHappyPath(
        scheme: String = "https",
        host: String = "emby.test"
    ) throws {
        try stubPublicInfo(scheme: scheme, host: host, path: "/emby/System/Info/Public")
        try stubAuth(scheme: scheme, host: host)
        try stubViews(scheme: scheme, host: host)
    }

    private func stubPublicInfo(
        scheme: String = "https",
        host: String = "emby.test",
        path: String
    ) throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("public_info.json")),
            scheme: scheme,
            host: host,
            path: path
        )
    }

    private func stubAuth(scheme: String = "https", host: String = "emby.test") throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("authenticate_success_synthetic.json")),
            scheme: scheme,
            host: host,
            path: "/emby/Users/AuthenticateByName"
        )
    }

    private func stubViews(
        scheme: String = "https",
        host: String = "emby.test",
        userID: String = fixtureUserID
    ) throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("user_views_mixed_synthetic.json")),
            scheme: scheme,
            host: host,
            path: "/emby/Users/\(userID)/Views"
        )
    }

    private func authRequests(host: String) -> [MockEmbyURLProtocol.RecordedRequest] {
        MockEmbyURLProtocol.recordedRequests().filter {
            $0.url.host() == host && $0.url.path.hasSuffix("/AuthenticateByName")
        }
    }

    private func viewRequests(host: String) -> [MockEmbyURLProtocol.RecordedRequest] {
        MockEmbyURLProtocol.recordedRequests().filter {
            $0.url.host() == host && $0.url.path.hasSuffix("/Views")
        }
    }

    /// 登录 a.test 与 b.test 两台(各自独立 token),返回 A 的连接与两台的档案。
    private func loginTwoServers() async throws -> (ServerConnection, ServerProfile, ServerProfile) {
        let profileA = makeProfile(host: "a.test")
        let profileB = makeProfile(host: "b.test")

        try stubPublicInfo(host: "a.test", path: "/emby/System/Info/Public")
        try stubPublicInfo(host: "b.test", path: "/emby/System/Info/Public")
        MockEmbyURLProtocol.stub(
            .json(#"{"AccessToken":"FAKE_TOKEN_A","User":{"Id":"USER-A"}}"#),
            host: "a.test",
            path: "/emby/Users/AuthenticateByName"
        )
        MockEmbyURLProtocol.stub(
            .json(#"{"AccessToken":"FAKE_TOKEN_B","User":{"Id":"USER-B"}}"#),
            host: "b.test",
            path: "/emby/Users/AuthenticateByName"
        )
        try stubViews(host: "a.test", userID: "USER-A")
        try stubViews(host: "b.test", userID: "USER-B")

        let connectionA = makeConnection(profile: profileA)
        _ = try await connectionA.login(username: "alice", password: "secret")
        _ = try await makeConnection(profile: profileB).login(username: "bob", password: "secret")

        let tokenA = try await credentials.token(forServer: profileA.id)
        let tokenB = try await credentials.token(forServer: profileB.id)
        XCTAssertEqual(tokenA, "FAKE_TOKEN_A")
        XCTAssertEqual(tokenB, "FAKE_TOKEN_B")
        return (connectionA, profileA, profileB)
    }
}
