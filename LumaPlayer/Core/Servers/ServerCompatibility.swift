import Foundation

/// 探测到的服务器兼容信息(API_CONTRACT.md 1.4)。
///
/// 随 `ServerProfile` 一起持久化,用于诊断。这里只**记录观察到的事实**:
/// 服务器不由我们控制,版本与能力差异是常态,
/// ⛔ 因此不得据此写硬编码的版本分支(2.4 明确「不为每个版本编写独立分支」)。
struct ServerCompatibility: Codable, Sendable, Equatable, Hashable {
    /// 服务器自己报出来的名称(可能与用户填的显示名不同)
    var serverName: String?
    /// 版本号,例如 `4.9.0.0`
    var serverVersion: String?
    /// 探测确定的 API 路径前缀:`/emby` 或 ""
    var apiPathPrefix: String
    /// scheme 是由局域网 http 回退确定的(API_CONTRACT.md 1.4 要求记录)
    var schemeFellBackToHTTP: Bool
}
