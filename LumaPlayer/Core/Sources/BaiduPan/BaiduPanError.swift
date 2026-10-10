import Foundation

/// 百度网盘源的失败。全部折成**可解释**的一句中文文案(`userMessage`),
/// 与 `EmbyAPIError` / `PlaybackFailureFfi` 同一口径。
///
/// ⛔ 不静默吞错:拿不到就抛,并让调用方把它显示出来
/// (CLAUDE.md 硬规则 4「不静默吞错,不用假数据占位」)。
enum BaiduPanError: Error, Equatable {

    /// 还没填 AppKey / SecretKey —— 用户尚未在开放平台建应用
    /// (docs/BAIDU_NETDISK_INTEGRATION.md §2.2 的「普通应用」形态)。
    case appCredentialsMissing
    /// 本地配置不完整(如应用目录名为空)。与 `appCredentialsMissing` 分开:
    /// 这个要用户去填「应用目录名」,那个要去开放平台建应用。
    case configuration(String)
    /// 没有授权:没有 token,或 token 已过期且刷新失败。
    /// ⚠️ 刷新失败会**作废** refresh_token(§3.4),所以这一档只能重新走授权。
    case notAuthorized(String)
    /// 设备码已过期(有效期 300 秒,§3.2)
    case deviceCodeExpired
    /// 等到设备码过期都没等到授权。带上最后一次的失败原因 ——
    /// 官方页没写「等待中」是哪个 `error` 值(见 `isFatalOAuthCode`),
    /// 所以把最后一句话带出来比只报「超时」有用得多。
    case authorizationTimedOut(lastFailure: String)
    /// 用户还没在手机上确认 —— 轮询中的正常态,不是错误
    case authorizationPending
    /// 用户在手机上拒绝了授权
    case authorizationDenied
    /// OAuth 错误响应(`{"error":"...","error_description":"..."}`)。
    ///
    /// ⚠️ 与 `server(errno:)` 分开是因为**轮询授权时必须能分辨**:
    /// 设备码模式下「用户还没确认」也是一个 OAuth 错误响应,得继续等,
    /// 而 `invalid_client` 要立刻失败。⛔ 不能一律当成「授权失败」。
    case oauth(code: String, message: String?)
    /// 业务错误码(`errno`)。`message` 取服务端的 `show_msg`(有就给)。
    case server(errno: Int, message: String?)
    /// HTTP 层:非 2xx、连接失败、响应不是 JSON。
    /// ⛔ 文本一律已过 `SecretRedactor`(URL 上带 `access_token`)。
    case transport(String)
    /// 响应解码失败。只带端点名与解码器描述,**不带响应体**
    /// (响应里可能有 token,ARCHITECTURE.md 8.1)。
    case decoding(endpoint: String, detail: String)
    /// 这个文件百度侧不给在线播(见 §4.4 的错误码表)。文案已带原因。
    case playbackUnsupported(String)
    /// 用户取消(关掉授权页)
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

    /// 是不是「这个目录读不出来」(-7 无权访问 / -9 不存在),而不是网络或 token 问题。
    ///
    /// 区分它只为**应用目录**那一处服务:应用目录 `/apps/{应用目录名}` 读不出来,
    /// 九成是「应用目录名」与控制台里建应用时填的名字不一致
    /// (§2.1:可访问范围完全由它决定)。那种情况给「重试」没用,要引导去核对名字。
    ///
    /// ⚠️ 只认这两个码:它们之外的失败(网络、token、频控)都不是目录本身的问题,
    /// ⛔ 不搞「大概是权限问题」的模糊匹配。
    var isDirectoryUnavailable: Bool {
        guard case .server(let errno, _) = self else { return false }
        return errno == BaiduPanErrno.notPermitted || errno == BaiduPanErrno.notFound
    }

    /// 这个失败是不是「重新授权就能好」。UI 据此决定给「重新授权」还是「重试」。
    var needsAuthorization: Bool {
        switch self {
        case .notAuthorized, .deviceCodeExpired, .authorizationDenied,
             .authorizationTimedOut, .appCredentialsMissing, .oauth:
            return true
        default:
            return false
        }
    }

    /// OAuth 错误码里哪些是**立刻失败**的。
    ///
    /// ⚠️ 其余一律按「继续等」处理。理由:官方「设备码模式授权」页
    /// **没有写**「用户还没确认」时返回哪个 `error` 值(只说了轮询间隔与次数),
    /// 所以不能按某个具体字符串白名单去判「等待中」—— 万一它给的是别的值,
    /// 轮询会在第一次请求就失败。
    /// 反过来判「什么肯定是致命的」是安全的:认不出来的码继续等,
    /// 到点自然超时,并把最后一次的错误带出来。
    /// 这条已登记 `docs/KNOWN_ISSUES.md`(待真实应用核实等待中的响应)。
    static func isFatalOAuthCode(_ code: String) -> Bool {
        ["invalid_client", "invalid_request", "unauthorized_client",
         "access_denied", "expired_token"].contains(code)
    }
}

/// 百度开放平台错误码(`平台简介 > 错误码`,见文档 §4.4 / §4.5)。
///
/// ⚠️ 只列本项目**真的会处置**的那些。表外的码一律原样带出 errno,
/// ⛔ 不编一个「大概是权限问题」的猜测文案。
enum BaiduPanErrno {
    /// 身份验证失败 / Token 无效或过期。§3.4:这几个码混用,都当「需要刷新」处理。
    static let tokenExpired = -6
    /// 文件或目录无权访问(不在 `/apps/{appname}` 范围内时也会撞它,§2.1)
    static let notPermitted = -7
    /// 文件或目录不存在
    static let notFound = -9
    /// 非会员需要看广告才能播
    static let needAd = 133
    /// 命中防盗链(下载时的 `User-Agent` 不对,§4.5)
    static let antiLeech = 31326
    /// 非音视频文件
    static let notMedia = 31301
    /// 视频格式不支持播放
    static let unsupportedFormat = 31304
    /// 码率太高暂不支持流畅播放
    static let bitrateTooHigh = 31338
    /// 非法媒体文件
    static let invalidMedia = 31339
    /// 视频正在转码 —— **可重试**
    static let transcoding = 31341
    /// 视频转码失败
    static let transcodeFailed = 31346
    /// 视频太长,暂不支持在线播放 —— 无解,只能降级到下载
    static let tooLong = 31347
    /// dlink 过期(8 小时),重新取一次即可
    static let dlinkExpired = 31360
    /// 签名错误(dlink 的查询串被截断)
    static let badSignature = 31362

    /// 401 之外的错误码里,哪些表示「token 不能用,去刷新」。
    /// §3.4:`20016` / `20017` / `31045` 与 `-6` 混用。
    static let requiresTokenRefresh: Set<Int> = [-6, 20016, 20017, 31045]

    /// 401 之外的错误码里,哪些值得**原样重试一次**(时机性问题)。
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
