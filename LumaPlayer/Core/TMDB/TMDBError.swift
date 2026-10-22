import Foundation

/// TMDB 刮削的失败,`userMessage` 给一句可解释的中文。
/// 「搜索没命中」是合法空结果(返回空数组),⛔ 不造 `noResults` case 冒充失败。
enum TMDBError: Error, Equatable {

    /// 没填 v4 Read Access Token(与 `unauthorized` 分开:一个要去填,一个要去查对不对)
    case tokenMissing
    /// HTTP 401。`code` / `message` 取响应体 `status_code` / `status_message`(`docs/TMDB_API.md` §5)
    case unauthorized(code: Int?, message: String?)
    /// HTTP 429
    case rateLimited(message: String?)
    /// HTTP 404
    case notFound(message: String?)
    /// 其余非 2xx
    case server(statusCode: Int, message: String?)
    /// 连不上 / 响应不是 HTTP。⛔ 文本须已过 `SecretRedactor`(可能含带参数的 URL)
    case transport(String)
    /// 只带解码器描述,不带响应体
    case decoding(detail: String)

    var userMessage: String {
        switch self {
        case .tokenMissing:
            return "还没有填写 TMDB 的 Read Access Token。去「设置 → 通用 → 元数据刮削」填一下。"
        case .unauthorized(let code, let message):
            return "TMDB 拒绝了这串 token\(code.map { "(错误码 \($0))" } ?? "")\(Self.detail(message))。"
        case .rateLimited(let message):
            return "TMDB 请求太频繁了,稍后再试\(Self.detail(message))。"
        case .notFound(let message):
            return "TMDB 找不到这个资源\(Self.detail(message))。"
        case .server(let statusCode, let message):
            return "TMDB 返回了错误(HTTP \(statusCode))\(Self.detail(message))。"
        case .transport(let detail):
            return "连接 TMDB 失败:\(detail)"
        case .decoding(let detail):
            return "解析 TMDB 的响应失败:\(detail)"
        }
    }

    /// UI 据此给「去设置」还是「重试」。
    var needsToken: Bool {
        switch self {
        case .tokenMissing, .unauthorized: return true
        default: return false
        }
    }

    private static func detail(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "" }
        return ":\(message)"
    }
}