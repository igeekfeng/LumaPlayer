import Foundation

/// 115 网页版用到的端点(`docs/PAN115_API.md` §1 - §4)。⛔ 路径与参数名以该文档为准,不得发明。
///
/// 主机分工见文档 §1:业务在 `webapi.115.com`,取直链在 `proapi.115.com`,
/// 扫码登录在 `qrcodeapi.115.com` / `passportapi.115.com`。
enum Pan115Endpoint: Sendable, Equatable {

    // MARK: - 扫码登录(qrcodeapi / passportapi)

    /// `GET https://qrcodeapi.115.com/api/1.0/{app}/1.0/token`(§2.2 第 1 步)
    case qrCodeToken(app: String)
    /// `GET https://qrcodeapi.115.com/get/status/?uid=&time=&sign=&_=`(§2.2 第 3 步)
    case qrCodeStatus(uid: String, time: Int, sign: String, now: Int)
    /// `POST https://passportapi.115.com/app/1.0/{app}/1.0/login/qrcode`(§2.2 第 4 步)
    ///
    /// ⚠️ `account` 是 token 响应里的 `uid`,不是 Cookie 里的 `UID`。
    case qrCodeLogin(app: String, account: String)

    // MARK: - 登录态

    /// `GET https://my.115.com/?ct=ajax&ac=nav&_=` —— 用户信息(昵称、VIP)。
    ///
    /// 这是本项目**唯一**的登录态请求。⛔ 不要加 `passportapi.115.com/.../check/sso` 那种探活:
    /// 它会踢掉同设备的其它 Cookie(§2.3),而 Cookie 失效本来就会在第一次列目录时暴露出来。
    case userInfo(now: Int)

    // MARK: - 目录(webapi)

    /// `GET https://webapi.115.com/files`(§3)。`limit` 上限 1150。
    case fileList(cid: String, offset: Int, limit: Int)
    /// `GET https://webapi.115.com/files/getid?path=` —— 按路径换目录 ID
    case directoryID(path: String)
    /// `POST https://webapi.115.com/rb/delete`(§9)。
    ///
    /// `fid` 是**文件 `fid` 或目录 `cid`**,表单字段名是 `fid[0]` / `fid[1]`…(`115driver` 就这么发)。
    /// ⚠️ 一次只传一个:批量语义与条数上限都没实测(§9)。
    case deleteFiles(ids: [String])

    // MARK: - 取直链(proapi)

    /// `POST https://proapi.115.com/app/chrome/downurl?t=<unix秒>`(§4.1)
    ///
    /// body 是 `data=<m115 加密后的 {"pickcode": …}>`。加密在 `Pan115Crypto`,这里只收已加密的串。
    case downloadURL(timestamp: Int, encryptedPayload: String)

    // MARK: - 形状

    var scheme: String { "https" }

    var host: String {
        switch self {
        case .qrCodeToken, .qrCodeStatus:
            return "qrcodeapi.115.com"
        case .qrCodeLogin:
            return "passportapi.115.com"
        case .userInfo:
            return "my.115.com"
        case .fileList, .directoryID, .deleteFiles:
            return "webapi.115.com"
        case .downloadURL:
            return "proapi.115.com"
        }
    }

    var path: String {
        switch self {
        case .qrCodeToken(let app): return "/api/1.0/\(app)/1.0/token"
        case .qrCodeStatus: return "/get/status/"
        case .qrCodeLogin(let app, _): return "/app/1.0/\(app)/1.0/login/qrcode"
        case .userInfo: return "/"
        case .fileList: return "/files"
        case .directoryID: return "/files/getid"
        case .deleteFiles: return "/rb/delete"
        case .downloadURL: return "/app/chrome/downurl"
        }
    }

    var method: String {
        switch self {
        case .qrCodeLogin, .downloadURL, .deleteFiles: return "POST"
        case .qrCodeToken, .qrCodeStatus, .userInfo, .fileList, .directoryID:
            return "GET"
        }
    }

    /// 诊断用端点名,不含凭据,可进日志。
    var name: String {
        switch self {
        case .qrCodeToken: return "qrcode/token"
        case .qrCodeStatus: return "qrcode/status"
        case .qrCodeLogin: return "qrcode/login"
        case .userInfo: return "my/ajax?ac=nav"
        case .fileList: return "webapi/files"
        case .directoryID: return "webapi/files/getid"
        case .deleteFiles: return "webapi/rb/delete"
        case .downloadURL: return "proapi/app/chrome/downurl"
        }
    }

    /// 顺序固定(便于断言与排障)。
    var queryItems: [(name: String, value: String)] {
        switch self {
        case .qrCodeToken:
            return []
        case .qrCodeStatus(let uid, let time, let sign, let now):
            return [
                ("uid", uid),
                ("time", String(time)),
                ("sign", sign),
                ("_", String(now)),
            ]
        case .qrCodeLogin:
            return []
        case .userInfo(let now):
            return [("_", String(now))]
        case .fileList(let cid, let offset, let limit):
            // `show_dir=1` 要目录一起返回;`natsort=0` 用 115 默认顺序,客户端自己排
            return [
                ("aid", "1"),
                ("cid", cid),
                ("o", ""),
                ("asc", ""),
                ("offset", String(offset)),
                ("show_dir", "1"),
                ("limit", String(limit)),
                ("snap", "0"),
                ("natsort", "0"),
                ("record_open_time", "1"),
                ("format", "json"),
                ("fc_mix", "0"),
            ]
        case .directoryID(let path):
            return [("path", path)]
        case .deleteFiles:
            return []
        case .downloadURL(let timestamp, _):
            return [("t", String(timestamp))]
        }
    }

    /// POST 的表单字段;nil = 没有 body。
    var formFields: [(name: String, value: String)]? {
        switch self {
        case .qrCodeLogin(_, let account):
            return [("account", account), ("app", app)]
        case .downloadURL(_, let encryptedPayload):
            return [("data", encryptedPayload)]
        case .deleteFiles(let ids):
            // ⚠️ 字段名带下标:`fid[0]` / `fid[1]`…;`fid=a,b` 这种写法 p115client 也支持,本项目只发前一种。
            return ids.enumerated().map { ("fid[\($0.offset)]", $0.element) }
        case .qrCodeToken, .qrCodeStatus, .userInfo, .fileList, .directoryID:
            return nil
        }
    }

    /// `qrCodeLogin` 的 `app` 要同时出现在 path 与 form 里,单独取出来避免两处不一致。
    private var app: String {
        switch self {
        case .qrCodeLogin(let app, _): return app
        default: return "web"
        }
    }

    var httpBody: Data? {
        guard let fields = formFields else { return nil }
        let encoded = fields.compactMap { item -> String? in
            guard let name = Self.encode(item.name), let value = Self.encode(item.value) else {
                return nil
            }
            return "\(name)=\(value)"
        }
        .joined(separator: "&")
        return encoded.data(using: .utf8)
    }

    var contentType: String? {
        formFields == nil ? nil : "application/x-www-form-urlencoded"
    }

    /// ⚠️ 取直链时的 `User-Agent` 会被写进直链校验(§4.3 的 `f` 参数),
    /// 所以取链与播放**必须用同一个 UA**,都取 `Pan115UserAgent.value`。所有端点统一带它。
    var headers: [String: String] { ["User-Agent": Pan115UserAgent.value] }

    /// ⚠️ 查询串手拼,不走 `URLComponents.queryItems`:后者按 RFC 3986 只编码非法字符,
    /// 而 115 的 `path` / `sign` 里出现 `/` `+` `=` 时必须整体编码,否则签名对不上。
    var url: URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        if !encodedQuery.isEmpty {
            components.percentEncodedQuery = encodedQuery
        }
        return components.url
    }

    var encodedQuery: String {
        queryItems.compactMap { item -> String? in
            guard let name = Self.encode(item.name), let value = Self.encode(item.value) else {
                return nil
            }
            return "\(name)=\(value)"
        }
        .joined(separator: "&")
    }

    /// 只保留 unreserved 字符(`A-Za-z0-9-._~`),空格编成 `%20`。
    static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

/// 115 要的 `User-Agent`(`docs/PAN115_API.md` §4.3)。
///
/// 115 的客户端 UA 形如 `Mozilla/5.0 115Browser/<版本>`。OpenList 的做法是启动时打
/// `appversion.115.com` 取真实版本号(`drivers/115/appver.go`);本项目**固定一个版本号**,
/// 因为:① 多一次请求就多一次风控面;② 版本号只需像个客户端,不需要最新。
///
/// ⚠️ 这个值同时用于「取直链」和「播放」,两处必须完全一致 —— 直链的 `f` 参数会校验 UA(§4.3)。
enum Pan115UserAgent {
    static let value = "Mozilla/5.0 115Browser/35.6.0.3"
}
