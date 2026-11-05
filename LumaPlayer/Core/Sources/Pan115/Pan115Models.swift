import Foundation

/// 扫码换 Cookie 时绑定的客户端渠道(`docs/PAN115_API.md` §2.1 / §2.2 第 4 步)。
///
/// 115 按 `ssoent`(UID 中段)给 Cookie 分组:**同一次渠道内的最近一次登录会踢掉该渠道下其它 Cookie**。
/// 所以 App 要用一个用户日常不碰的渠道,才能和常用的 Web 端(`web`/A1)共存。
/// `tv` 是 AList 115 驱动的官方推荐值;`os_*` / `windows` / `mac` / `linux` 的客户端已下架且
/// 走另一套 ECDH P-224 加密(§2.1 / §4.2),⛔ 不列进来。
///
/// ⚠️ 只有**第 4 步**(换 Cookie)带这个值;二维码 token / 图片 / 状态轮询仍走 `web`
/// (AList 官方脚本与 p115client 都这样,§2.2)。
enum Pan115AuthorizationApp: String, Sendable {
    case tv = "tv"
    case wechatmini = "wechatmini"
    case alipaymini = "alipaymini"
    case qandroid = "qandroid"

    /// 扫码默认渠道。⛔ 不要改回 `web`:它和用户常用的浏览器 Web 端同一个 `ssoent`,会互踢。
    static let `default`: Pan115AuthorizationApp = .tv

    var ssoent: String {
        switch self {
        case .tv: return "I1"
        case .wechatmini: return "R1"
        case .alipaymini: return "R2"
        case .qandroid: return "M1"
        }
    }

    /// 按 `ssoent` 反查渠道名,给设置页显示**已存凭据**用。
    /// `A1` 是本项目改用 `tv` 之前留下的老 Cookie(与浏览器 Web 端同组),单独标出来提醒。
    /// - Returns: nil = 认不出的 ssoent,⛔ 不猜。
    static func displayName(forSSOEnt ssoent: String) -> String? {
        if let app = allApps.first(where: { $0.ssoent == ssoent }) { return app.displayName }
        if ssoent == "A1" { return "网页端(旧登录)" }
        return nil
    }

    private static let allApps: [Pan115AuthorizationApp] = [.tv, .wechatmini, .alipaymini, .qandroid]

    /// 渠道在 UI 上的名字。⛔ 不写「设备」—— 这是渠道分组,不是物理机器。
    var displayName: String {
        switch self {
        case .tv: return "电视端"
        case .wechatmini: return "微信小程序"
        case .alipaymini: return "支付宝小程序"
        case .qandroid: return "115 管理安卓端"
        }
    }
}

/// 115 网盘的凭据:Cookie 四件套(`docs/PAN115_API.md` §2)。
///
/// `UID` 不是纯数字,是 `user_id_ssoent_timestamp` 三段拼接,中间的 `ssoent` 决定 115 把请求当成哪个客户端
/// (§2.1)。本项目按 `Pan115AuthorizationApp` 绑定渠道。
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

    /// `UID` 中段 = `ssoent`,决定这份 Cookie 属于哪个渠道(§2.1)。
    /// `p115client type.py` 的 `P115UID` 按 `user_id_ssoent_timestamp` 正好拆三段;
    /// 其它形状返回 nil —— ⛔ 不猜,设置页就只显示「无法识别」。
    var ssoent: String? {
        let parts = uid.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let middle = String(parts[1])
        return middle.isEmpty ? nil : middle
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

/// 列目录的一页(`GET webapi.115.com/files`,§3)。
///
/// `count` 是**该目录的总条目数**,所以这一页能精确回答「还有没有下一页」——
/// 这是 115 与百度的关键差别(百度的 `list` 没有总数字段,只能靠「不满页」推断)。
struct Pan115DirectoryPage: Sendable, Equatable {
    let entries: [Pan115FileEntry]
    /// 服务端确认的偏移量。用它推进,⛔ 不自行累加步长(防 offset 越界静默回绕)
    let offset: Int
    /// 服务端有没有认我们请求的那个 offset。
    ///
    /// ⚠️ aps 接口的文档明写 offset 越界会「相当于 offset=0,从头开始」——
    /// 服务端**不报错**,只是悄悄从头数。不认的时候必须停,否则会无限循环。
    let isOffsetHonored: Bool
    /// 这一页请求的条数上限
    let limit: Int
    /// 目录总条目数。nil = 服务端没给,只能靠「不满页」推断还有没有
    let totalCount: Int?
    /// 还有没有下一页
    let hasMore: Bool

    /// 下一页的偏移量。
    ///
    /// ⚠️ 是 `offset + limit`(**服务端口径**),⛔ 不是 `offset + entries.count`:
    /// 解码时丢掉缺 `cid` 的条目会让 `entries.count` 少于服务端实际推进的条数,
    /// 用它推进会**漏项**。服务端按 `limit` 切页。
    var nextOffset: Int { offset + limit }

    init(
        entries: [Pan115FileEntry],
        offset: Int,
        isOffsetHonored: Bool,
        limit: Int,
        totalCount: Int?,
        hasMore: Bool
    ) {
        self.entries = entries
        self.offset = offset
        self.isOffsetHonored = isOffsetHonored
        self.limit = limit
        self.totalCount = totalCount
        self.hasMore = hasMore
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
    /// 删除时服务端回「文件已删除,请勿重复操作」(`231011`,§9)。
    /// 目标状态已经达到(别处删过 / 上一次其实生效了),按幂等成功处理,⛔ 不重试也不报错。
    case alreadyDeleted
    /// 本项目自己的参数检查,不是 115 的错误码:没有可用的 id 就不发请求。
    case invalidRequest(String)
    /// 直链过期或签名不符(§4.3),重取即可
    case linkExpired
    /// 被 115 频控挡下:`590075 操作太频繁`,或 403/405/429(阿里云 WAF)。
    ///
    /// `retryAfter` 是**本项目自己定的**冷却剩余秒数 —— 115 不告诉你多久恢复,只回一句
    /// 「请稍候再试」;实测恢复窗口在十几分钟到半小时之间(§6),所以这里按整轮冷却算。
    /// ⛔ 冷却期内不要再发请求:继续打会把临时频控升级成域名级风控(§6)。
    case rateLimited(retryAfter: TimeInterval)
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
            return "115 的登录已在别处失效(同一渠道内重复登录会顶掉旧 Cookie),请重新扫码登录。"
                + "想让 App 与网页端共存,退出登录再扫一次即可切到「\(Pan115AuthorizationApp.default.displayName)」渠道。"
        case .alreadyDeleted:
            return "这个文件已经不在 115 网盘里了。"
        case .invalidRequest(let detail):
            return "115 请求参数不完整:\(detail)"
        case .linkExpired:
            return "播放地址已过期,重新获取一次。"
        case .rateLimited(let retryAfter):
            let minutes = max(1, Int((retryAfter / 60).rounded(.up)))
            return "115 判断操作太频繁,已暂停请求。约 \(minutes) 分钟后再试,"
                + "期间不要反复点 —— 继续请求会延长风控时间。"
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
        // 「上一个删除 / 还原还没完」:115 的后台任务,不是频控。⛔ 别把它说成「操作太频繁」,
        // 否则用户以为要等半小时;实际几秒后重试就行(§9)。
        if Pan115Code.operationBusy.contains(code) {
            return "115 还在处理上一次删除或还原,请过几秒再试。"
        }
        let base: String
        switch code {
        case Pan115Code.alreadyDeleted:
            base = "这个文件已经不在网盘里了"
        case Pan115Code.notLoggedIn:
            base = "115 的登录已失效"
        case Pan115Code.kickedOut:
            base = "登录已在别处失效(同一渠道内重复登录)"
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
    /// 删除时「文件已删除,请勿重复操作」(§9 的 `231011`)。目标状态已达成,当成功。
    static let alreadyDeleted = 231011
    /// 删除 / 还原还在后台跑(`990009`),或账号有同类任务(`990005`)。
    ///
    /// ⚠️ 这不是频控(不进冷却):服务端只是说「上一个还没完」,重发也没用。
    /// 出处:`p115client client.py:349-356` 的响应原样。
    static let operationBusy: Set<Int> = [990005, 990009]
    /// 操作太频繁(`p115client` 把它归成 `EBUSY`)。这是风控的第一档,**比 WAF 早一步**:
    /// 认出来就该停手,继续打才会升级成域名级拦截(§6)。
    static let tooFrequent: Set<Int> = [590075, 40110000]
    /// `state: false` 且**没有错误码**时,靠文案认「登录已失效」(§3 的「请先登录」、
    /// §2.3 的 `990001` 文案)。只列文档里出现过的一手形状,认不出就原样带出,⛔ 不猜。
    static let notLoggedInMessages: [String] = ["请先登录", "请重新登录", "登录超时", "登陆超时"]
}

/// 115 的请求纪律(§6)。所有「多久算太频繁」的数字都在这里,⛔ 不要在调用点各写一套。
enum Pan115Policy {
    /// 扫码轮询的间隔。
    ///
    /// 官方说这接口是长轮询(状态不变时服务端会把请求挂住),但服务端提前返回时
    /// 客户端就会变成每秒两次的空转。这里给一个下限:不论请求多快返回,两次轮询之间至少隔这么久。
    static let authorizationPollInterval: Duration = .seconds(2)
    /// 命中频控后的整轮冷却。
    ///
    /// 115 不给恢复时间(社区实测十几分钟到半小时,§6),取上限再留余量。
    /// ⛔ 冷却期内一个请求都不发 —— 继续打会把临时频控升级成域名级 WAF 拦截。
    static let rateLimitCoolDown: Duration = .seconds(30 * 60)
    /// 取直链失败时最多自动补取几次。⛔ 只补一次,不循环。
    static let linkRetryLimit = 1
}
