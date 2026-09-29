import XCTest
@testable import LumaPlayer

/// 启动会话恢复:
/// 「重新启动后自动恢复最近一次可用会话」(ARCHITECTURE.md 4.1)。
/// 「重启」= 从同一 defaults / 凭据文件重建 registry + AppContainer。
///
/// 并发说明:UserDefaults(non-Sendable)不能从测试方法的隔离区域发送给
/// ServerRegistry 的 init —— 无论直接用 `self.defaults` 存储还是先拷贝成
/// 局部常量,region 都与存储共享,会触发数据竞争诊断(提取成 helper 也一样)。
/// UserDefaults(suiteName:) 对同名 suite 返回同一实例,因此在方法内重新
/// 构造局部实例,语义与 setUp 建的完全等价,且作为新构造值可跨隔离传递。
/// AppContainer 是 @MainActor,相关交互统一放进 `Task { @MainActor in }`,
/// 闭包只捕获 Sendable 值,不捕获 self。
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

    /// 恢复会话并断言最终状态。在 MainActor 上构造 AppContainer 并触发恢复;
    /// 参数全部 Sendable,Task 闭包不捕获 self。
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
        // 同名 suite 返回同一 UserDefaults 实例(单例语义),等价于 self.defaults;
        // 每处构造都用独立的新构造值,发送后不再复用(region 可转移)
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
            expectedRoute: .serverList
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
        // 回归:切到 alpha 后,用切换前的旧快照编辑 alpha,
        // 不得把它的 lastUsedAt 回退到切换之前(否则重启恢复成 beta)
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

        // 模拟重启:独立构造的 defaults 与局部凭据,
        // Task 闭包内只捕获 Sendable 值、不捕获 self
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
