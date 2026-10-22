import Foundation

/// 弹弹play 请求失败。「没匹配上」「搜索无结果」不是错误,是合法空结果。
enum DandanplayError: Error, Equatable {

    /// 还没填 AppId / AppSecret(要用户去填;`forbidden` 是要用户去查)。
    case credentialsMissing
    /// 只调公开接口,出现即说明签名头没带上(§1)。
    case unauthorized
    /// 凭据无效、签名不符、时间戳偏差过大或 IP 被屏蔽(§1)。`reason` 取响应头 `X-Error-Message`。
    case forbidden(reason: String?)
    case server(statusCode: Int)
    /// HTTP 200 但 `success == false`。`detail` 在参数校验失败时指向具体字段。
    case api(code: Int?, message: String?, detail: String?)
    /// ⛔ 文本一律已过 `SecretRedactor`。
    case transport(String)
    /// 只带解码器描述,不带响应体。
    case decoding(detail: String)

    var userMessage: String {
        switch self {
        case .credentialsMissing:
            return "还没有填写弹弹play 的 AppId / AppSecret。去「设置 → 弹幕」填一下。"
        case .unauthorized:
            return "弹弹play 要求身份验证(HTTP 401)。"
        case .forbidden(let reason):
            let hint: String
            switch reason {
            case "Invalid Timestamp": hint = ":本机时间与服务器相差过大,校准一下系统时间"
            case "Invalid Signature": hint = ":签名不符,检查 AppSecret 是否填对"
            case let reason?: hint = ":\(reason)"
            case nil: hint = ""
            }
            return "弹弹play 拒绝了请求(HTTP 403)\(hint)。"
        case .server(let statusCode):
            return "弹弹play 返回了错误(HTTP \(statusCode))。"
        case .api(let code, let message, let detail):
            let reason = [message, detail].compactMap { $0 }.joined(separator: " · ")
            let parts = [code.map { "错误码 \($0)" }, reason.isEmpty ? nil : reason].compactMap { $0 }
            return "弹弹play 返回失败\(parts.isEmpty ? "" : "(\(parts.joined(separator: ":")))")。"
        case .transport(let detail):
            return "连接弹弹play 失败:\(detail)"
        case .decoding(let detail):
            return "解析弹弹play 的响应失败:\(detail)"
        }
    }

    /// 去设置页填 / 查凭据就能好。
    var needsCredentials: Bool {
        switch self {
        case .credentialsMissing, .unauthorized: return true
        case .forbidden(let reason): return reason != "Invalid Timestamp"
        default: return false
        }
    }
}
