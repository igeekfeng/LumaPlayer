import Foundation

/// 115 网盘的凭据:Cookie 四件套(`docs/PAN115_API.md` §2)。
///
/// `UID` 不是纯数字,是 `user_id_ssoent_timestamp` 三段拼接,中间的 `ssoent` 决定 115 把请求当成哪个客户端
/// (§2.1)。本项目只用 `web`(`A1`),因为 `os_mac` 那套走 ECDH P-224,而 CryptoKit 没有 P-224。
struct Pan115Credential: Codable, Sendable, Equatable {
    let uid: String
    let cid: String
    let seid: String
    /// 老 Cookie 可能没有,`115driver` 也不校验它(§2)。
    let kid: String?

    init(uid: String, cid: String, seid: String, kid: String?) {
        self.uid = uid
        self.cid = cid
        self.seid = seid
        self.kid = kid
    }

    /// 解析浏览器复制出来的 Cookie 串。`115driver` 的做法:按 `;` 切、key 转大写,
    /// **UID / CID / SEID 缺一即失败**(§2),KID 可缺。
    init?(cookieHeader: String) {
        var fields: [String: String] = [:]
        for pair in cookieHeader.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            let value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            fields[key] = value
        }
        guard let uid = fields["UID"], let cid = fields["CID"], let seid = fields["SEID"] else {
            return nil
        }
        self.init(uid: uid, cid: cid, seid: seid, kid: fields["KID"])
    }

    /// 发请求用的 `Cookie` 头。顺序与 `115driver pkg/driver/login.go:122-124` 一致。
    var cookieHeader: String {
        var parts = ["UID=\(uid)", "CID=\(cid)", "SEID=\(seid)"]
        if let kid, !kid.isEmpty { parts.append("KID=\(kid)") }
        return parts.joined(separator: "; ")
    }

    /// 扫码登录成功后 115 会把四件套放在 `data.cookie` 对象里(§2.2 第 4 步)。
    init?(cookieObject: [String: String]) {
        guard let uid = cookieObject["UID"],
              let cid = cookieObject["CID"],
              let seid = cookieObject["SEID"] else { return nil }
        self.init(uid: uid, cid: cid, seid: seid, kid: cookieObject["KID"])
    }
}

/// 扫码登录的会话(§2.2 第 1 步)。`uid` 与 Cookie 里的 `UID` 是两回事 —— 第 4 步的 `account` 用这个 `uid`。
struct Pan115QRCodeSession: Sendable, Equatable {
    let uid: String
    let time: Int
    let sign: String
    /// 要编进二维码的文本(`https://115.com/scan/…`),不是图片地址。
    let content: String

    /// 二维码有效期。**115 的 token 响应不给有效期**,两个参考实现(`115driver` / `p115client`)
    /// 也都没有这个常量 —— 这是本项目自己定的上限:超时就提示用户重新拿一张二维码,
    /// 而不是无限轮询(§6 限速,轮询本身也是请求)。
    /// ⛔ 不要按响应里的 `time` 推 —— 那是签发时刻,不是过期时刻。
    static let validitySeconds: TimeInterval = 120
}

/// 扫码状态(§2.2 第 3 步的 `status` 字段)。
enum Pan115QRCodeStatus: Sendable, Equatable {
    case waiting
    case scanned
    case allowed
    case expired
    case canceled
    /// 认不出的码原样带出,⛔ 不猜。
    case unknown(Int)

    init(raw: Int) {
        switch raw {
        case 0: self = .waiting
        case 1: self = .scanned
        case 2: self = .allowed
        case -1: self = .expired
        case -2: self = .canceled
        default: self = .unknown(raw)
        }
    }
}

/// 账号信息(`GET https://my.115.com/?ct=ajax&ac=nav`,`115driver pkg/driver/api.go` `ApiUserInfo`)。
struct Pan115Account: Sendable, Equatable {
    let userID: String?
    let userName: String?
    let isVip: Bool
}

/// 列表里的一条(§3)。字段名是 115 的缩写,⛔ 不要按直觉猜。
///
/// 转换到 `BaiduPanFile` 见 `file(path:)` —— 本项目把 `BaiduPanFile` 当作「文件树文件」的通用形状
/// (`LocalFolderListing` 也复用它),115 沿用同一个形状,浏览页才不用分派。
struct Pan115FileEntry: Sendable, Equatable {
    /// `fid`,空表示这是目录(§3)
    let fid: String
    let cid: String
    let name: String
    /// `s`,字节数。115 给的是字符串
    let size: String?
    /// `pc` = pick_code,取直链就靠它(§4.1)
    let pickCode: String?
    let sha1: String?
    /// `te`,unix 秒(`p115client tool/attr.py:245-246`)。⛔ 不是日期字符串。
    let modifiedAtSeconds: Int?
    /// `iv`(web)/ `isv`(app),`1` 表示是视频
    let isVideo: Bool

    var isDirectory: Bool { fid.isEmpty }

    /// `BaiduPanFile.fsID` 是 `UInt64`;115 的 `fid` 就是数字字符串。
    /// 目录的 `fid` 为空,用 `cid` 兜底 —— 目录条目自身在父目录里以 `cid` 标识。
    var numericID: UInt64? {
        let raw = isDirectory ? cid : fid
        return UInt64(raw)
    }

    /// - Parameter parentPath: 父目录在项目内的路径(`/` 起头),由调用方按浏览栈拼。
    func file(parentPath: String) -> BaiduPanFile? {
        guard let id = numericID else { return nil }
        return BaiduPanFile(
            fsID: id,
            path: parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)",
            name: name,
            sizeBytes: size.flatMap(UInt64.init),
            isDirectory: isDirectory,
            category: isVideo ? BaiduPanCategory.video : nil,
            modifiedAt: modifiedAtSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            thumbnailURL: nil
        )
    }
}

/// 115 源的失败,全部折成一句可解释的中文文案,与 `BaiduPanError` 同口径。
enum Pan115Error: Error, Equatable {
    /// 还没有 Cookie
    case notAuthorized
    /// Cookie 格式不对(UID / CID / SEID 缺一)
    case badCookie
    /// 二维码过期。两种表现都要认:轮询响应 `status: -1`,或 `state: 0` + `errno 40199002`(§2.2)
    case qrCodeExpired
    /// 用户在手机上取消了
    case qrCodeCanceled
    /// 扫码登录等不到结果
    case authorizationTimedOut
    /// 已经在扫码登录中(⛔ 不折成 `server`:那是 115 的错误码,这里没有码)
    case authorizationInProgress
    /// 业务错误(`state: false`)。`code` 是 115 的 `code` / `errno`。
    case server(code: Int, message: String?)
    /// 被踢下线(`40101035`,§2.3)
    case kickedOut
    /// 直链过期或签名不符(§4.3),重取即可
    case linkExpired
    /// 115 不给这个文件在线播(文案已带原因,⛔ 不折成 `server` —— 那会显示「返回了错误码 0」)
    case playbackUnsupported(String)
    /// 找不到这个文件的 pick_code(浏览目录时没缓存到,§3)
    case pickCodeMissing(String)
    /// 非 2xx / 连接失败 / 响应不是 JSON。⛔ 文本必须已过 `SecretRedactor`。
    case transport(String)
    /// ⛔ 不带响应体(可能有凭据)
    case decoding(endpoint: String, detail: String)
    /// m115 加解密失败(§5)
    case crypto(String)
    case cancelled

    var userMessage: String {
        switch self {
        case .notAuthorized:
            return "还没有登录 115 网盘。扫码登录后即可浏览你的网盘。"
        case .badCookie:
            return "115 的登录凭据不完整(缺少 UID / CID / SEID),请重新扫码登录。"
        case .qrCodeExpired:
            return "二维码已过期,请重新获取。"
        case .qrCodeCanceled:
            return "你在手机上取消了登录。"
        case .authorizationTimedOut:
            return "等待扫码超时,请重新获取二维码。"
        case .authorizationInProgress:
            return "已经在扫码登录中,请先完成或取消。"
        case .server(let code, let message):
            return Pan115Error.serverMessage(code: code, serverMessage: message)
        case .kickedOut:
            return "115 的登录已在别处失效(同一账号最多 2 台设备),请重新扫码登录。"
        case .linkExpired:
            return "播放地址已过期,重新获取一次。"
        case .playbackUnsupported(let detail):
            return detail
        case .pickCodeMissing(let detail):
            return "找不到这个文件的播放标识(\(detail)),请返回上一级目录再进来。"
        case .transport(let detail):
            return "连接 115 网盘失败:\(detail)"
        case .decoding(let endpoint, let detail):
            return "解析 115 网盘的响应失败(\(endpoint)):\(detail)"
        case .crypto(let detail):
            return "115 的加密数据处理失败:\(detail)"
        case .cancelled:
            return "已取消。"
        }
    }

    /// UI 据此决定给「重新登录」还是「重试」。
    var needsAuthorization: Bool {
        switch self {
        case .notAuthorized, .badCookie, .kickedOut, .qrCodeExpired, .qrCodeCanceled,
             .authorizationTimedOut:
            return true
        default:
            return false
        }
    }

    /// 目录读不出来时,「重试」没用(凭据问题,或目录已经不在了)。
    ///
    /// 115 把「目录不存在」当业务错误回(`state: 0` + `errno`),不像 HTTP 那样有 404:
    /// `800001`(`目录不存在`)、`10014`(`云端目录不存在`)、`20009`(`父目录不存在`)。
    /// 片库根被删 / 改名时就是这几个码,浏览页据此静默回落到网盘根,⛔ 不要停在一条错误页上。
    /// 出处:`p115client client.py:252`(10014)、`:266`(20009)、`:334`(800001)。
    var isDirectoryUnavailable: Bool {
        switch self {
        case .notAuthorized, .badCookie, .kickedOut:
            return true
        case .server(let code, _):
            return Pan115Code.directoryMissing.contains(code)
        default:
            return false
        }
    }

    static func serverMessage(code: Int, serverMessage: String?) -> String {
        let base: String
        switch code {
        case Pan115Code.notLoggedIn:
            base = "115 的登录已失效"
        case Pan115Code.kickedOut:
            base = "登录已在别处失效(同一账号最多 2 台设备)"
        case Pan115Code.invalidSignature:
            base = "请求签名无效"
        default:
            base = "115 网盘返回了错误码 \(code)"
        }
        guard let serverMessage, !serverMessage.isEmpty else { return "\(base)。" }
        return "\(base):\(serverMessage)"
    }
}

/// 115 的错误码。只列本项目会处置的;表外的码原样带出,⛔ 不编猜测文案。
///
/// 来源:`115driver pkg/driver/` 与 `p115client` 里各处 `errno` / `code` 判断。
enum Pan115Code {
    /// 未登录 / 登录超时(`errNo` / `errno`)
    static let notLoggedIn = 990001
    /// 被多设备登录管理踢下线(§2.3)
    static let kickedOut = 40101035
    /// 签名 / 参数错误
    static let invalidSignature = 40101017
    /// 二维码过期(`115driver pkg/driver/error.go:121`)。⚠️ 这是 `state: 0` + 错误码的形式,
    /// 不是 `status: -1` —— 两个都要认,见 `Pan115APIClient.validate`。
    static let qrCodeExpired = 40199002
    /// 「目录不存在」的三个码。片库根被删 / 改名时 115 就回这几个(没有 HTTP 404)。
    /// 出处:`p115client client.py:252`、`:266`、`:334`。
    static let directoryMissing: Set<Int> = [800001, 10014, 20009]
}
