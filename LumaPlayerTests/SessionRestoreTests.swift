import XCTest
@testable import LumaPlayer

/// 启动会话恢复。「重启」= 从同一 defaults / 凭据文件重建 registry + AppContainer。
///
/// 并发:`UserDefaults`(non-Sendable)从存储属性或其局部拷贝发给 `ServerRegistry.init` 都会触发数据竞争诊断,
/// 所以方法内按同名 suite 重新构造(同名返回同一实例,语义等价)。AppContainer 交互放进
/// `Task { @MainActor in }`,闭包只捕获 Sendable 值、不捕获 self。
final class SessionRestoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var credentialsFile: URL!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() {
        super.setUp()
        suiteName = "test.LumaPlayer.session.\(UUID().uuidString)"
        // suiteName 为随机 UUID,实际不会为 nil
        defaults = UserDefaults(suiteName: suiteName)!
        credentialsFile = .temporaryCredentialsFile()
        storage = CredentialFileStore(fileURL: credentialsFile)
        credentials = CredentialStore(storage: storage)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        defaults = nil
        credentialsFile = nil
        storage = nil
        credentials = nil
        try await super.tearDown()
    }

    private func makeProfile(name: String, deviceID: String = "shared-device") -> ServerProfile {
        ServerProfile(
            displayName: name,
            baseURL: URL(string: "https://\(name).example.com")!,
            deviceID: deviceID
        )
    }

    /// 在 MainActor 上构造 AppContainer、触发恢复并断言最终状态。
    private func assertRestoredSession(
        registry: ServerRegistry,
        credentials: CredentialStore,
        expectedServerID: UUID?,
        expectedRoute: AppRoute
    ) async {
        await Task { @MainActor in
            let container = AppContainer(registry: registry, credentials: credentials)
            await container.restoreSession()
            XCTAssertEqual(container.state.currentServer?.id, expectedServerID)
            XCTAssertEqual(container.state.route, expectedRoute)
        }.value
    }

    func testRestorePicksMostRecentlyUsedServer() async throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        let firstBoot = try ServerRegistry(defaults: defaults, credentials: credentials)
        let a = makeProfile(name: "alpha")
        let b = makeProfile(name: "beta")
        try await firstBoot.add(a)
        try await firstBoot.add(b)
        try await firstBoot.markUsed(id: a.id, at: Date(timeIntervalSince1970: 300))
        try await firstBoot.markUsed(id: b.id, at: Date(timeIntervalSince1970: 100))

        // 模拟重启:全新 registry + AppContainer,再触发恢复
        await assertRestoredSession(
            registry: try ServerRegistry(defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials),
            credentials: credentials,
            expectedServerID: a.id,
            expectedRoute: .browse
        )
    }

    func testRestoreWithoutServersShowsOnboarding() async throws {
        await assertRestoredSession(
            registry: try ServerRegistry(defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials),
            credentials: credentials,
            expectedServerID: nil,
            expectedRoute: .onboarding
        )
    }

    func testEditingAfterSwitchDoesNotChangeRestoreTarget() async throws {
        // 用切换前的旧快照编辑 alpha,不得把 lastUsedAt 回退到切换之前(否则重启恢复成 beta)
        let defaults = UserDefaults(suiteName: suiteName)!
        let firstBoot = try ServerRegistry(defaults: defaults, credentials: credentials)
        let a = makeProfile(name: "alpha")
        let b = makeProfile(name: "beta")
        try await firstBoot.add(a)
        try await firstBoot.add(b)
        try await firstBoot.markUsed(id: b.id, at: Date(timeIntervalSince1970: 100))

        let session = try ServerRegistry(defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials)
        let credentials = try XCTUnwrap(self.credentials)
        try await Task { @MainActor in
            let container = AppContainer(registry: session, credentials: credentials)
            await container.restoreSession()
            try await container.switchCurrent(to: a)
            var staleEdit = a               // 列表视图里的旧快照:lastUsedAt 仍是 nil
            staleEdit.displayName = "renamed"
            try await container.updateServer(staleEdit)
            XCTAssertNotNil(container.state.currentServer?.lastUsedAt)
        }.value

        let restarted = try ServerRegistry(defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials)
        let recent = await restarted.mostRecentlyUsed()
        XCTAssertEqual(recent?.id, a.id)
        XCTAssertEqual(recent?.displayName, "renamed")
    }

    func testRestoreRunsOnlyOnce() async throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        let firstBoot = try ServerRegistry(defaults: defaults, credentials: credentials)
        let a = makeProfile(name: "alpha")
        let b = makeProfile(name: "beta")
        try await firstBoot.add(a)
        try await firstBoot.add(b)
        try await firstBoot.markUsed(id: a.id, at: Date(timeIntervalSince1970: 300))

        // 模拟重启
        let restarted = try ServerRegistry(defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials)
        let credentials = try XCTUnwrap(self.credentials)

        // 恢复后用户手动切到 beta;再触发一次恢复不应覆盖用户操作
        try await Task { @MainActor in
            let container = AppContainer(registry: restarted, credentials: credentials)
            await container.restoreSession()
            XCTAssertEqual(container.state.currentServer?.id, a.id)

            try await container.switchCurrent(to: b)
            await container.restoreSession()
            XCTAssertEqual(container.state.currentServer?.id, b.id)
        }.value
    }
}
