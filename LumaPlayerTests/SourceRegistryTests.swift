import XCTest
@testable import LumaPlayer

/// 来源注册表的来源泛化部分:旧 Emby 数据迁移、多来源共存、非 Emby 来源的增删改查。Emby 侧行为见 `ServerRegistryTests`。
final class SourceRegistryTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() {
        super.setUp()
        suiteName = "test.LumaPlayer.sources.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        defaults = nil
        storage = nil
        credentials = nil
        try await super.tearDown()
    }

    private func makeRegistry() throws -> SourceRegistry {
        try SourceRegistry(defaults: UserDefaults(suiteName: suiteName)!, credentials: credentials)
    }

    private func makeEmby(name: String) -> ServerProfile {
        ServerProfile(
            displayName: name,
            baseURL: URL(string: "https://\(name).example.com")!,
            deviceID: "shared-device"
        )
    }

    private func makeBaidu(name: String = "百度网盘", folder: String = "LumaPlayer") -> BaiduPanSource {
        BaiduPanSource(displayName: name, folderName: folder)
    }

    // MARK: - 迁移

    /// 旧格式存的是 `[ServerProfile]`,必须读成 `.emby(_)`;⛔ 不能因为换了 key / 类型就静默丢服务器。
    func testLegacyEmbyStorageMigratesToEmbySources() async throws {
        let a = makeEmby(name: "alpha")
        let b = makeEmby(name: "beta")
        let legacy = try JSONEncoder().encode([a, b])
        defaults.set(legacy, forKey: SourceRegistry.legacyEmbyStorageKey)

        let registry = try makeRegistry()

        let emby = await registry.all()
        XCTAssertEqual(Set(emby.map(\.id)), [a.id, b.id])
        let sources = await registry.allSources()
        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources.allSatisfy {
            if case .emby = $0 { return true }
            return false
        })
    }

    /// 迁移只发生一次。
    func testNewFormatTakesPrecedenceOverLegacy() async throws {
        let legacyOnly = makeEmby(name: "old")
        let newOnly = makeEmby(name: "new")
        defaults.set(try JSONEncoder().encode([legacyOnly]), forKey: SourceRegistry.legacyEmbyStorageKey)
        // UserDefaults 非 Sendable:按 suite 名重新构造(同名单例,实例相同)再传
        let seeded = SourceRegistry(
            profiles: [newOnly],
            defaults: UserDefaults(suiteName: suiteName)!,
            credentials: credentials
        )
        try await seeded.add(SourceProfile.baiduPan(makeBaidu()))

        let registry = try makeRegistry()
        let ids = Set(await registry.all().map(\.id))
        XCTAssertEqual(ids, [newOnly.id])
    }

    // MARK: - 多来源共存

    func testBaiduSourceCoexistsWithEmby() async throws {
        let registry = try makeRegistry()
        let emby = makeEmby(name: "alpha")
        let baidu = makeBaidu()
        try await registry.add(emby)
        try await registry.add(SourceProfile.baiduPan(baidu))

        // Emby 便利入口只看到 Emby;通用入口看到两个
        let embyOnly = await registry.all().map(\.id)
        XCTAssertEqual(embyOnly, [emby.id])
        let allIDs = Set(await registry.allSources().map(\.id))
        XCTAssertEqual(allIDs, [emby.id, baidu.id])
    }

    func testBaiduSourceSurvivesRestart() async throws {
        let registry = try makeRegistry()
        let baidu = makeBaidu(folder: "MyApp")
        try await registry.add(SourceProfile.baiduPan(baidu))

        let restarted = try makeRegistry()
        let loaded = await restarted.allSources().first { $0.id == baidu.id }
        guard case .baiduPan(let source)? = loaded else {
            return XCTFail("重启后应读回 .baiduPan 来源,实际:\(String(describing: loaded))")
        }
        XCTAssertEqual(source.folderName, "MyApp")
        XCTAssertEqual(source.displayName, "百度网盘")
    }

    func testMostRecentlyUsedSourceAcrossKinds() async throws {
        let registry = try makeRegistry()
        let emby = makeEmby(name: "alpha")
        let baidu = makeBaidu()
        try await registry.add(emby)
        try await registry.add(SourceProfile.baiduPan(baidu))

        try await registry.markUsed(id: baidu.id, at: Date(timeIntervalSince1970: 200))
        var recent = await registry.mostRecentlyUsedSource()
        XCTAssertEqual(recent?.id, baidu.id)

        try await registry.markUsed(id: emby.id, at: Date(timeIntervalSince1970: 300))
        recent = await registry.mostRecentlyUsedSource()
        XCTAssertEqual(recent?.id, emby.id)
    }

    func testAddDuplicateBaiduIDThrows() async throws {
        let registry = try makeRegistry()
        var baidu = makeBaidu()
        try await registry.add(SourceProfile.baiduPan(baidu))
        baidu.folderName = "clone"
        do {
            try await registry.add(SourceProfile.baiduPan(baidu))
            XCTFail("重复 id 的 add 应抛 duplicateServer")
        } catch let error as ServerRegistryError {
            XCTAssertEqual(error, .duplicateServer(baidu.id))
        }
    }

    /// 更新百度来源时 `lastUsedAt` 仍归注册表独占(与 Emby 同一条)。
    func testUpdateKeepsRegistryOwnedLastUsedForBaidu() async throws {
        let registry = try makeRegistry()
        let baidu = makeBaidu()
        try await registry.add(SourceProfile.baiduPan(baidu))
        try await registry.markUsed(id: baidu.id, at: Date(timeIntervalSince1970: 500))

        var stale = baidu                 // 快照:lastUsedAt 仍是 nil
        stale.displayName = "改过名"
        try await registry.update(SourceProfile.baiduPan(stale))

        let loaded = await registry.allSources().first { $0.id == baidu.id }
        XCTAssertEqual(loaded?.displayName, "改过名")
        XCTAssertEqual(loaded?.lastUsedAt, Date(timeIntervalSince1970: 500))
    }

    func testRemoveDeletesBaiduCredentials() async throws {
        let registry = try makeRegistry()
        let baidu = makeBaidu()
        try await registry.add(SourceProfile.baiduPan(baidu))
        try await credentials.saveToken("BAIDU-TOKEN", forServer: baidu.id)

        try await registry.remove(id: baidu.id)

        let remaining = await registry.allSources()
        XCTAssertTrue(remaining.isEmpty)
        let token = try await credentials.token(forServer: baidu.id)
        XCTAssertNil(token)
    }
}
