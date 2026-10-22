import Foundation

/// 百度网盘源的失败,全部折成一句可解释的中文文案(`userMessage`),与 `EmbyAPIError` 同口径。
enum BaiduPanError: Error, Equatable {

    /// 还没填 AppKey / SecretKey
    case appCredentialsMissing
    /// 本地配置不完整(如应用目录名为空)
    case configuration(String)
    /// 没有 token,或刷新失败(refresh_token 随之作废,§6),只能重新授权。
    case notAuthorized(String)
    /// 设备码已过期(有效期 300 秒)
    case deviceCodeExpired
    /// 等到设备码过期都没等到授权。带最后一次失败原因(见 `isFatalOAuthCode`)。
    case authorizationTimedOut(lastFailure: String)
    /// 轮询中的正常态,不是错误
    case authorizationPending
    case authorizationDenied
    /// OAuth 错误响应(`{"error":"...","error_description":"..."}`)。
    /// ⛔ 不能一律当授权失败:「用户还没确认」也是这种响应,得继续等。
    case oauth(code: String, message: String?)
    /// 业务错误码(`errno`)。`message` 取服务端的 `show_msg` / `errmsg`。
    case server(errno: Int, message: String?)
    /// 非 2xx、连接失败、响应不是 JSON。⛔ 文本必须已过 `SecretRedactor`。
    case transport(String)
    /// ⛔ 不带响应体(可能有 token)。
    case decoding(endpoint: String, detail: String)
    /// 百度不给在线播(`BAIDU_PAN_API.md` §5),文案已带原因。
    case playbackUnsupported(String)
    case cancelled

    var userMessage: String {
        switch self {
        case .appCredentialsMissing:
            return "还没有配置百度网盘的 AppKey / SecretKey。先在开放平台建一个应用,再把两串密钥填进来。"
        case .configuration(let detail):
            return detail
        case .notAuthorized(let detail):
            return "百度网盘授权已失效,需要重新授权(\(detail))。"
        case .deviceCodeExpired:
            return "授权二维码已过期(有效期 5 分钟),请重新获取。"
        case .authorizationTimedOut(let lastFailure):
            return "等待授权超时,请重新获取二维码。最后一次返回:\(lastFailure)"
        case .authorizationPending:
            return "等待手机上确认…"
        case .authorizationDenied:
            return "你在手机上拒绝了本次授权。"
        case .oauth(let code, let message):
            return "百度授权失败(\(code))\(message.map { ":\($0)" } ?? "")。"
        case .server(let errno, let message):
            return BaiduPanErrno.userMessage(errno: errno, serverMessage: message)
        case .transport(let detail):
            return "连接百度网盘失败:\(detail)"
        case .decoding(let endpoint, let detail):
            return "解析百度网盘的响应失败(\(endpoint)):\(detail)"
        case .playbackUnsupported(let detail):
            return detail
        case .cancelled:
            return "已取消。"
        }
    }

    /// 目录本身读不出来(只认 -7 / -9,⛔ 不模糊匹配)。应用目录读不出来多半是「应用目录名」
    /// 与控制台填的不一致(§3),给「重试」没用。
    var isDirectoryUnavailable: Bool {
        guard case .server(let errno, _) = self else { return false }
        return errno == BaiduPanErrno.notPermitted || errno == BaiduPanErrno.notFound
    }

    /// UI 据此决定给「重新授权」还是「重试」。
    var needsAuthorization: Bool {
        switch self {
        case .notAuthorized, .deviceCodeExpired, .authorizationDenied,
             .authorizationTimedOut, .appCredentialsMissing, .oauth:
            return true
        default:
            return false
        }
    }

    /// 立刻失败的 OAuth 错误码,其余一律继续等。官方没写「等待中」返回哪个值,
    /// ⛔ 不能按白名单判等待中;认不出的码等到超时并带出最后一次错误。
    static func isFatalOAuthCode(_ code: String) -> Bool {
        ["invalid_client", "invalid_request", "unauthorized_client",
         "access_denied", "expired_token"].contains(code)
    }
}

/// 百度开放平台错误码(`BAIDU_PAN_API.md` §5)。
///
/// 只列本项目会处置的。表外的码原样带出 errno,⛔ 不编猜测文案。
enum BaiduPanErrno {
    /// Token 无效或过期(§6)
    static let tokenExpired = -6
    /// 无权访问(不在 `/apps/{appname}` 范围内也会撞它,§3)
    static let notPermitted = -7
    static let notFound = -9
    /// 非会员要看广告才能播
    static let needAd = 133
    /// 防盗链(`User-Agent` 不对,§1)
    static let antiLeech = 31326
    static let notMedia = 31301
    static let unsupportedFormat = 31304
    static let bitrateTooHigh = 31338
    static let invalidMedia = 31339
    /// 正在转码,可重试
    static let transcoding = 31341
    static let transcodeFailed = 31346
    /// 无解,只能下载
    static let tooLong = 31347
    /// dlink 过期(8 小时),重取即可
    static let dlinkExpired = 31360
    /// dlink 查询串被截断
    static let badSignature = 31362

    /// 与 `-6` 同义,都去刷新 token(§5)。
    static let requiresTokenRefresh: Set<Int> = [-6, 20016, 20017, 31045]

    /// 时机性问题,原样重试一次。
    static let retryable: Set<Int> = [31341, 31360]

    static func userMessage(errno: Int, serverMessage: String?) -> String {
        let base: String
        switch errno {
        case tokenExpired:
            base = "百度网盘授权已过期"
        case notPermitted:
            base = "这个文件不在应用可访问的范围内(只允许 /apps/{应用目录} 下的文件)"
        case notFound:
            base = "文件不存在了"
        case needAd:
            base = "这个账号不是会员,百度要求先看广告才能播放"
        case antiLeech:
            base = "被百度防盗链拦下了(请求头不对)"
        case notMedia:
            base = "这不是音视频文件"
        case unsupportedFormat:
            base = "百度不支持在线播放这个视频格式"
        case bitrateTooHigh:
            base = "码率太高,百度不给流畅播;建议下载后本地播放"
        case invalidMedia:
            base = "百度判定这是非法媒体文件"
        case transcoding:
            base = "视频还在云端转码,稍后重试"
        case transcodeFailed:
            base = "百度转码失败"
        case tooLong:
            base = "视频太长,百度不支持在线播放;只能下载后本地播放"
        case dlinkExpired:
            base = "下载地址已过期(有效期 8 小时)"
        case badSignature:
            base = "下载地址签名错误"
        default:
            base = "百度网盘返回了错误码 \(errno)"
        }
        guard let serverMessage, !serverMessage.isEmpty else { return "\(base)。" }
        return "\(base):\(serverMessage)"
    }
}
