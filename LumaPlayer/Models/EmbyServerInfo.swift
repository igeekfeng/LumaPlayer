import Foundation

/// `/System/Info/Public`(免认证)与 `/System/Info`(需认证)的响应(API_CONTRACT.md 3.1)。
/// 字段**全部可选**:服务器不由我们控制,不同版本 / 权限下返回差异很大,缺失时上层按「未知」展示,
/// ⛔ 不得在模型层填假默认值(8.1)。
struct EmbyServerInfo: Decodable, Sendable, Equatable {
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
