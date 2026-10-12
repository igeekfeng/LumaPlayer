import Foundation

/// TMDB 刮削的失败。全部折成**可解释**的一句中文文案(`userMessage`),
/// 与 `EmbyAPIError` / `BaiduPanError` 同一口径。
///
/// ⛔ 不静默吞错:拿不到就抛,并让调用方把它显示出来
/// (CLAUDE.md 硬规则 4「不静默吞错,不用假数据占位」)。
///
/// ⚠️ 「搜索没有命中」**不是**错误 —— 那是一个合法的空结果,
/// `TMDBClient` 返回空数组,⛔ 不在这里造一个 `noResults` case 去冒充失败。
enum TMDBError: Error, Equatable {

    /// 还没在设置里填 v4 Read Access Token。
    /// 与 `unauthorized` 分开:这个要用户去填 token,那个要用户去查 token 对不对。
    case tokenMissing
    /// token 被拒(HTTP 401)。`code` 是响应体里的 `status_code`(官方错误表 §5),
    /// `message` 取 `status_message`(不含凭据)。
    case unauthorized(code: Int?, message: String?)
    /// 频率超限(HTTP 429)。
    case rateLimited(message: String?)
    /// 请求的资源找不到(HTTP 404)。
    case notFound(message: String?)
    /// 其余非 2xx:`statusCode` + 服务端的 `status_message`。
    case server(statusCode: Int, message: String?)
    /// HTTP 层之外的传输失败(连不上、响应不是 HTTP)。
    /// ⛔ 文本一律已过 `SecretRedactor`(途中可能有带参数的 URL)。
    case transport(String)
    /// 响应解码失败。只带解码器描述,**不带响应体**。
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

    /// 这个失败是不是「去设置页检查 / 填 token 就能好」。UI 据此决定给「去设置」还是「重试」。
    var needsToken: Bool {
        switch self {
        case .tokenMissing, .unauthorized: return true
        default: return false
        }
    }

    /// `status_message` 的存在与否决定要不要带冒号。
    private static func detail(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "" }
        return ":\(message)"
    }
}