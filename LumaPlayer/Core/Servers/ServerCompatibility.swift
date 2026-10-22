import Foundation

/// 探测到的服务器兼容信息(API_CONTRACT.md 1.4),随 `ServerProfile` 持久化,用于诊断。
/// ⛔ 只记录事实,不据此写硬编码的版本分支(2.4)。
struct ServerCompatibility: Codable, Sendable, Equatable, Hashable {
    /// 服务器自报的名称(可能与用户填的显示名不同)
    var serverName: String?
    /// 例如 `4.9.0.0`
    var serverVersion: String?
    /// `/emby` 或 ""
    var apiPathPrefix: String
    /// scheme 由局域网 http 回退确定(1.4 要求记录)
    var schemeFellBackToHTTP: Bool
}
