import XCTest
@testable import LumaPlayer

/// UserDefaults 在方法内按 suiteName 重建,AppContainer 相关操作放进 `Task { @MainActor in }`,闭包只捕获 Sendable 值。
final class AddServerNamingTests: XCTestCase {
    private var suiteName: String!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
        suiteName = "test.LumaPlayer.naming.\(UUID().uuidString)"
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

    func testBlankNameUsesServerName() async throws {
        try stubServer(publicInfo: #"{"ServerName":"FAKE_SERVER_NAME","Version":"4.7.11.0","Id":"FAKE_ID"}"#)
        let name = try await addServer(displayName: "  ")
        XCTAssertEqual(name, "FAKE_SERVER_NAME")
    }

    func testBlankNameFallsBackToHostWhenServerNameMissing() async throws {
        try stubServer(publicInfo: #"{"Version":"4.7.11.0","Id":"FAKE_ID"}"#)
        let name = try await addServer(displayName: "")
        XCTAssertEqual(name, "emby.test")
    }

    func testUserProvidedNameWins() async throws {
        try stubServer(publicInfo: #"{"ServerName":"FAKE_SERVER_NAME","Version":"4.7.11.0"}"#)
        let name = try await addServer(displayName: "家里")
        XCTAssertEqual(name, "家里")
    }

    // MARK: - 辅助

    private func stubServer(publicInfo: String) throws {
        MockEmbyURLProtocol.stub(.json(publicInfo), path: "/emby/System/Info/Public")
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("authenticate_success_synthetic.json")),
            path: "/emby/Users/AuthenticateByName"
        )
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("user_views_mixed_synthetic.json")),
            path: "/emby/Users/00000000-0000-0000-0000-000000000003/Views"
        )
    }

    /// 走完整的 `AppContainer.addServer`,返回入库后的显示名。
    private func addServer(displayName: String) async throws -> String {
        let suiteName: String = self.suiteName
        let credentials: CredentialStore = self.credentials
        // registry 是 actor(Sendable),在这里建好再交给 MainActor 任务;
        // UserDefaults 作为新构造值直接传进 init,不跨隔离
        let registry = ServerRegistry(
            profiles: [],
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            credentials: credentials
        )
        return try await Task { @MainActor in
            let container = AppContainer(
                registry: registry,
                credentials: credentials,
                session: MockEmbyURLProtocol.makeSession()
            )
            let profile = try await container.addServer(
                address: "https://emby.test",
                displayName: displayName,
                username: "alice",
                password: "secret"
            )
            let stored = await registry.all().first { $0.id == profile.id }
            return try XCTUnwrap(stored).displayName
        }.value
    }
}
