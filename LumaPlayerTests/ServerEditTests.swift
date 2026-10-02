import XCTest
@testable import LumaPlayer

/// 编辑服务器地址:要重新探测(前缀 / http 回退跟着地址走),探测不通不保存,
/// 保存后浏览用的连接要换成新地址 —— 以前缓存的连接一直拿着旧地址,要重启 App 才生效。
///
/// 并发写法同 `AddServerNamingTests`:AppContainer 相关操作放进 `Task { @MainActor in }`,
/// 闭包只捕获 Sendable 值。
final class ServerEditTests: XCTestCase {
    private var suiteName: String!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
        suiteName = "test.LumaPlayer.edit.\(UUID().uuidString)"
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        storage = nil
        credentials = nil
        try await super.tearDown()
    }

    func testNewAddressIsProbedAndBrowsingConnectionIsRebuilt() async throws {
        // 新地址不带 /emby 前缀:探测第二步命中
        MockEmbyURLProtocol.stub(
            .json(#"{"ServerName":"FAKE_SERVER_NAME","Version":"4.9.5.0","Id":"FAKE_SERVER_ID"}"#),
            host: "new.test",
            path: "/System/Info/Public"
        )
        let original = Self.profile()
        let registry = try await makeRegistry(with: original)
        let credentials: CredentialStore = self.credentials

        try await Task { @MainActor in
            let container = AppContainer(
                registry: registry,
                credentials: credentials,
                session: MockEmbyURLProtocol.makeSession()
            )
            let before = container.connection(for: original)
            let beforeURL = await before.currentProfile().baseURL
            XCTAssertEqual(beforeURL, testURL("https://emby.test"))

            try await container.editServer(original, displayName: "新名字", address: "https://new.test/")

            let all = await registry.all()
            let stored = try XCTUnwrap(all.first)
            XCTAssertEqual(stored.displayName, "新名字")
            XCTAssertEqual(stored.baseURL, testURL("https://new.test"))
            XCTAssertEqual(stored.apiPathPrefix, "")
            XCTAssertEqual(stored.serverVersion, "4.9.5.0")
            XCTAssertEqual(stored.compatibility?.apiPathPrefix, "")

            let after = container.connection(for: stored)
            XCTAssertFalse(after === before)
            let afterURL = await after.currentProfile().baseURL
            XCTAssertEqual(afterURL, testURL("https://new.test"))
        }.value
    }

    func testUnreachableAddressIsNotSaved() async throws {
        // down.test 上没有任何 stub:四次探测全部失败
        let original = Self.profile()
        let registry = try await makeRegistry(with: original)
        let credentials: CredentialStore = self.credentials

        try await Task { @MainActor in
            let container = AppContainer(
                registry: registry,
                credentials: credentials,
                session: MockEmbyURLProtocol.makeSession()
            )
            do {
                try await container.editServer(original, displayName: "改了", address: "https://down.test")
                XCTFail("探测不通应当抛错")
            } catch let error as ServerLoginError {
                XCTAssertEqual(error, .unreachable(host: "down.test"))
            }
            let all = await registry.all()
            let stored = try XCTUnwrap(all.first)
            XCTAssertEqual(stored, original)
        }.value
    }

    func testRenameOnlySendsNoRequest() async throws {
        let original = Self.profile()
        let registry = try await makeRegistry(with: original)
        let credentials: CredentialStore = self.credentials

        try await Task { @MainActor in
            let container = AppContainer(
                registry: registry,
                credentials: credentials,
                session: MockEmbyURLProtocol.makeSession()
            )
            let revisionBefore = container.state.serverListRevision
            try await container.editServer(original, displayName: "只改名", address: "https://emby.test")
            // 主窗口的服务器菜单靠修订号重读列表,改名也必须 +1
            XCTAssertEqual(container.state.serverListRevision, revisionBefore + 1)
            let all = await registry.all()
            let stored = try XCTUnwrap(all.first)
            XCTAssertEqual(stored.displayName, "只改名")
            XCTAssertEqual(stored.baseURL, original.baseURL)
            XCTAssertEqual(stored.apiPathPrefix, "/emby")
        }.value
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    /// 不写 scheme 的局域网地址会被补成 https;编辑时同样要允许回退到 http(API_CONTRACT.md 1.4),
    /// 否则存下来的是一个永远连不上的 https 地址。
    func testSchemelessLANAddressFallsBackToHTTP() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"Version":"4.7.11.0","Id":"FAKE_SERVER_ID"}"#),
            scheme: "http",
            host: "192.168.1.20",
            path: "/emby/System/Info/Public"
        )
        let original = Self.profile()
        let registry = try await makeRegistry(with: original)
        let credentials: CredentialStore = self.credentials

        try await Task { @MainActor in
            let container = AppContainer(
                registry: registry,
                credentials: credentials,
                session: MockEmbyURLProtocol.makeSession()
            )
            try await container.editServer(original, displayName: original.displayName, address: "192.168.1.20:8096")
            let all = await registry.all()
            let stored = try XCTUnwrap(all.first)
            XCTAssertEqual(stored.baseURL, testURL("http://192.168.1.20:8096"))
            XCTAssertEqual(stored.apiPathPrefix, "/emby")
            XCTAssertEqual(stored.compatibility?.schemeFellBackToHTTP, true)
        }.value
    }

    // MARK: - 辅助

    private static func profile() -> ServerProfile {
        ServerProfile(
            displayName: "emby.test",
            baseURL: testURL("https://emby.test"),
            apiPathPrefix: "/emby",
            serverID: "FAKE_SERVER_ID",
            userID: "USER-1",
            username: "testuser",
            deviceID: "DEVICE-UUID-1"
        )
    }

    /// registry 是 actor(Sendable),在这里建好再交给 MainActor 任务;
    /// UserDefaults 作为新构造值直接传进 init,不跨隔离(同 `AddServerNamingTests`)
    private func makeRegistry(with profile: ServerProfile) async throws -> ServerRegistry {
        let suiteName: String = self.suiteName
        let credentials: CredentialStore = self.credentials
        return ServerRegistry(
            profiles: [profile],
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            credentials: credentials
        )
    }
}
