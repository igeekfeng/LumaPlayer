import Foundation

/// assrt 的错误(HTTP 层 + 业务 `status` 码)。
///
/// 业务码来自 <https://assrt.net/api/doc#errors>(2026-10-21):
/// `status != 0` 即失败,HTTP 仍可能是 200 —— ⛔ 不能只看 HTTP 状态。
///
/// 文案写给用户看:该说「密钥不对」就说「密钥不对」,⛔ 不把数字码丢出去。
enum AssrtError: LocalizedError, Equatable {
    /// 还没填 API 密钥
    case missingToken
    /// 密钥无效 / 被重置(`20001`、HTTP 401)
    case invalidToken
    /// 关键词太短(`101`,服务端要求至少 3 个字符)
    case keywordTooShort
    /// 没有这条字幕(`20900`)
    case notFound
    /// 配额超限(`30900`,默认 20 次/分钟,按 token + IP 共享)
    case quotaExceeded
    /// 服务端故障(`30000` / `30001` / `30002` / `30300`)或其它非 2xx
    case server(message: String?)
    /// 传输层失败(断网、超时、响应不是 HTTP)
    case transport(String)
    /// 这条字幕里没有能挂的文本文件(只有压缩包 / 图形字幕)
    case noTextFile

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "还没有填 assrt 的 API 密钥"
        case .invalidToken:
            return "assrt 的 API 密钥无效,请到设置里重新填写"
        case .keywordTooShort:
            return "关键词太短,至少 3 个字符"
        case .notFound:
            return "没有这条字幕(可能已被删除)"
        case .quotaExceeded:
            return "请求太频繁,assrt 每分钟最多 20 次,过一会儿再试"
        case .server(let message):
            return "字幕站返回错误" + (message.map { ":\($0)" } ?? "")
        case .transport(let reason):
            return "网络错误:\(reason)"
        case .noTextFile:
            return "这条字幕只有压缩包或图形字幕(PGS / VobSub),挂不上;换一条试试"
        }
    }

    /// 业务 `status` → 错误;`0` 返回 nil(成功)。
    static func from(status: Int, message: String?) -> AssrtError? {
        switch status {
        case 0: return nil
        case 1: return .invalidToken          // no such user
        case 101: return .keywordTooShort
        case 20001: return .invalidToken
        case 20400: return .server(message: message ?? "接口不存在")
        case 20900: return .notFound
        case 30900: return .quotaExceeded
        default: return .server(message: message)
        }
    }
}
