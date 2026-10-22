import Foundation

/// 百度网盘用到的端点(`docs/BAIDU_PAN_API.md` §1 - §2)。⛔ 路径与参数名以该文档为准,不得发明。
///
/// 两个主机:`openapi.baidu.com`(OAuth)、`pan.baidu.com`(网盘业务)。
/// 与 Emby 相反,`access_token` 放查询串;唯一要自己挂的头是 `User-Agent`(见 `headers`)。
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
    /// ⛔ 不用 `/xpan/file?method=meta`(文档 §2.2):实测它既不给 `errno` 也不给 `dlink`。
    /// 这条带 `errno`,条目带 `dlink` 与 `duration`。
    ///
    /// 一个目录一次批量请求是配额要求(§7)。
    case fileMeta(accessToken: String, fsIDs: [UInt64])
    /// `GET /rest/2.0/xpan/file?method=streaming&path=&type=[&nom3u8=1][&adToken=]`。
    ///
    /// - Parameter probeOnly: `nom3u8=1`,只要 JSON 状态。起播前探一次,在建流前问出
    ///   `133` / `-6` / `31347` 等错误(§2.3)。
    /// - Parameter adToken: `errno=133` 时把响应里的 `adToken` 整体编码后带回重试(§5)。
    case streaming(
        accessToken: String,
        path: String,
        type: BaiduPanStreamType,
        probeOnly: Bool,
        adToken: String?
    )

    /// `POST /rest/2.0/xpan/file?method=filemanager&access_token=&opera=delete`(§2.4)
    ///
    /// `filelist` 是路径字符串的 JSON 数组(单条也是数组)。`async=0`:异步拿不到逐条结果。
    case deleteFile(accessToken: String, path: String)

    /// `POST /rest/2.0/xpan/file?method=filemanager&access_token=&opera=rename`(§2.5)
    ///
    /// `filelist` 是对象数组 `{path, newname}`,只改最后一段名字。
    /// 一次送多条是配额要求(§7);⛔ 批次之间必须自底向上(§2.6),父目录改名后子项 `path` 立刻失效。
    case renameFiles(accessToken: String, operations: [BaiduPanRenameOperation])

    // MARK: - 形状

    var host: String {
        switch self {
        case .deviceCode, .deviceToken, .refreshToken:
            return "openapi.baidu.com"
        case .userInfo, .fileList, .fileMeta, .streaming, .deleteFile, .renameFiles:
            return "pan.baidu.com"
        }
    }

    var path: String {
        switch self {
        case .deviceCode: return "/oauth/2.0/device/code"
        case .deviceToken, .refreshToken: return "/oauth/2.0/token"
        case .userInfo: return "/rest/2.0/xpan/nas"
        case .fileList, .streaming, .deleteFile, .renameFiles: return "/rest/2.0/xpan/file"
        case .fileMeta: return "/rest/2.0/xpan/multimedia"
        }
    }

    var method: String {
        switch self {
        case .deleteFile, .renameFiles: return "POST"
        case .deviceCode, .deviceToken, .refreshToken,
             .userInfo, .fileList, .fileMeta, .streaming:
            return "GET"
        }
    }

    /// 诊断用端点名,不含凭据,可进日志。
    var name: String {
        switch self {
        case .deviceCode: return "oauth/device/code"
        case .deviceToken: return "oauth/token(device_code)"
        case .refreshToken: return "oauth/token(refresh_token)"
        case .userInfo: return "xpan/nas?method=uinfo"
        case .fileList: return "xpan/file?method=list"
        case .fileMeta: return "xpan/multimedia?method=filemetas"
        case .streaming: return "xpan/file?method=streaming"
        case .deleteFile: return "xpan/file?method=filemanager(opera=delete)"
        case .renameFiles: return "xpan/file?method=filemanager(opera=rename)"
        }
    }

    /// 顺序固定(便于断言与排障)。
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
            // 服务端按字符串排序,剧集顺序在客户端自己排。不传 `web`(不接缩略图)
            return [
                ("method", "list"),
                ("access_token", accessToken),
                ("dir", directory),
                ("order", "name"),
                ("start", String(start)),
                ("limit", String(limit)),
            ]
        case .fileMeta(let accessToken, let fsIDs):
            // `fsids` 是 JSON 数组字面量(`[123]`),整段编码。用 `fs_id` 不用 path:改名 / 挪动后 fs_id 不变
            return [
                ("method", "filemetas"),
                ("access_token", accessToken),
                ("fsids", "[\(fsIDs.map(String.init).joined(separator: ","))]"),
                ("dlink", "1"),
                // `needmedia=1` 时条目里才有 `duration`(秒)
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
        case .deleteFile(let accessToken, _):
            return [
                ("method", "filemanager"),
                ("access_token", accessToken),
                ("opera", "delete"),
            ]
        case .renameFiles(let accessToken, _):
            return [
                ("method", "filemanager"),
                ("access_token", accessToken),
                ("opera", "rename"),
            ]
        }
    }

    /// POST 的表单字段;nil = 没有 body。编码与查询串同口径(`Self.encode`)。
    /// ⛔ `access_token` 留在查询串上(§1),不挪进 body。
    var formFields: [(name: String, value: String)]? {
        switch self {
        case .deleteFile(_, let path):
            return [
                ("async", "0"),
                ("filelist", "[\"\(path)\"]"),
            ]
        case .renameFiles(_, let operations):
            let list = operations.map { operation in
                "{\"path\":\(Self.jsonString(operation.path)),"
                    + "\"newname\":\(Self.jsonString(operation.newName))}"
            }
            .joined(separator: ",")
            return [
                ("async", "0"),
                ("filelist", "[\(list)]"),
            ]
        case .deviceCode, .deviceToken, .refreshToken,
             .userInfo, .fileList, .fileMeta, .streaming:
            return nil
        }
    }

    /// JSON 字符串字面量(含两侧引号)。手写而非 `JSONEncoder`:`formFields` 不能 `throw`,
    /// 而路径 / 新名里常有 `"` 与 `\`,⛔ 不转义会让 `filelist` 变成非法 JSON。
    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
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
        switch self {
        case .deleteFile, .renameFiles: return "application/x-www-form-urlencoded"
        case .deviceCode, .deviceToken, .refreshToken,
             .userInfo, .fileList, .fileMeta, .streaming:
            return nil
        }
    }

    /// 包括 OAuth 在内全部请求都要 `User-Agent: pan.baidu.com`(下载侧不给会撞 `31326` 防盗链);
    /// 唯一例外是播放流要 `xpanvideo;…`,⛔ 两者不能互换(§1)。
    var headers: [String: String] {
        switch self {
        case .deviceCode, .deviceToken, .refreshToken, .userInfo, .fileList, .fileMeta,
             .deleteFile, .renameFiles:
            return ["User-Agent": BaiduPanUserAgent.download]
        case .streaming:
            return ["User-Agent": BaiduPanUserAgent.streaming]
        }
    }

    /// ⚠️ 查询串手拼,不走 `URLComponents.queryItems`:后者不编码 `/`,
    /// 而百度要求 `path` / `dir` 整体编码(`/apps/x` → `%2Fapps%2Fx`)。
    var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.percentEncodedQuery = encodedQuery
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

/// 播放流的 `type`(`BAIDU_PAN_API.md` §2.3)。
///
/// ⛔ 只用通用 HLS。`M3U8_FLV_264_*` 与 `M3U8_MP3_128` 是私有协议,只有网盘自家播放器放得动。
enum BaiduPanStreamType: String, Sendable, Equatable {
    /// `ts` 分片,480p
    case auto480 = "M3U8_AUTO_480"
    /// `ts` 分片,720p
    case auto720 = "M3U8_AUTO_720"
    /// `ts` 分片,1080p(按原片自动封顶)
    case auto1080 = "M3U8_AUTO_1080"
    /// 音频 HLS
    case audioHLSPM3 = "M3U8_HLS_MP3_128"

    /// 按 1080p 请求,百度按原片自动封顶(§2.3)。
    static let video = BaiduPanStreamType.auto1080
    /// 音频:只有 `M3U8_HLS_MP3_128` 是通用 HLS
    static let audio = BaiduPanStreamType.audioHLSPM3
}

/// `opera=rename` 的 `filelist[]` 里的一项(`BAIDU_PAN_API.md` §2.5)。
///
/// ⚠️ `path` 是当前路径,所以批次必须自底向上提交(集文件 → 季目录 → 剧根,§2.6)。
struct BaiduPanRenameOperation: Sendable, Equatable {
    let path: String
    /// 只是最后一段,不含路径
    let newName: String

    init(path: String, newName: String) {
        self.path = path
        self.newName = newName
    }

    /// 推算出的新路径(不是服务端回的),只用来更新本地缓存与进度快照,⛔ 不当请求参数。
    var renamedPath: String {
        (path as NSString).deletingLastPathComponent + "/" + newName
    }
}

/// 百度要的 `User-Agent`。播放流按 §1 的分段形式(官方另一页示例用简写 `xpanvideo;netdisk;client`);
/// 要换形式只改这里。
enum BaiduPanUserAgent {
    static var streaming: String {
        "xpanvideo;\(appName);\(appVersion);\(systemName);\(systemVersion);ts"
    }

    /// 列表 / 元信息 / 下载 / OAuth
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
