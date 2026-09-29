import Foundation

/// CredentialStore 的错误。
enum CredentialStoreError: Error {
    /// 凭据文件里的 DeviceId 不是合法的 UTF-8(被外部篡改或损坏)
    case corruptedDeviceID
}

/// 服务器凭证的存取语义(actor,ARCHITECTURE.md 3.1.2)。
///
/// 两个职责:
/// - **AccessToken**:按 `ServerProfile.id` 分服务器存,删除服务器时同步删
///   (token 本体走 `X-Emby-Token` 头,见 API_CONTRACT.md 2.2);
/// - **DeviceId**:全 App 唯一,首次生成后落盘,account 固定 `deviceId`,
///   删除服务器时**不**删(API_CONTRACT.md 2.4 —— 按服务器生成会让
///   Emby 后台出现一堆重复设备记录)。
///
/// 密码**不存**:token 被吊销后回登录页手动输入
/// (`docs/DECISIONS/credentials-file-storage.md`,推翻了 `remember-password-auto-relogin.md`)。
///
/// 方法是 `async`:CredentialFileStore 是另一个 actor,跨 actor 调用隐式异步
/// (`ServerRegistry.remove(id:) async throws` 同理,见 ARCHITECTURE.md 3.1.2)。
actor CredentialStore {
    /// DeviceId 的固定 account(API_CONTRACT.md 2.4)
    private static let deviceIDAccount = "deviceId"
    private static let tokenAccountPrefix = "server-token:"

    private let storage: CredentialFileStore

    init(storage: CredentialFileStore) {
        self.storage = storage
    }

    /// 从旧版钥匙串导入 DeviceId 与各服务器 token(给 `CredentialFileStore` 用)。
    /// account 命名与旧版一致,原样搬过去;旧版存的 `server-password:*` 不导入。
    static func legacyKeychainImport(
        service: String = LegacyKeychainImport.defaultService
    ) -> CredentialFileStore.LegacyImport {
        {
            try LegacyKeychainImport.values(service: service) { account in
                account == deviceIDAccount || account.hasPrefix(tokenAccountPrefix)
            }
        }
    }

    // MARK: - 服务器 token

    func saveToken(_ token: String, forServer id: UUID) async throws {
        try await storage.setValue(Data(token.utf8), forAccount: Self.tokenAccount(forServer: id))
    }

    func token(forServer id: UUID) async throws -> String? {
        guard let data = try await storage.value(forAccount: Self.tokenAccount(forServer: id)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func deleteToken(forServer id: UUID) async throws {
        try await storage.removeValue(forAccount: Self.tokenAccount(forServer: id))
    }

    private static func tokenAccount(forServer id: UUID) -> String {
        tokenAccountPrefix + id.uuidString
    }

    // MARK: - DeviceId

    /// 首次调用生成并写入;之后恒返回同一个值(全 App 唯一)。
    /// 原子性由 CredentialFileStore 的 get-or-set 在单个 actor 隔离内保证。
    func deviceID() async throws -> String {
        let data = try await storage.value(forAccount: Self.deviceIDAccount) {
            Data(UUID().uuidString.utf8)
        }
        guard let id = String(data: data, encoding: .utf8), !id.isEmpty else {
            throw CredentialStoreError.corruptedDeviceID
        }
        return id
    }
}
