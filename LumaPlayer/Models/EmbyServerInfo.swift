import Foundation

/// `/System/Info/Public`(免认证探测)与 `/System/Info`(需认证)的响应
/// (API_CONTRACT.md 3.1)。
///
/// 字段**全部可选**:API_CONTRACT.md 8.1 的必填表不含本类型,而服务器
/// 不由我们控制,不同版本、不同权限下这个端点
/// 返回的字段差异很大。缺失时上层按「未知」展示,
/// ⛔ 不得在模型层填假默认值(8.1)。
struct EmbyServerInfo: Decodable, Sendable, Equatable {
    /// 服务器 Id
    let id: String?
    /// 管理后台里配置的服务器名称
    let serverName: String?
    /// 版本字符串,例如 `4.9.0.0`
    let version: String?

    // 显式 CodingKeys,不用 .convertFromPascalCase(API_CONTRACT.md 8.2)
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
    }
}
