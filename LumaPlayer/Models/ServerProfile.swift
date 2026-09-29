import Foundation

/// 一台 Emby 服务器的非敏感配置(ARCHITECTURE.md 6.1 的契约模型)。
///
/// ⚠️ AccessToken **不**属于此类型:token 按 `id` 存本地凭据文件
/// (API_CONTRACT.md 1.2、2.2),因此本模型可安全持久化到 UserDefaults
/// 并出现在诊断输出里(UserDefaults dump 不含 token)。
struct ServerProfile: Codable, Identifiable, Sendable, Equatable, Hashable {
    let id: UUID

    /// 用户可见名称
    var displayName: String

    /// 站点根,**不含** `/emby` 前缀(API_CONTRACT.md 1.2)
    var baseURL: URL

    /// `/emby` 或 `""`。由探测阶段确定后保存,禁止每次请求时重新猜
    /// (API_CONTRACT.md 1.2、ARCHITECTURE.md 6.1)。
    var apiPathPrefix: String

    var serverID: String?
    var serverVersion: String?

    var userID: String?
    var username: String?

    /// 探测到的兼容信息(由 `ServerConnection` 写入)。
    /// 可选字段:尚未探测过的服务器没有这个值。
    var compatibility: ServerCompatibility?

    /// 本机设备 ID。全 App 唯一、存本地凭据文件、删服务器时不删(API_CONTRACT.md 2.4);
    /// 各 profile 持有的是同一个值。
    var deviceID: String

    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        displayName: String,
        baseURL: URL,
        apiPathPrefix: String = "",
        serverID: String? = nil,
        serverVersion: String? = nil,
        userID: String? = nil,
        username: String? = nil,
        compatibility: ServerCompatibility? = nil,
        deviceID: String,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiPathPrefix = apiPathPrefix
        self.serverID = serverID
        self.serverVersion = serverVersion
        self.userID = userID
        self.username = username
        self.compatibility = compatibility
        self.deviceID = deviceID
        self.lastUsedAt = lastUsedAt
    }
}
