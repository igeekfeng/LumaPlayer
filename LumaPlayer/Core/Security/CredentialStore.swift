import Foundation

/// CredentialStore 的错误。
enum CredentialStoreError: Error {
    /// 凭据文件里的 DeviceId 不是合法的 UTF-8(被外部篡改或损坏)
    case corruptedDeviceID
}

/// 服务器凭证的存取语义(actor,CLAUDE.md「并发分层」)。
///
/// 三个职责:
/// - **AccessToken**:按 `ServerProfile.id` 分服务器存,删除服务器时同步删
///   (token 本体走 `X-Emby-Token` 头,见 API_CONTRACT.md 2.2);
/// - **DeviceId**:全 App 唯一,首次生成后落盘,account 固定 `deviceId`,
///   删除服务器时**不**删(API_CONTRACT.md 2.4 —— 按服务器生成会让
///   Emby 后台出现一堆重复设备记录)。
///
/// - **密码**:**可选**,仅用户在登录表单勾了「记住密码」的服务器才有;
///   用于 token 被吊销后静默重新登录(`API_CONTRACT.md 2.5`)。
///   和 token 一样存凭据文件(base64 只是编码,不是加密),**不进钥匙串**。
///
/// 方法是 `async`:CredentialFileStore 是另一个 actor,跨 actor 调用隐式异步
/// (`ServerRegistry.remove(id:) async throws` 同理,见 CLAUDE.md「并发分层」)。
actor CredentialStore {
    /// DeviceId 的固定 account(API_CONTRACT.md 2.4)
    private static let deviceIDAccount = "deviceId"
    private static let tokenAccountPrefix = "server-token:"
    private static let passwordAccountPrefix = "server-password:"

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

    // MARK: - 服务器密码(可选)

    func savePassword(_ password: String, forServer id: UUID) async throws {
        try await storage.setValue(Data(password.utf8), forAccount: Self.passwordAccount(forServer: id))
    }

    func password(forServer id: UUID) async throws -> String? {
        guard let data = try await storage.value(forAccount: Self.passwordAccount(forServer: id)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func deletePassword(forServer id: UUID) async throws {
        try await storage.removeValue(forAccount: Self.passwordAccount(forServer: id))
    }

    private static func passwordAccount(forServer id: UUID) -> String {
        passwordAccountPrefix + id.uuidString
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

    // MARK: - 百度网盘(docs/BAIDU_PAN_API.md §1、docs/SOURCE_ABSTRACTION_PLAN.md §4.1)

    /// 百度源只有**一份**凭据,不像 Emby 那样按服务器分 ——
    /// 一个 App 只对应开放平台上的一个应用,一个用户只授权一次。
    /// 所以 account 是固定名字,不带 id。
    private enum BaiduAccount {
        /// AppKey / SecretKey / 应用目录名 的 JSON(一次写完,见下)
        static let appCredentials = "baidu-app-credentials"
        /// `BaiduPanTokenBundle` 的 JSON
        static let token = "baidu-token"
        /// 片库根(用户在应用目录里选定的起点)
        static let libraryRoot = "baidu-library-root"
    }

    /// AppKey / SecretKey / 应用目录名。整体作为一个 JSON 落盘:
    /// 分三个 account 写的话,中途失败会留下「有 AppKey 没 SecretKey」的半截配置,
    /// 而那种状态只会让人反复撞「授权失败」却看不出哪里缺。
    struct BaiduPanAppConfiguration: Codable, Sendable, Equatable {
        var appKey: String
        var secretKey: String
        /// 应用目录名:第三方应用只能访问 `/apps/{这个值}`(`BAIDU_PAN_API.md` §3)
        var folderName: String
    }

    func baiduPanAppConfiguration() async throws -> BaiduPanAppConfiguration? {
        guard let data = try await storage.value(forAccount: BaiduAccount.appCredentials) else {
            return nil
        }
        return try JSONDecoder().decode(BaiduPanAppConfiguration.self, from: data)
    }

    func saveBaiduPanAppConfiguration(_ configuration: BaiduPanAppConfiguration) async throws {
        try await storage.setValue(
            JSONEncoder().encode(configuration), forAccount: BaiduAccount.appCredentials)
    }

    /// 删除整套应用凭据。**只在删除整个百度来源时用** ——
    /// 解除授权(`deleteBaiduPanToken`)刻意保留它,重新扫码不该逼人再填一遍密钥。
    func deleteBaiduPanAppConfiguration() async throws {
        try await storage.removeValue(forAccount: BaiduAccount.appCredentials)
    }

    /// 片库根:用户在 `/apps/{应用目录名}` **内部**选定的一个子目录,作为进来时的起点。
    ///
    /// ⛔ 它**不是**应用凭据,所以不塞进 `BaiduPanAppConfiguration`:
    /// 改片库根不该碰 AppKey / token,而改 AppKey 会连带作废 token
    /// (见 `BaiduPanConnection.saveConfiguration`)。两件事的生命周期不同。
    struct BaiduPanLibraryRoot: Codable, Sendable, Equatable {
        var path: String
    }

    func baiduPanLibraryRoot() async throws -> BaiduPanLibraryRoot? {
        guard let data = try await storage.value(forAccount: BaiduAccount.libraryRoot) else {
            return nil
        }
        return try JSONDecoder().decode(BaiduPanLibraryRoot.self, from: data)
    }

    func saveBaiduPanLibraryRoot(_ root: BaiduPanLibraryRoot) async throws {
        try await storage.setValue(
            JSONEncoder().encode(root), forAccount: BaiduAccount.libraryRoot)
    }

    func deleteBaiduPanLibraryRoot() async throws {
        try await storage.removeValue(forAccount: BaiduAccount.libraryRoot)
    }

    func baiduPanToken() async throws -> BaiduPanTokenBundle? {
        guard let data = try await storage.value(forAccount: BaiduAccount.token) else {
            return nil
        }
        return try JSONDecoder().decode(BaiduPanTokenBundle.self, from: data)
    }

    func saveBaiduPanToken(_ bundle: BaiduPanTokenBundle) async throws {
        try await storage.setValue(JSONEncoder().encode(bundle), forAccount: BaiduAccount.token)
    }

    /// 解绑:删 token,**保留** AppKey / SecretKey / 目录名
    /// —— 重新授权不该逼用户再填一遍密钥。
    func deleteBaiduPanToken() async throws {
        try await storage.removeValue(forAccount: BaiduAccount.token)
    }
}
