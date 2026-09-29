import XCTest
@testable import LumaPlayer

/// ServerRegistry 的增删改查、持久化「重启」与凭据联动
/// (ARCHITECTURE.md 10.1)。
/// UserDefaults 用独立 suite、凭据用临时文件,测试后清理。
final class ServerRegistryTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var credentialsFile: URL!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var registry: ServerRegistry!

    override func setUp() {
        super.setUp()
        suiteName = "test.LumaPlayer.registry.\(UUID().uuidString)"
        // suiteName 为随机 UUID,实际不会为 nil
        defaults = UserDefaults(suiteName: suiteName)!
        credentialsFile = .temporaryCredentialsFile()
        storage = CredentialFileStore(fileURL: credentialsFile)
        credentials = CredentialStore(storage: storage)
        do {
            // UserDefaults(non-Sendable)不能从存储读取后跨隔离发送,
            // 这里按 suite 名重新构造(同名单例,实例相同),作为新构造值传递
            registry = try ServerRegistry(defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials)
        } catch {
            XCTFail("全新临时 suite 不应损坏:\(error)")
            registry = ServerRegistry(profiles: [], defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials)
        }
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        defaults = nil
        credentialsFile = nil
        storage = nil
        credentials = nil
        registry = nil
        try await super.tearDown()
    }

    /// 测试辅助:构造合法 profile
    private func makeProfile(name: String, deviceID: String = "shared-device") -> ServerProfile {
        ServerProfile(
            displayName: name,
            baseURL: URL(string: "https://\(name).example.com")!,
            deviceID: deviceID
        )
    }

    // MARK: - 持久化(「重启」= 从同一 defaults 重建 registry)

    func testProfilesSurviveRestart() async throws {
        let a = makeProfile(name: "alpha")
        let b = makeProfile(name: "beta")
        try await registry.add(a)
        try await registry.add(b)

        let restarted = try ServerRegistry(defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials)
        let ids = Set(await restarted.all().map(\.id))
        XCTAssertEqual(ids, [a.id, b.id])
    }

    func testCorruptedStorageThrows() async throws {
        defaults.set(Data("not-json".utf8), forKey: ServerRegistry.storageKey)
        XCTAssertThrowsError(try ServerRegistry(defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials)) { error in
            XCTAssertEqual(error as? ServerRegistryError, .storageCorrupted)
        }
    }

    // MARK: - 删除与凭据联动

    func testRemovingOneServerKeepsTheOther() async throws {
        let a = makeProfile(name: "alpha")
        let b = makeProfile(name: "beta")
        try await registry.add(a)
        try await registry.add(b)
        try await credentials.saveToken("TOKEN-B", forServer: b.id)

        try await registry.remove(id: a.id)

        let remaining = await registry.all()
        XCTAssertEqual(remaining.map(\.id), [b.id])
        let tokenB = try await credentials.token(forServer: b.id)
        XCTAssertEqual(tokenB, "TOKEN-B")
    }

    func testRemovingServerDeletesItsToken() async throws {
        let a = makeProfile(name: "alpha")
        try await registry.add(a)
        try await credentials.saveToken("TOKEN-A", forServer: a.id)

        try await registry.remove(id: a.id)

        let token = try await credentials.token(forServer: a.id)
        XCTAssertNil(token)
    }

    func testRemoveIsIdempotentForRetry() async throws {
        // 场景:persist 成功但清 token 失败 → 直接重试 remove
        let a = makeProfile(name: "alpha")
        try await registry.add(a)
        try await credentials.saveToken("TOKEN-A", forServer: a.id)
        try await registry.remove(id: a.id)
        try await registry.remove(id: a.id)  // 不抛
        let token = try await credentials.token(forServer: a.id)
        XCTAssertNil(token)
    }

    // MARK: - DeviceId

    func testDeviceIDStableAcrossServerRemoval() async throws {
        let before = try await credentials.deviceID()
        let a = makeProfile(name: "alpha", deviceID: before)
        try await registry.add(a)
        try await registry.remove(id: a.id)
        let after = try await credentials.deviceID()
        XCTAssertEqual(before, after)
    }

    func testDeviceIDSharedAcrossStoreInstances() async throws {
        // 「全 App 唯一」:新的 CredentialStore 实例(同一凭据文件)
        // 读到的仍是同一个 DeviceId
        let first = try await credentials.deviceID()
        let secondCredentials = CredentialStore(storage: CredentialFileStore(fileURL: credentialsFile))
        let second = try await secondCredentials.deviceID()
        XCTAssertEqual(first, second)
    }

    // MARK: - token 不进 UserDefaults

    func testUserDefaultsDumpContainsNoToken() async throws {
        let a = makeProfile(name: "alpha")
        try await registry.add(a)
        try await credentials.saveToken("SECRET-TOKEN-DO-NOT-LEAK", forServer: a.id)

        let dump = defaults.dictionaryRepresentation()
            .map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n")
        // dump 确实包含 profiles 键(证明断言的不是空 dump)
        XCTAssertTrue(dump.contains(ServerRegistry.storageKey))
        XCTAssertFalse(dump.contains("SECRET-TOKEN-DO-NOT-LEAK"))
    }

    // MARK: - 最近使用与增改

    func testMostRecentlyUsed() async throws {
        let a = makeProfile(name: "alpha")
        let b = makeProfile(name: "beta")
        try await registry.add(a)
        try await registry.add(b)

        try await registry.markUsed(id: a.id, at: Date(timeIntervalSince1970: 100))
        try await registry.markUsed(id: b.id, at: Date(timeIntervalSince1970: 200))
        var recent = await registry.mostRecentlyUsed()
        XCTAssertEqual(recent?.id, b.id)

        try await registry.markUsed(id: a.id, at: Date(timeIntervalSince1970: 300))
        recent = await registry.mostRecentlyUsed()
        XCTAssertEqual(recent?.id, a.id)
    }

    func testMarkUsedUnknownThrows() async throws {
        let stranger = makeProfile(name: "stranger")
        do {
            try await registry.markUsed(id: stranger.id, at: Date())
            XCTFail("未知 id 的 markUsed 应抛 notFound")
        } catch let error as ServerRegistryError {
            XCTAssertEqual(error, .notFound(stranger.id))
        }
    }

    func testUpdatePersistsAcrossRestart() async throws {
        let a = makeProfile(name: "alpha")
        try await registry.add(a)

        var edited = a
        edited.displayName = "renamed"
        try await registry.update(edited)

        let restarted = try ServerRegistry(defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials)
        let loaded = await restarted.all().first { $0.id == a.id }
        XCTAssertEqual(loaded?.displayName, "renamed")
    }

    func testUpdateKeepsRegistryOwnedLastUsed() async throws {
        // 回归:update 是合并式的,旧快照不得把 lastUsedAt 写回去
        let a = makeProfile(name: "alpha")
        try await registry.add(a)
        try await registry.markUsed(id: a.id, at: Date(timeIntervalSince1970: 500))

        var stale = a                       // 快照:lastUsedAt 仍是 nil
        stale.displayName = "renamed"
        try await registry.update(stale)

        let loaded = await registry.all().first { $0.id == a.id }
        XCTAssertEqual(loaded?.displayName, "renamed")
        XCTAssertEqual(loaded?.lastUsedAt, Date(timeIntervalSince1970: 500))
    }

    func testUpdateUnknownThrows() async throws {
        let stranger = makeProfile(name: "stranger")
        do {
            try await registry.update(stranger)
            XCTFail("未知 id 的 update 应抛 notFound")
        } catch let error as ServerRegistryError {
            XCTAssertEqual(error, .notFound(stranger.id))
        }
    }

    func testCompatibilitySurvivesRestart() async throws {
        // 探测到的兼容信息随档案一起持久化,供诊断使用
        let a = makeProfile(name: "alpha")
        try await registry.add(a)

        var probed = a
        probed.compatibility = ServerCompatibility(
            serverName: "emby.test",
            serverVersion: "4.9.0.0",
            apiPathPrefix: "/emby",
            schemeFellBackToHTTP: true
        )
        try await registry.update(probed)

        let restarted = try ServerRegistry(defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials)
        let loaded = await restarted.all().first { $0.id == a.id }
        XCTAssertEqual(loaded?.compatibility?.serverVersion, "4.9.0.0")
        XCTAssertEqual(loaded?.compatibility?.apiPathPrefix, "/emby")
        XCTAssertEqual(loaded?.compatibility?.schemeFellBackToHTTP, true)
    }

    func testOldProfileWithoutCompatibilityStillDecodes() async throws {
        // 早期版本存下的档案没有 compatibility 字段:Optional 解码必须放过
        let a = makeProfile(name: "alpha")
        try await registry.add(a)
        let restarted = try ServerRegistry(defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials)
        let loaded = await restarted.all().first { $0.id == a.id }
        XCTAssertNil(loaded?.compatibility)
    }

    func testAddDuplicateIDThrows() async throws {
        let a = makeProfile(name: "alpha")
        try await registry.add(a)

        var copy = a
        copy.displayName = "clone"
        do {
            try await registry.add(copy)
            XCTFail("重复 id 的 add 应抛 duplicateServer")
        } catch let error as ServerRegistryError {
            XCTAssertEqual(error, .duplicateServer(a.id))
        }
    }
}
