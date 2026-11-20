import CryptoKit
import Foundation

/// 夸克网盘的凭据(`docs/QUARK_API.md` §4)。
///
/// 四件套全部属于**一个账号**,全 App 一份(与 115 的 Cookie 同性质):
/// - `accessToken` / `refreshToken`:业务接口凭据;`refresh_token` 每次刷新都会被轮换,新值必须落盘(§3);
/// - `deviceID`:参与 `req_id` 与 token 刷新,**必须持久化** —— 换了就要重新扫码(§1);
/// - `queryToken`:扫码会话的中间态,换到 `refresh_token` 之后就只作诊断用。
///
/// ⛔ 不进 `UserDefaults`、日志、诊断文件;只进 `CredentialStore`(走凭据文件通道)。
struct QuarkCredential: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var deviceID: String
    /// 扫码阶段拿到的 `query_token`,刷新后仍保留(不参与业务请求)
    var queryToken: String

    init(accessToken: String, refreshToken: String, deviceID: String, queryToken: String = "") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.deviceID = deviceID
        self.queryToken = queryToken
    }
}

/// 扫码登录的第 1 步结果(`docs/QUARK_API.md` §4 第 1 步)。
///
/// ⚠️ `qrData` 是**图片本身**(base64 编码的 PNG),不是要编进二维码的文本 —— 页面上直接显示它。
struct QuarkQRCodeSession: Sendable, Equatable {
    /// base64 PNG(不带 `data:` 前缀)
    let imageBase64: String
    /// 第 3 步要的 `query_token`
    let queryToken: String

    /// 二维码有效期未知(§8)。这是**本项目自己定的**上限:超时提示换一张,
    /// 而不是无限轮询 —— 每次轮询都是一次请求(§10 的频控口径)。
    /// ⛔ 不要从响应里推:服务端不给有效期。
    static let validitySeconds: TimeInterval = 180
}

/// 账号信息(`GET /user?method=user_info`,`docs/QUARK_API.md` §7)。
///
/// 只用于「登录态是否有效」与设置页展示;TV 端不给昵称以外的资料,缺就是缺。
struct QuarkAccount: Sendable, Equatable {
    let nickname: String?
    let isVip: Bool
}

/// 列目录的一页(`docs/QUARK_API.md` §5)。
///
/// ⚠️ 与百度 / 115 都不同:夸克**给了目录总数**(`total_count`),所以「还有没有下一页」
/// 可以精确判断;但页脚兜底仍按「本页为空即到底」,防止总数异常时死循环。
struct QuarkDirectoryPage: Sendable, Equatable {
    let files: [QuarkFileEntry]
    /// 服务端认的 `page_index`。⚠️ 用它 +1 推进,⛔ 不按已解码条数推进(§5)
    let pageIndex: Int
    let pageSize: Int
    /// 目录总条目数。nil = 响应里没给
    let totalCount: Int?
    /// 还有没有下一页
    let hasMore: Bool

    /// 下一页的 `page_index`。服务端按 `page_size` 切页,所以推进量是条数而不是解码后的条数。
    var nextPageIndex: Int { pageIndex + 1 }
}

/// 一条可播放的直链(`/file?method=download`,`docs/QUARK_API.md` §6.1)。
///
/// ⚠️ 地址**原样**交给内核,⛔ 不经 `PlaybackURLBuilder`、⛔ 不做 `URLComponents` 往返
/// (会改签名参数,与百度 / 115 同一个坑)。
struct QuarkDownloadLink: Sendable, Equatable {
    let url: URL
    /// 取链时响应给的 `size`。只作展示 / 诊断,不当 Content-Length 承诺
    let sizeBytes: UInt64?
    /// 给内核的请求头。TV 端 CDN 直链是自带签名的地址,参考实现都不挂头(§6.1),
    /// 所以这里是**空的**;真撞 403 再加,⛔ 不预先塞一堆头。
    let headers: [String: String]
}

/// 夸克源的失败,全部折成一句可解释的中文文案,与 `BaiduPanError` / `Pan115Error` 同口径。
enum QuarkError: Error, Equatable {
    /// 还没有登录
    case notAuthorized
    /// 用户在手机上取消了 / 二维码被作废
    case qrCodeExpired
    /// 扫码登录等不到结果(本项目自己的超时,§8)
    case authorizationTimedOut
    /// 已经在扫码登录中
    case authorizationInProgress
    /// 业务错误。`code` 是夸克的 `errno`(`status >= 400` 时用 HTTP 状态码)
    case server(code: Int, message: String?)
    /// 换 token 的第三方服务受理失败(外层 `code != 200`,§4 第 4 步)
    case tokenExchange(code: Int, message: String?)
    /// 授权码无效(`data.errno = 11004`):⛔ 不重试同一个 code,只能重新扫码(§8)
    case authorizationCodeInvalid
    /// `refresh_token` 也失效(`data.errno = 11000`):只能重新扫码
    case refreshTokenInvalid
    /// 本项目自己的参数检查,不是夸克的错误码
    case invalidRequest(String)
    /// 网盘里找不到这个路径(片库根被删 / 改名)。TV 端只给 fid 树,
    /// 「这一层不存在」只能在按路径解析时才发现,⛔ 不编服务端错误码。
    case directoryNotFound(path: String)
    /// 这个文件拿不到播放地址(文案已带原因)
    case playbackUnsupported(String)
    /// 非 2xx / 连接失败 / 响应不是 JSON。⛔ 文本必须已过 `SecretRedactor`
    case transport(String)
    /// ⛔ 不带响应体(可能有凭据)
    case decoding(endpoint: String, detail: String)
    /// 请求频率被服务端挡下(§10)。`retryAfter` 是**本项目自己定的**冷却秒数
    case rateLimited(retryAfter: TimeInterval)
    case cancelled

    var userMessage: String {
        switch self {
        case .notAuthorized:
            return "还没有登录夸克网盘。扫码登录后即可浏览你的网盘。"
        case .qrCodeExpired:
            return "二维码已过期,请重新获取。"
        case .authorizationTimedOut:
            return "等待扫码超时,请重新获取二维码。"
        case .authorizationInProgress:
            return "已经在扫码登录中,请先完成或取消。"
        case .server(let code, let message):
            return QuarkError.serverMessage(code: code, serverMessage: message)
        case .tokenExchange(let code, let message):
            let base = "换登录凭据失败(第三方服务返回 \(code))"
            guard let message, !message.isEmpty else { return "\(base)。" }
            return "\(base):\(message)"
        case .authorizationCodeInvalid:
            return "这次的授权码已经无效,请重新扫码。"
        case .refreshTokenInvalid:
            return "夸克的登录凭据已失效(刷新令牌也过期了),请重新扫码登录。"
        case .invalidRequest(let detail):
            return "夸克请求参数不完整:\(detail)"
        case .directoryNotFound(let path):
            return "网盘里找不到「\(path)」这个目录,它可能已被删除或改名。"
        case .playbackUnsupported(let detail):
            return detail
        case .transport(let detail):
            return "连接夸克网盘失败:\(detail)"
        case .decoding(let endpoint, let detail):
            return "解析夸克网盘的响应失败(\(endpoint)):\(detail)"
        case .rateLimited(let retryAfter):
            let minutes = max(1, Int((retryAfter / 60).rounded(.up)))
            return "夸克判断请求太频繁,已暂停请求。约 \(minutes) 分钟后再试,期间不要反复点。"
        case .cancelled:
            return "已取消。"
        }
    }

    /// UI 据此决定给「重新登录」还是「重试」。
    var needsAuthorization: Bool {
        switch self {
        case .notAuthorized, .qrCodeExpired, .authorizationTimedOut, .authorizationCodeInvalid,
             .refreshTokenInvalid:
            return true
        default:
            return false
        }
    }

    /// 目录读不出来时「重试」有没有用。夸克把「目录不存在」当业务错误回,不像 HTTP 那样有 404。
    ///
    /// ⚠️ 只认「按路径解析时确实没找到」这一种:TV 端没有公开的「目录不存在」错误码样本,
    /// ⛔ 不拿猜测的错误码集合去判(与 115 那套「有实测样本的码表」不同)。
    var isDirectoryUnavailable: Bool {
        if case .directoryNotFound = self { return true }
        return false
    }

    static func serverMessage(code: Int, serverMessage: String?) -> String {
        let base: String
        switch code {
        case QuarkCode.tokenInvalid, QuarkCode.signatureInvalid:
            base = "夸克的登录凭据已失效"
        case QuarkCode.parameterInvalid:
            base = "请求参数不被接受"
        default:
            base = "夸克网盘返回了错误码 \(code)"
        }
        guard let serverMessage, !serverMessage.isEmpty else { return "\(base)。" }
        return "\(base):\(serverMessage)"
    }
}

/// 夸克的错误码。只列本项目会处置的;**表外的码原样带出**,⛔ 不编猜测文案。
///
/// 全部是 2026-11-20 用无凭据请求实测到的响应原话(`docs/QUARK_API.md` §8),不是从别处抄的:
/// - `10001` = `签名验证失败，禁止访问` / `公参缺失…`(**注意:与 OpenList 注释里「access_token 过期」的推断相反**)
/// - `11001` = `Access Token无效`(业务请求带无效 token 时)
/// - `11002` = `授权码Code二维码过期`(`/oauth/code` 的 query_token 失效)
/// - `11003` = `用户未确认授权`(`/oauth/code` 的**正常等待态**,不是失败)
/// - `11004` = `授权码Code无效`(换 token 时 code 不可用)
/// - `11000` = `Refresh Token无效`(换 token 时 refresh_token 不可用)
enum QuarkCode {
    /// 签名 / 公共参数被拒。⚠️ 这一点**与 OpenList 的推断相反**,不能当成「token 过期」去刷新。
    static let signatureInvalid = 10001
    /// access_token 无效 —— 这才是要刷新的那一档
    static let tokenInvalid = 11001
    /// 二维码 / `query_token` 已过期
    static let qrCodeExpired = 11002
    /// 用户还没在手机上确认(轮询的「继续等」态)
    static let authorizationPending = 11003
    /// 授权码不可用
    static let authorizationCodeInvalid = 11004
    /// 刷新令牌不可用
    static let refreshTokenInvalid = 11000
    /// 参数错误(`参数错误: [access_token不能为空]`)
    static let parameterInvalid = 14001
}

/// 夸克的请求纪律(`docs/QUARK_API.md` §5、§10)。所有数字都在这里,⛔ 不要在调用点各写一套。
enum QuarkPolicy {
    /// 列目录一页多少条。参考实现都用 100(§5),不调大:夸克没有配额说明,保守取值。
    static let pageSize = 100
    /// 串行、两次请求之间的最小间隔。
    ///
    /// 两份参考实现都没有退避逻辑,本项目仍按「串行 + 至少 500ms」处理(§5),
    /// 与 `docs/PAN115_API.md` §6 同口径。⛔ 不做并发批量请求、不做后台预取。
    static let minimumRequestInterval: Duration = .milliseconds(500)
    /// 扫码轮询间隔。参考实现每 2 秒问一次(`docs/QUARK_API.md` §4 第 2 步)。
    static let authorizationPollInterval: Duration = .seconds(2)
    /// 命中频控后的整轮冷却。夸克不告诉恢复时间,按 30 分钟算(与 115 同量级,§10)
    static let rateLimitCoolDown: Duration = .seconds(30 * 60)
    /// 抓到「token 无效」后最多自动刷新几次。⛔ 只刷一次,不循环(§3)
    static let refreshRetryLimit = 1
}

/// 列表里的一条(`docs/QUARK_API.md` §5.1)。
///
/// ⚠️ `fid` 是**字符串**(夸克的 id 形如 32 位 hex,不是数字),而「文件树来源」的通用形状
/// `BaiduPanFile.fsID` 是 `UInt64`。所以条目 id 由**虚拟路径**派生(见 `QuarkPath`):
/// 整个项目的续播 / 隐藏 / 刮削缓存 / 弹幕键都按路径串起来,TV 端恰恰不给路径(§5.1),
/// 由 `QuarkConnection` 按 fid 树现拼一份 —— 这样上层一行都不用改。
struct QuarkFileEntry: Sendable, Equatable {
    /// 文件 / 目录 ID,取直链与进子目录都用它
    let fid: String
    let parentFid: String
    let name: String
    /// 字节;目录为 0 / nil
    let sizeBytes: Int64?
    let isDirectory: Bool
    /// `1` = 视频
    let category: Int?
    /// 时长(秒)。⚠️ 单位未实测,⛔ 不用来显示
    let durationSeconds: Double?
    /// 修改时间(服务端给毫秒,解码时已换算)
    let modifiedAt: Date?
    let createdAt: Date?
    /// 缩略图。⚠️ 临时签名地址,不落盘、不当封面用(封面走 TMDB 刮削)
    let thumbnailURL: URL?

    var isVideo: Bool { category == QuarkCategory.video }

    /// - Parameter parentPath: 父目录在项目内的虚拟路径(`/` 起头)
    func file(parentPath: String, sourceID: UUID) -> BaiduPanFile {
        let path = QuarkPath.child(name, of: parentPath)
        return BaiduPanFile(
            fsID: QuarkPath.fileID(sourceID: sourceID, path: path),
            path: path,
            name: name,
            sizeBytes: sizeBytes.map { UInt64(max(0, $0)) },
            isDirectory: isDirectory,
            category: isVideo ? BaiduPanCategory.video : nil,
            modifiedAt: modifiedAt,
            thumbnailURL: nil
        )
    }
}

/// `category` 取值里本项目只用到的那个(§5.1)
enum QuarkCategory {
    static let video = 1
}

/// 夸克源的虚拟路径(`docs/QUARK_API.md` §5.1:TV 端只给 fid 树,不提供路径)。
///
/// 造法与本地文件夹同一套路:条目在来源内的 id = SHA-256(来源 id + 虚拟路径) 前 8 字节。
/// 代价也一样 —— 网盘里改名 / 挪目录后 id 会变,旧的续播记录与刮削缓存跟不过去
/// (与本地文件夹共用同一条已知限制,见 `KNOWN_ISSUES.md`)。
enum QuarkPath {
    /// 网盘根的虚拟路径。⚠️ 与 `QuarkEndpoint.rootFid`(`"0"`)是两回事:fid 走接口,路径走界面
    static let root = "/"

    /// `"/影视"` + `"电影"` → `"/影视/电影"`;父路径是根时不留双斜杠
    static func child(_ name: String, of parent: String) -> String {
        parent == root || parent.isEmpty ? "/" + name : parent + "/" + name
    }

    /// 去掉尾部斜杠、空串归成 `/`
    static func normalized(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? root : trimmed
    }

    static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? root : parent
    }

    /// 见类型注释。与 `LocalFolderListing.fileID` 同一个算法,两个来源的 id 空间互不相干。
    static func fileID(sourceID: UUID, path: String) -> UInt64 {
        let digest = SHA256.hash(data: Data("\(sourceID.uuidString)|quark|\(path)".utf8))
        return digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
