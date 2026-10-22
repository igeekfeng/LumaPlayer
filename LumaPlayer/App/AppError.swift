import Foundation

/// 应用层面要呈现给用户的异常;领域错误的文案由使用处映射。
enum AppError: LocalizedError, Equatable {
    /// 服务器列表无法解码,已按空列表启动
    case serverListCorrupted
    case credentialReadFailed
    /// 从钥匙串迁移登录信息失败(多半是授权窗点了「拒绝」),下次启动重试
    case credentialMigrationFailed

    var errorDescription: String? {
        switch self {
        case .serverListCorrupted:
            return "本地服务器列表数据损坏,无法读取。应用将以空列表启动;若之前添加过服务器,请重新添加。"
        case .credentialReadFailed:
            return "无法读取本地保存的登录令牌。"
        case .credentialMigrationFailed:
            return "从钥匙串迁移登录信息失败。请退出并重新打开 LumaPlayer,在钥匙串弹窗中点「允许」。"
        }
    }
}

/// 添加 / 编辑表单共用。
extension ServerURLError {
    var userMessage: String {
        switch self {
        case .malformed:
            return "地址无法解析,请检查输入(例如 https://192.168.1.10:8096)。"
        case .unsupportedScheme:
            return "地址协议只支持 http 或 https。"
        case .missingHost:
            return "地址缺少主机名。"
        }
    }
}

/// API_CONTRACT.md 第 7 节「UI 行为」列。可含 host 与状态码,⛔ 不含带认证参数的 URL。
extension EmbyAPIError {
    var userMessage: String {
        switch self {
        case .unauthorized:
            return "登录已过期,请重新登录。"
        case .forbidden:
            return "没有访问权限,请检查该服务器上的用户权限。"
        case .notFound:
            return "服务器上找不到该内容。"
        case .rateLimited:
            return "服务器繁忙(429),请稍后再试。"
        case .server(let status):
            return "服务器错误(\(status)),请稍后重试。"
        case .unexpectedStatus(let code):
            return "服务器返回异常状态码(\(code))。"
        case .decoding(_, let endpointName):
            return "服务器响应无法解析(端点 \(endpointName))。"
        case .transport:
            return "网络连接失败,请检查网络与服务器地址。"
        case .cancelled:
            // 取消是正常流程,UI 不应显示为错误
            return "请求已取消。"
        }
    }
}

/// 登录体 `Pw` 拼写已核实(PITFALLS.md Q10),401 就是用户名或密码错。
extension ServerLoginError {
    var userMessage: String {
        switch self {
        case .unreachable(let host):
            return "无法连接 \(host):公开信息端点探测失败。请检查地址、网络与反向代理配置。"
        case .invalidCredentials:
            return "用户名或密码错误。"
        case .accessDenied(let error):
            return "登录成功,但读取媒体库失败:\(error.userMessage)"
        case .api(let error):
            return error.userMessage
        case .credentialFailure:
            return "无法把登录令牌保存到本地,登录未生效。"
        }
    }
}
