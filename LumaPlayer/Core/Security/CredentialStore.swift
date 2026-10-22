import Foundation

enum CredentialStoreError: Error {
    /// DeviceId 不是合法 UTF-8
    case corruptedDeviceID
}

/// 凭据的存取语义(底层是 `CredentialFileStore`)。
///
/// - token:按 `ServerProfile.id` 分服务器存,删服务器时同步删;
/// - DeviceId:全 App 唯一,删服务器时⛔ 不删(按服务器生成会让 Emby 后台出一堆重复设备,API_CONTRACT.md 2.4);
/// - 密码:仅勾了「记住密码」才存,用于 token 吊销后静默重登(API_CONTRACT.md 2.5)。
actor CredentialStore {
    private static let deviceIDAccount = "deviceId"
    private static let tokenAccountPrefix = "server-token:"
    private static let passwordAccountPrefix = "server-password:"

    private let storage: CredentialFileStore

    init(storage: CredentialFileStore) {
        self.storage = storage
    }

    /// 钥匙串导入:account 名原样搬,只导 DeviceId 与 token,`server-password:*` 不导。
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

    /// 首次调用生成并写入,之后恒返回同一值;原子性靠 `CredentialFileStore` 的 get-or-set。
    func deviceID() async throws -> String {
        let data = try await storage.value(forAccount: Self.deviceIDAccount) {
            Data(UUID().uuidString.utf8)
        }
        guard let id = String(data: data, encoding: .utf8), !id.isEmpty else {
            throw CredentialStoreError.corruptedDeviceID
        }
        return id
    }

    // MARK: - 百度网盘(docs/BAIDU_PAN_API.md §1)

    /// 全 App 一份(一个 App 对应开放平台上一个应用、授权一次),account 不带 id。
    private enum BaiduAccount {
        static let appCredentials = "baidu-app-credentials"
        static let token = "baidu-token"
        /// 旧的全 App 单值片库根,只读兼容(见 `baiduPanLibraryRoot(for:)`)。⛔ 不要往里写。
        static let legacyLibraryRoot = "baidu-library-root"
    }

    /// 整体一个 JSON 落盘:分开写中途失败会留下半截配置,只会反复「授权失败」看不出缺什么。
    struct BaiduPanAppConfiguration: Codable, Sendable, Equatable {
        var appKey: String
        var secretKey: String
        /// 第三方应用只能访问 `/apps/{这个值}`(§3)
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

    /// 只在删最后一个百度来源时用;解除授权保留它,重新扫码不用再填密钥。
    func deleteBaiduPanAppConfiguration() async throws {
        try await storage.removeValue(forAccount: BaiduAccount.appCredentials)
    }

    /// 片库根:`/apps/{应用目录名}` 内的起点目录,按来源 id 分(同一授权下可有多个来源)。
    /// ⛔ 不塞进 `BaiduPanAppConfiguration`:改 AppKey 会作废 token,改片库根不该碰它们。
    private static func libraryRootAccount(for sourceID: UUID) -> String {
        "baidu-library-root:" + sourceID.uuidString
    }

    /// nil = 没设,直接用应用目录。新键没写过时继承旧键 `baidu-library-root`(每个来源各继承一次);
    /// 写过新键就不再回看旧键,清掉的不会「复活」。
    func baiduPanLibraryRoot(for sourceID: UUID) async throws -> BaiduPanLibraryRoot? {
        if let data = try await storage.value(forAccount: Self.libraryRootAccount(for: sourceID)) {
            return try JSONDecoder().decode(StoredLibraryRoot.self, from: data).root
        }
        guard let legacy = try await storage.value(forAccount: BaiduAccount.legacyLibraryRoot) else {
            return nil
        }
        return try? JSONDecoder().decode(BaiduPanLibraryRoot.self, from: legacy)
    }

    /// nil = 明确清空:写一个「没有」而不是删键,删键会触发旧键继承。
    func saveBaiduPanLibraryRoot(_ root: BaiduPanLibraryRoot?, for sourceID: UUID) async throws {
        try await storage.setValue(
            JSONEncoder().encode(StoredLibraryRoot(root: root)),
            forAccount: Self.libraryRootAccount(for: sourceID))
    }

    /// 删来源时用。⛔ 不要拿它当「清空片库根」(会触发旧键继承)。
    func deleteBaiduPanLibraryRoot(for sourceID: UUID) async throws {
        try await storage.removeValue(forAccount: Self.libraryRootAccount(for: sourceID))
    }

    /// 包一层区分「没写过」(要继承旧键)与「写过但清空」(⛔ 不能继承);直接存 `BaiduPanLibraryRoot?` 分不开。
    private struct StoredLibraryRoot: Codable {
        var root: BaiduPanLibraryRoot?
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

    /// 解绑:只删 token,保留 AppKey / SecretKey / 目录名。
    func deleteBaiduPanToken() async throws {
        try await storage.removeValue(forAccount: BaiduAccount.token)
    }

    // MARK: - TMDB 刮削(docs/TMDB_API.md §1)

    /// v4 Read Access Token,全 App 一份刮所有来源。
    private static let tmdbReadAccessTokenAccount = "tmdb-read-access-token"

    func tmdbReadAccessToken() async throws -> String? {
        guard let data = try await storage.value(forAccount: Self.tmdbReadAccessTokenAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func saveTMDBReadAccessToken(_ token: String) async throws {
        try await storage.setValue(Data(token.utf8), forAccount: Self.tmdbReadAccessTokenAccount)
    }

    func deleteTMDBReadAccessToken() async throws {
        try await storage.removeValue(forAccount: Self.tmdbReadAccessTokenAccount)
    }

    // MARK: - 弹弹play 弹幕(docs/DANDANPLAY_API.md §1)

    /// AppId + AppSecret 整体一个 JSON(理由同 `BaiduPanAppConfiguration`),全 App 一份。
    /// AppSecret 只在本地算签名,⛔ 不作为请求头发出(见 `DandanplayClient`)。
    private static let dandanplayCredentialsAccount = "dandanplay-app-credentials"

    func dandanplayCredentials() async throws -> DandanplayCredentials? {
        guard let data = try await storage.value(forAccount: Self.dandanplayCredentialsAccount) else {
            return nil
        }
        return try JSONDecoder().decode(DandanplayCredentials.self, from: data)
    }

    func saveDandanplayCredentials(_ credentials: DandanplayCredentials) async throws {
        try await storage.setValue(
            JSONEncoder().encode(credentials), forAccount: Self.dandanplayCredentialsAccount)
    }

    func deleteDandanplayCredentials() async throws {
        try await storage.removeValue(forAccount: Self.dandanplayCredentialsAccount)
    }

    // MARK: - assrt(伪射手)在线字幕

    /// assrt API 密钥(32 位),全 App 一份(接口事实见 `AssrtEndpoint`)。
    private static let assrtTokenAccount = "assrt-api-token"

    func assrtToken() async throws -> String? {
        guard let data = try await storage.value(forAccount: Self.assrtTokenAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveAssrtToken(_ token: String) async throws {
        try await storage.setValue(Data(token.utf8), forAccount: Self.assrtTokenAccount)
    }

    func deleteAssrtToken() async throws {
        try await storage.removeValue(forAccount: Self.assrtTokenAccount)
    }
}
