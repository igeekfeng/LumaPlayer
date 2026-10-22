import Synchronization
import XCTest
@testable import LumaPlayer

/// 每个用例一个临时文件,tearDown 删除,不碰真实沙盒容器。
final class CredentialFileStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: CredentialFileStore!

    override func setUp() {
        super.setUp()
        fileURL = .temporaryCredentialsFile()
        store = CredentialFileStore(fileURL: fileURL)
    }

    override func tearDown() async throws {
        try await store.removeAll()
        fileURL = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - 键值语义

    func testRoundTrip() async throws {
        try await store.setValue(Data("secret".utf8), forAccount: "account-a")
        let loaded = try await store.value(forAccount: "account-a")
        XCTAssertEqual(loaded, Data("secret".utf8))
    }

    func testMissingValueReturnsNil() async throws {
        let loaded = try await store.value(forAccount: "never-exists")
        XCTAssertNil(loaded)
    }

    func testOverwriteReplacesValue() async throws {
        try await store.setValue(Data("old".utf8), forAccount: "account-a")
        try await store.setValue(Data("new".utf8), forAccount: "account-a")
        let loaded = try await store.value(forAccount: "account-a")
        XCTAssertEqual(loaded, Data("new".utf8))
    }

    func testRemoveValueDeletesIt() async throws {
        try await store.setValue(Data("x".utf8), forAccount: "account-a")
        try await store.removeValue(forAccount: "account-a")
        let loaded = try await store.value(forAccount: "account-a")
        XCTAssertNil(loaded)
    }

    func testRemoveMissingIsIdempotentAndWritesNothing() async throws {
        // 删除不存在的条目不抛错(ServerRegistry.remove 重试依赖幂等),也不凭空建文件
        try await store.removeValue(forAccount: "never-exists")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    }

    func testRemoveAllClearsEveryAccount() async throws {
        try await store.setValue(Data("1".utf8), forAccount: "account-a")
        try await store.setValue(Data("2".utf8), forAccount: "account-b")
        try await store.removeAll()
        let a = try await store.value(forAccount: "account-a")
        let b = try await store.value(forAccount: "account-b")
        XCTAssertNil(a)
        XCTAssertNil(b)
    }

    func testValueOrDefaultCreatesOnceAndReuses() async throws {
        // DeviceId 的「全 App 唯一」依赖这个原子 get-or-set
        let first = try await store.value(forAccount: "device", defaultingTo: {
            Data("generated".utf8)
        })
        let second = try await store.value(forAccount: "device", defaultingTo: {
            Data("other".utf8)
        })
        XCTAssertEqual(first, Data("generated".utf8))
        XCTAssertEqual(second, Data("generated".utf8))
    }

    // MARK: - 落盘

    func testValuesSurviveNewInstance() async throws {
        try await store.setValue(Data("1".utf8), forAccount: "account-a")
        let reopened = CredentialFileStore(fileURL: fileURL)
        let loaded = try await reopened.value(forAccount: "account-a")
        XCTAssertEqual(loaded, Data("1".utf8))
    }

    func testFileIsOwnerOnlyAndExcludedFromBackup() async throws {
        try await store.setValue(Data("1".utf8), forAccount: "account-a")
        // 覆盖写一次:rename 换了 inode,属性要跟着新文件走
        try await store.setValue(Data("2".utf8), forAccount: "account-a")

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o600)
        let values = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testCorruptedFileThrowsAndIsLeftUntouched() async throws {
        let garbage = Data("not json".utf8)
        try garbage.write(to: fileURL)

        do {
            _ = try await store.value(forAccount: "deviceId")
            XCTFail("损坏的文件应抛错")
        } catch let error as CredentialFileError {
            XCTAssertEqual(error, .corrupted)
        }
        do {
            try await store.setValue(Data("x".utf8), forAccount: "account-a")
            XCTFail("损坏的文件上写入也应抛错")
        } catch let error as CredentialFileError {
            XCTAssertEqual(error, .corrupted)
        }
        // ⛔ 不得覆盖:里面可能有唯一的 DeviceId
        XCTAssertEqual(try Data(contentsOf: fileURL), garbage)
    }

    // MARK: - 旧版钥匙串导入

    func testLegacyImportRunsOnceAndPersists() async throws {
        let calls = CallCounter()
        let importer: CredentialFileStore.LegacyImport = {
            calls.increment()
            return ["deviceId": Data("LEGACY-DEVICE".utf8)]
        }
        let first = CredentialFileStore(fileURL: fileURL, legacyImport: importer)
        let deviceID = try await first.value(forAccount: "deviceId")
        XCTAssertEqual(deviceID, Data("LEGACY-DEVICE".utf8))

        // 重启:文件里已有「导入过」标记,不再碰钥匙串
        let second = CredentialFileStore(fileURL: fileURL, legacyImport: importer)
        let again = try await second.value(forAccount: "deviceId")
        XCTAssertEqual(again, Data("LEGACY-DEVICE".utf8))
        XCTAssertEqual(calls.value, 1)
    }

    func testLegacyImportDoesNotOverrideNewerValues() async throws {
        // 文件里的值比钥匙串新,优先
        try await store.setValue(Data("NEW-TOKEN".utf8), forAccount: "server-token:A")
        let migrating = CredentialFileStore(fileURL: fileURL) {
            ["server-token:A": Data("OLD-TOKEN".utf8), "deviceId": Data("LEGACY-DEVICE".utf8)]
        }
        let token = try await migrating.value(forAccount: "server-token:A")
        XCTAssertEqual(token, Data("NEW-TOKEN".utf8))
        let deviceID = try await migrating.value(forAccount: "deviceId")
        XCTAssertEqual(deviceID, Data("LEGACY-DEVICE".utf8))
    }

    func testLegacyImportFailureIsNotRetriedUntilRestart() async throws {
        let calls = CallCounter()
        let failing: CredentialFileStore.LegacyImport = {
            calls.increment()
            throw KeychainError(status: errSecAuthFailed)
        }
        let migrating = CredentialFileStore(fileURL: fileURL, legacyImport: failing)
        for _ in 0..<2 {
            do {
                _ = try await migrating.value(forAccount: "deviceId")
                XCTFail("导入失败应抛错,不得当成「没有旧数据」")
            } catch let error as KeychainError {
                XCTAssertEqual(error.status, errSecAuthFailed)
            }
        }
        // 同一进程内不重试(每次重试都会再弹一轮授权窗)
        XCTAssertEqual(calls.value, 1)
        // 失败时不写文件、不打「导入过」标记:DeviceId 不能在导入前就被生成出来
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))

        // 重启后重试,这次成功
        let restarted = CredentialFileStore(fileURL: fileURL) { ["deviceId": Data("LEGACY-DEVICE".utf8)] }
        let deviceID = try await restarted.value(forAccount: "deviceId")
        XCTAssertEqual(deviceID, Data("LEGACY-DEVICE".utf8))
    }
}

/// 闭包是 `@Sendable` 的,计数要跨线程安全。
private final class CallCounter: Sendable {
    private let count = Mutex(0)

    func increment() {
        count.withLock { $0 += 1 }
    }

    var value: Int {
        count.withLock { $0 }
    }
}
