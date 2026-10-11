import Foundation

/// 百度网盘用到的端点(`docs/BAIDU_PAN_API.md` §1 - §2)。
///
/// ⛔ 与 `EmbyEndpoint` 是两个东西,不得混用(CLAUDE.md 硬规则 1 的同一条:
/// 端点、参数名一律以文档为准,不得发明)。路径与参数名逐个对着
/// `docs/BAIDU_PAN_API.md` 抄,响应字段在官方页 / 实测核实过。
///
/// ## 两个主机
///
/// - `openapi.baidu.com` —— OAuth(设备码 / 换 token / 刷新);
/// - `pan.baidu.com` —— 网盘业务接口(用户信息 / 列表 / 元信息 / 播放流)。
///
/// ## 认证放哪
///
/// 与 Emby**相反**:百度把 `access_token` 放在查询串上,不放请求头。
/// 唯一要自己挂的头是 `User-Agent`(列表/下载要 `pan.baidu.com`,
/// 播放流要 `xpanvideo;...`,见 §1)。
enum BaiduPanEndpoint: Sendable, Equatable {

    // MARK: - OAuth(openapi.baidu.com)

    /// `GET /oauth/2.0/device/code?response_type=device_code&client_id=&scope=basic,netdisk`
    case deviceCode(clientID: String, scope: String)
    /// `GET /oauth/2.0/token?grant_type=device_token&code=&client_id=&client_secret=`
    case deviceToken(deviceCode: String, clientID: String, clientSecret: String)
    /// `GET /oauth/2.0/token?grant_type=refresh_token&refresh_token=&client_id=&client_secret=`
    case refreshToken(refreshToken: String, clientID: String, clientSecret: String)

    // MARK: - 网盘(pan.baidu.com)

    /// `GET /rest/2.0/xpan/nas?method=uinfo&vip_version=v2`
    case userInfo(accessToken: String)
    /// `GET /rest/2.0/xpan/file?method=list&dir=&start=&limit=&order=name`
    case fileList(accessToken: String, directory: String, start: Int, limit: Int)
    /// `GET /rest/2.0/xpan/multimedia?method=filemetas&fsids=[fs_id,...]&dlink=1&needmedia=1&thumb=1`
    ///
    /// ⚠️ **不是** `/xpan/file?method=meta` —— 那是文档 §2.2 写的路,但 2026-10-10
    /// 用真实应用实测:`method=meta&dlink=1` 的响应**既没有 `errno`、也没有 `dlink`**,
    /// 条目里只有路径/大小/`md5` 一类的静态属性。
    /// 给 `dlink` 的是 `multimedia` 这条(响应带 `errno`,条目带 `dlink` 与 `duration`)。
    /// ⇒ 播放入口一律走这里;`method=meta` 本项目不再使用。
    ///
    /// `fsids` 本来就是**数组**(单文件是 `N = 1` 的特例)。批量不是为了好看:
    /// 未审核应用的配额是 10 次/小时,逐个文件取封面会瞬间把配额烧光 ——
    /// 一个目录一次请求是这个功能能不能用的前提。
    case fileMeta(accessToken: String, fsIDs: [UInt64])
    /// `GET /rest/2.0/xpan/file?method=streaming&path=&type=[&nom3u8=1][&adToken=]`。
    ///
    /// - Parameter probeOnly: `nom3u8=1` —— 只要 JSON 状态,不要 m3u8 文本。
    ///   起播前用它探一次,把 `133`(要看广告)/ `-6`(token 失效)/
    ///   `31347`(片子太长)在**建流之前**问出来(`BAIDU_PAN_API.md` §2.3)。
    /// - Parameter adToken: `errno=133` 时把响应里的 `adToken` **整体编码**后带回重试(§5)。
    case streaming(
        accessToken: String,
        path: String,
        type: BaiduPanStreamType,
        probeOnly: Bool,
        adToken: String?
    )

    // MARK: - 形状

    var host: String {
        switch self {
        case .deviceCode, .deviceToken, .refreshToken:
            return "openapi.baidu.com"
        case .userInfo, .fileList, .fileMeta, .streaming:
            return "pan.baidu.com"
        }
    }

    /// 不含 host 的路径
    var path: String {
        switch self {
        case .deviceCode: return "/oauth/2.0/device/code"
        case .deviceToken, .refreshToken: return "/oauth/2.0/token"
        case .userInfo: return "/rest/2.0/xpan/nas"
        case .fileList, .streaming: return "/rest/2.0/xpan/file"
        case .fileMeta: return "/rest/2.0/xpan/multimedia"
        }
    }

    var method: String { "GET" }

    /// 诊断用端点名。**不含任何凭据**,可安全进日志(CLAUDE.md「安全与隐私」)。
    var name: String {
        switch self {
        case .deviceCode: return "oauth/device/code"
        case .deviceToken: return "oauth/token(device_code)"
        case .refreshToken: return "oauth/token(refresh_token)"
        case .userInfo: return "xpan/nas?method=uinfo"
        case .fileList: return "xpan/file?method=list"
        case .fileMeta: return "xpan/multimedia?method=filemetas"
        case .streaming: return "xpan/file?method=streaming"
        }
    }

    /// 查询参数。顺序固定(便于断言与排障),值一律整体 URL 编码。
    var queryItems: [(name: String, value: String)] {
        switch self {
        case .deviceCode(let clientID, let scope):
            return [
                ("response_type", "device_code"),
                ("client_id", clientID),
                ("scope", scope),
            ]
        case .deviceToken(let deviceCode, let clientID, let clientSecret):
            return [
                ("grant_type", "device_token"),
                ("code", deviceCode),
                ("client_id", clientID),
                ("client_secret", clientSecret),
            ]
        case .refreshToken(let refreshToken, let clientID, let clientSecret):
            return [
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken),
                ("client_id", clientID),
                ("client_secret", clientSecret),
            ]
        case .userInfo(let accessToken):
            // `vip_version=v2`:`vip_type` 才是 0/1/2 三档(§4)
            return [
                ("method", "uinfo"),
                ("access_token", accessToken),
                ("vip_version", "v2"),
            ]
        case .fileList(let accessToken, let directory, let start, let limit):
            // `order=name`:文档明确「排序按字符串处理,有剧集排序需求需自行开发」
            // —— 那就别指望它,列表在客户端自己按名字排。
            // 不传 `web`(就不给缩略图与 `dir_empty`)—— 本项目不接缩略图。
            return [
                ("method", "list"),
                ("access_token", accessToken),
                ("dir", directory),
                ("order", "name"),
                ("start", String(start)),
                ("limit", String(limit)),
            ]
        case .fileMeta(let accessToken, let fsIDs):
            // `fsids` 是 **JSON 数组的字面量**(`[123]`),整段编码后送 ——
            // 实测 `fsids=%5B1106099239747639%5D` 可用(2026-10-10)。
            // ⚠️ 用 `fs_id` 而不是 `path`:同一份文件改过名 / 挪过位置后 path 会变,
            // 而 `fs_id` 不变,列表里本来就带着它。
            return [
                ("method", "filemetas"),
                ("access_token", accessToken),
                ("fsids", "[\(fsIDs.map(String.init).joined(separator: ","))]"),
                ("dlink", "1"),
                // `needmedia=1` 时条目里才有 `duration`(实测有,秒)
                ("needmedia", "1"),
                ("thumb", "1"),
            ]
        case .streaming(let accessToken, let path, let type, let probeOnly, let adToken):
            var items: [(name: String, value: String)] = [
                ("method", "streaming"),
                ("access_token", accessToken),
                ("path", path),
                ("type", type.rawValue),
            ]
            if probeOnly { items.append(("nom3u8", "1")) }
            if let adToken { items.append(("adToken", adToken)) }
            return items
        }
    }

    /// 要自己挂的请求头。
    ///
    /// ⚠️ **全部**请求都要 `User-Agent: pan.baidu.com` —— 这是 2026-10-10 在
    /// 官方「设备码模式授权」页逐个 curl 示例上核实的(OAuth 三个请求的示例
    /// 都带这个头)。§1 另外说明:下载侧不给它会撞 `31326 防盗链`。
    /// 唯一例外是**播放流**,它要的是 `xpanvideo;…`,⛔ 两者不能互换。
    var headers: [String: String] {
        switch self {
        case .deviceCode, .deviceToken, .refreshToken, .userInfo, .fileList, .fileMeta:
            return ["User-Agent": BaiduPanUserAgent.download]
        case .streaming:
            return ["User-Agent": BaiduPanUserAgent.streaming]
        }
    }

    /// 拼好的绝对地址。
    ///
    /// ⚠️ 查询串是**手拼**的,不走 `URLComponents.queryItems`:
    /// 后者按 RFC 3986 只编码非法字符,`/` 是查询串里的合法字符会被原样留下,
    /// 而百度要求 `path` / `dir` **整体**编码(`/apps/x` → `%2Fapps%2Fx`)。
    /// 这里用只保留 unreserved 字符的允许集,与官方 cURL 示例的
    /// `--data-urlencode` 同一口径。
    var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.percentEncodedQuery = encodedQuery
        return components.url
    }

    /// 手拼的查询串(POSIX 编码:`/` → `%2F`)
    var encodedQuery: String {
        queryItems.compactMap { item -> String? in
            guard let name = Self.encode(item.name), let value = Self.encode(item.value) else {
                return nil
            }
            return "\(name)=\(value)"
        }
        .joined(separator: "&")
    }

    /// 只保留 unreserved 字符(`A-Za-z0-9-._~`)。
    /// 空格按 `%20` 而不是 `+` —— 百度那边两种都收,但 `%20` 是无歧义的那个。
    static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

/// 播放流要的 `type`(`BAIDU_PAN_API.md` §2.3 的取值表)。
///
/// ⛔ 只用**通用 HLS**那一档。`M3U8_FLV_264_*` 与 `M3U8_MP3_128` 是私有协议,
/// 需要网盘自家播放器才放得动 —— 列在这里只为把「为什么不给那些选项」
/// 写清楚,不是备用方案。
enum BaiduPanStreamType: String, Sendable, Equatable {
    /// `ts` 分片,480p
    case auto480 = "M3U8_AUTO_480"
    /// `ts` 分片,720p
    case auto720 = "M3U8_AUTO_720"
    /// `ts` 分片,1080p(按原片自动封顶)
    case auto1080 = "M3U8_AUTO_1080"
    /// 音频 HLS
    case audioHLSPM3 = "M3U8_HLS_MP3_128"

    /// 视频按 1080p 请求:百度会按原片自动封顶,不会把 720p 顶上 1080p(§2.3)。
    static let video = BaiduPanStreamType.auto1080
    /// 音频:只有 `M3U8_HLS_MP3_128` 是通用 HLS
    static let audio = BaiduPanStreamType.audioHLSPM3
}

/// 百度要的 `User-Agent` 字面量。
///
/// §1 给的形式:`xpanvideo;<appName>;<appVersion>;<sysName>;<sysVersion>;ts`。
/// ⚠️ 官方「播单下音频播放」页的 cURL 示例给的是简写 `xpanvideo;netdisk;client`,
/// 两处都出自官方站点。这里按 §1 的分段形式给全,并且**集中在一处** ——
/// 真机联调若发现要换形式,只改这里。
enum BaiduPanUserAgent {
    /// 播放流(§1)
    static var streaming: String {
        "xpanvideo;\(appName);\(appVersion);\(systemName);\(systemVersion);ts"
    }

    /// 列表 / 元信息 / 下载(§1:不给这个 UA 会撞 `31326` 防盗链)
    static let download = "pan.baidu.com"

    private static var appName: String { "LumaPlayer" }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private static var systemName: String { "macOS" }

    private static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}
