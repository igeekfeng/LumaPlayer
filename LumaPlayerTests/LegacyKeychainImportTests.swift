import Security
import XCTest
@testable import LumaPlayer

/// 旧版钥匙串导入(真实钥匙串)。
/// 每个用例用唯一 service 隔离,条目由测试进程自己创建(读取不弹授权窗),tearDown 逐条删除。
final class LegacyKeychainImportTests: XCTestCase {
    private var service: String!
    private var createdAccounts: [String] = []

    override func setUp() {
        super.setUp()
        service = "test.LumaPlayer.legacy.\(UUID().uuidString)"
        createdAccounts = []
    }

    override func tearDown() {
        for account in createdAccounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service as String,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
        service = nil
        super.tearDown()
    }

    func testMissingServiceImportsNothing() throws {
        let values = try LegacyKeychainImport.values(service: service) { _ in true }
        XCTAssertEqual(values, [:])
    }

    func testFilterSelectsAccounts() throws {
        try addItem("A", account: "keep-1")
        try addItem("B", account: "keep-2")
        try addItem("C", account: "skip")

        let values = try LegacyKeychainImport.values(service: service) { $0.hasPrefix("keep-") }
        XCTAssertEqual(values, ["keep-1": Data("A".utf8), "keep-2": Data("B".utf8)])
    }

    func testCredentialImportTakesDeviceIDAndTokensButNotPasswords() throws {
        let serverID = UUID()
        try addItem("LEGACY-DEVICE", account: "deviceId")
        try addItem("FAKE_TOKEN", account: "server-token:\(serverID.uuidString)")
        try addItem("FAKE_PASSWORD", account: "server-password:\(serverID.uuidString)")

        let values = try CredentialStore.legacyKeychainImport(service: service)()
        XCTAssertEqual(values, [
            "deviceId": Data("LEGACY-DEVICE".utf8),
            "server-token:\(serverID.uuidString)": Data("FAKE_TOKEN".utf8),
        ])
    }

    func testImportedValuesReadBackThroughCredentialStore() async throws {
        // 端到端:旧版 account 命名与新存储一致,导入后读得出来
        let serverID = UUID()
        try addItem("LEGACY-DEVICE", account: "deviceId")
        try addItem("FAKE_TOKEN", account: "server-token:\(serverID.uuidString)")
        let storage = CredentialFileStore(
            fileURL: .temporaryCredentialsFile(),
            legacyImport: CredentialStore.legacyKeychainImport(service: service)
        )
        let credentials = CredentialStore(storage: storage)

        let deviceID = try await credentials.deviceID()
        XCTAssertEqual(deviceID, "LEGACY-DEVICE", "迁移后 DeviceId 必须是旧值,不得重新生成")
        let token = try await credentials.token(forServer: serverID)
        XCTAssertEqual(token, "FAKE_TOKEN")
        try await storage.removeAll()
    }

    private func addItem(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service as String,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        createdAccounts.append(account)
    }
}
