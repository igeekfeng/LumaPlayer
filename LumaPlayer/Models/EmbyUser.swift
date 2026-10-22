import Foundation

/// Emby 用户对象(认证响应里的 `User`,API_CONTRACT.md 3.1)。`Id` 必填(8.1 必填表),`Name` 可选。
struct EmbyUser: Decodable, Sendable, Equatable {
    let id: String
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

/// `POST /Users/AuthenticateByName` 的响应(API_CONTRACT.md 3.1)。
/// ⚠️ 拼写核实状态:`AccessToken` / `User` 已核实 ✅;请求体的 `Pw` 已实测(docs/PITFALLS.md Q10)。
struct AuthenticationResult: Decodable, Sendable, Equatable {
    /// 后续所有请求的 `X-Emby-Token`(API_CONTRACT.md 2.2)。必填(8.1)。
    let accessToken: String
    let user: EmbyUser
    /// 不在 8.1 的必填表里 → 可选
    let serverID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
        case serverID = "ServerId"
    }
}
