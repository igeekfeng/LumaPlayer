import CryptoKit
import Foundation

/// 夸克 TV 端用到的端点与常量(`docs/QUARK_API.md` §1 - §6)。⛔ 路径与参数名以该文档为准,不得发明。
///
/// 三套接口里只走 TV 端:只有它能给可直连的播放地址,网页 Cookie 版被限速、必须本地代理中转(§0)。
enum QuarkEndpoint: Sendable, Equatable {

    /// `GET /oauth/authorize`:拿二维码图片(base64 PNG)与 `query_token`(§4 第 1 步)
    case authorize
    /// `GET /oauth/code`:用 `query_token` 换授权码(§4 第 3 步)。
    /// ⚠️ 用户没确认时这里回 `errno 11003 用户未确认授权` —— 客户端要反复调它,没有独立的状态端点。
    case code(queryToken: String)
    /// `GET /user?method=user_info`(§7)
    case userInfo
    /// `GET /file?method=list`(§5)
    case list(parentFid: String, pageIndex: Int, pageSize: Int)
    /// `GET /file?method=download`(§6.1)
    case download(fid: String)

    /// 业务主机。签名常量与设备指纹都来自开源实现的硬编码值(§1),随客户端版本更新可能失效。
    static let apiHost = "open-api-drive.quark.cn"

    /// 换 token 的主机。
    ///
    /// ⚠️ 文档记录的是 `http://api.extscreen.com/quarkdrive`(第三方、明文,§1)。本项目**用 https**:
    /// 同一主机同一个 `/token` 在 https 下返回完全一致的响应(2026-11-20 实测,`errno 11004` / `11000` 都复现),
    /// 而明文 HTTP 会被 ATS 直接拦下、还得开全局例外。⛔ 不要改回 http。
    static let codeHost = "api.extscreen.com"
    static let codeBasePath = "/quarkdrive"

    static let clientID = "d3194e61504e493eb6222857bccfed94"
    static let signKey = "kw2dvtd7p4t3pjl2d9ed9yc8yej8kw2d"
    static let appVer = "1.8.2.2"
    static let channel = "GENERAL"

    /// 网盘根目录的 `fid`(§1)
    static let rootFid = "0"

    var host: String { Self.apiHost }

    var path: String {
        switch self {
        case .authorize: return "/oauth/authorize"
        case .code: return "/oauth/code"
        case .userInfo: return "/user"
        case .list, .download: return "/file"
        }
    }

    var method: String { "GET" }

    /// 端点自己的查询参数(不含通用设备参数,那些由 `QuarkSignedRequest` 补)。
    /// 顺序固定,便于测试断言。
    var queryItems: [(name: String, value: String)] {
        switch self {
        case .authorize:
            return [
                ("auth_type", "code"),
                ("client_id", Self.clientID),
                ("scope", "netdisk"),
                ("qrcode", "1"),
                ("qr_width", "460"),
                ("qr_height", "460"),
            ]
        case .code(let queryToken):
            return [
                ("client_id", Self.clientID),
                ("scope", "netdisk"),
                ("query_token", queryToken),
            ]
        case .userInfo:
            return [("method", "user_info")]
        case .list(let parentFid, let pageIndex, let pageSize):
            // 排序与过滤都按 OpenList 的取值固定:这一层不需要客户端排序,
            // 浏览页自己按目录在前、名字自然序排(见 `QuarkSourceProvider`)。
            return [
                ("method", "list"),
                ("parent_fid", parentFid),
                ("order_by", "3"),
                ("desc", "1"),
                ("category", ""),
                ("source", ""),
                ("ex_source", ""),
                ("list_all", "0"),
                ("page_size", String(pageSize)),
                ("page_index", String(pageIndex)),
            ]
        case .download(let fid):
            return [
                ("method", "download"),
                ("group_by", "source"),
                ("fid", fid),
                ("resolution", "low,normal,high,super,2k,4k"),
                ("support", "dolby_vision"),
            ]
        }
    }

    /// 诊断用端点名,不含凭据,可进日志。
    var name: String {
        switch self {
        case .authorize: return "oauth/authorize"
        case .code: return "oauth/code"
        case .userInfo: return "user?method=user_info"
        case .list: return "file?method=list"
        case .download: return "file?method=download"
        }
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

/// 设备指纹(`docs/QUARK_API.md` §1)。
///
/// ⚠️ 服务端据此把请求认成「TV 客户端」,⛔ 不要改成 Mac Safari —— 改了签名可能照样过、
/// 但业务接口的行为无从预期。
enum QuarkDeviceFingerprint {
    static let userAgent = "Mozilla/5.0 (Linux; U; Android 13; zh-cn; "
        + "M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) "
        + "Mobile Safari/533.1"
    static let brand = "Xiaomi"
    static let platform = "tv"
    static let name = "M2004J7AC"
    static let model = "M2004J7AC"
    static let buildDevice = "M2004J7AC"
    static let buildProduct = "M2004J7AC"
    static let gpu = "Adreno (TM) 550"
    static let activityRect = "{}"

    /// 会被写进查询串与 token body 的通用字段(§1、§4 第 4 步)。
    /// 顺序固定:`req_id` 与 `access_token` 由调用方插在最前。
    static func queryItems(deviceID: String) -> [(name: String, value: String)] {
        [
            ("app_ver", QuarkEndpoint.appVer),
            ("device_id", deviceID),
            ("device_brand", brand),
            ("platform", platform),
            ("device_name", name),
            ("device_model", model),
            ("build_device", buildDevice),
            ("build_product", buildProduct),
            ("device_gpu", gpu),
            ("activity_rect", activityRect),
            ("channel", QuarkEndpoint.channel),
        ]
    }
}

/// 一个业务请求的签名三件套(`docs/QUARK_API.md` §2)。
struct QuarkSignature: Sendable, Equatable {
    /// 13 位毫秒时间戳,同时进请求头 `x-pan-tm`
    let timestamp: String
    /// `md5(deviceID + timestamp)`,进查询串 `req_id`
    let requestID: String
    /// `sha256(method + "&" + pathname + "&" + timestamp + "&" + signKey)`,进请求头 `x-pan-token`
    let panToken: String
}

enum QuarkSigner {

    /// - Parameters:
    ///   - method: 大写 HTTP 方法
    ///   - path: 不含查询串的路径(`/file`)
    ///
    /// ⚠️ sha256 的入参是**字符串拼接**,⛔ 不做 URL 编码、不加空格、不改大小写。
    static func sign(
        method: String,
        path: String,
        deviceID: String,
        signKey: String = QuarkEndpoint.signKey,
        milliseconds: Int64
    ) -> QuarkSignature {
        let timestamp = String(milliseconds)
        return QuarkSignature(
            timestamp: timestamp,
            requestID: md5Hex(deviceID + timestamp),
            panToken: sha256Hex("\(method)&\(path)&\(timestamp)&\(signKey)")
        )
    }

    static func nowMilliseconds(_ now: Date = Date()) -> Int64 {
        Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// 32 位小写 hex
    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 64 位小写 hex
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
