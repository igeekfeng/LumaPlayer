import Foundation

/// 夸克 TV 端接口的线格式(`docs/QUARK_API.md` §3 - §7)。
///
/// 几个决定写法的特点:
/// - 成功/失败都用 `status` + `errno`(`status: 0` 且 `errno: 0` 才是成功);
/// - `errno` 可能缺(`quarkTv.mjs:96` 按 0 处理);
/// - 换 token 的响应外面还包了一层第三方服务的信封(`code` / `message` / `data`);
/// - 数字与字符串混用(`size` 可能是字符串),所以统一走宽容解码。
///
/// 所有类型都是**全容错**:字段缺失不抛错,由上层判断「拿到的够不够用」。
/// `CLAUDE.md` 硬规则要求不静默吞错 —— 这里只是不把「字段缺失」当解码错误,
/// 真正缺关键字段时由 `QuarkAPIClient` 抛 `QuarkError.decoding`。

// MARK: - 宽容解码

enum QuarkDecoding {
    static func int<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }

    static func int64<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int64? {
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) { return value }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Int64(text) }
        return nil
    }

    static func string<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return text }
        if let number = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return String(number)
        }
        return nil
    }
}

// MARK: - 通用信封

/// 所有业务响应的公共外壳(`docs/QUARK_API.md` §3)。
struct QuarkEnvelope: Decodable, Sendable {
    let status: Int?
    let errno: Int?
    let errorInfo: String?
    let reqID: String?

    /// `errno` 缺失按 0 处理(§3 的成功判定)
    var effectiveErrno: Int { errno ?? 0 }
    var effectiveStatus: Int { status ?? 0 }
    var isSuccess: Bool { effectiveStatus == 0 && effectiveErrno == 0 }

    var errorMessage: String? {
        guard let errorInfo, !errorInfo.isEmpty else { return nil }
        return errorInfo
    }

    private enum CodingKeys: String, CodingKey {
        case status, errno, reqID = "req_id"
        case errorInfo = "error_info"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = QuarkDecoding.int(container, .status)
        errno = QuarkDecoding.int(container, .errno)
        errorInfo = try? container.decodeIfPresent(String.self, forKey: .errorInfo)
        reqID = try? container.decodeIfPresent(String.self, forKey: .reqID)
    }
}

// MARK: - 扫码登录(§4)

/// 第 1 步 `GET /oauth/authorize` 的响应。
struct QuarkAuthorizeResponse: Decodable, Sendable {
    let envelope: QuarkEnvelope
    /// base64 PNG(图片本身,不是二维码内容)
    let qrData: String?
    let queryToken: String?

    private enum CodingKeys: String, CodingKey {
        case status, errno, reqID = "req_id"
        case errorInfo = "error_info"
        case qrData = "qr_data"
        case queryToken = "query_token"
    }

    init(from decoder: any Decoder) throws {
        envelope = try QuarkEnvelope(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        qrData = try? container.decodeIfPresent(String.self, forKey: .qrData)
        queryToken = try? container.decodeIfPresent(String.self, forKey: .queryToken)
    }

    /// nil = 响应里没有可用的二维码 / `query_token`
    var session: QuarkQRCodeSession? {
        guard let qrData, let queryToken, !qrData.isEmpty, !queryToken.isEmpty else { return nil }
        return QuarkQRCodeSession(imageBase64: qrData, queryToken: queryToken)
    }
}

/// 第 3 步 `GET /oauth/code` 的响应。
struct QuarkCodeResponse: Decodable, Sendable {
    let envelope: QuarkEnvelope
    let code: String?

    private enum CodingKeys: String, CodingKey {
        case status, errno, reqID = "req_id"
        case errorInfo = "error_info"
        case code
    }

    init(from decoder: any Decoder) throws {
        envelope = try QuarkEnvelope(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try? container.decodeIfPresent(String.self, forKey: .code)
    }
}

/// 第 4 步 `POST {codeApi}/token` 的响应(`docs/QUARK_API.md` §4)。
///
/// ⚠️ 外面是第三方服务的信封:`code == 200` 只表示「受理了」,
/// 里面 `data.status == -1` / `data.errno != 0` 才是真失败(如 `11004` 授权码无效)。
struct QuarkTokenExchangeResponse: Decodable, Sendable {
    let code: Int?
    let message: String?
    let data: Payload?

    struct Payload: Decodable, Sendable {
        let envelope: QuarkEnvelope
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?
        let scope: String?

        private enum CodingKeys: String, CodingKey {
            case status, errno, reqID = "req_id"
            case errorInfo = "error_info"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }

        init(from decoder: any Decoder) throws {
            envelope = try QuarkEnvelope(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try? container.decodeIfPresent(String.self, forKey: .accessToken)
            refreshToken = try? container.decodeIfPresent(String.self, forKey: .refreshToken)
            expiresIn = QuarkDecoding.int(container, .expiresIn)
            scope = try? container.decodeIfPresent(String.self, forKey: .scope)
        }

        var tokens: (access: String, refresh: String)? {
            guard let accessToken, let refreshToken,
                  !accessToken.isEmpty, !refreshToken.isEmpty else { return nil }
            return (accessToken, refreshToken)
        }
    }

    private enum CodingKeys: String, CodingKey { case code, message, data }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = QuarkDecoding.int(container, .code)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        data = try? container.decodeIfPresent(Payload.self, forKey: .data)
    }
}

// MARK: - 登录态(§7)

/// `GET /user?method=user_info` 的响应。TV 端只给很少的字段,缺就不显示。
struct QuarkUserInfoResponse: Decodable, Sendable {
    let envelope: QuarkEnvelope
    let nickname: String?
    let vip: Int?

    private enum CodingKeys: String, CodingKey {
        case status, errno, reqID = "req_id"
        case errorInfo = "error_info"
        case data
    }

    private struct Payload: Decodable, Sendable {
        let nickname: String?
        let nickNameCamel: String?
        let vip: Int?

        private enum CodingKeys: String, CodingKey {
            case nickname
            case nickNameCamel = "nick_name"
            case vip
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nickname = try? container.decodeIfPresent(String.self, forKey: .nickname)
            nickNameCamel = try? container.decodeIfPresent(String.self, forKey: .nickNameCamel)
            vip = QuarkDecoding.int(container, .vip)
        }
    }

    init(from decoder: any Decoder) throws {
        envelope = try QuarkEnvelope(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try? container.decodeIfPresent(Payload.self, forKey: .data)
        nickname = payload?.nickname ?? payload?.nickNameCamel
        vip = payload?.vip
    }

    var account: QuarkAccount {
        QuarkAccount(nickname: nickname, isVip: (vip ?? 0) > 0)
    }
}

// MARK: - 目录(§5)

/// `GET /file?method=list` 的响应。
struct QuarkFileListResponse: Decodable, Sendable {
    let envelope: QuarkEnvelope
    let totalCount: Int?
    /// 已解码的条目(缺 `fid` / `filename` 的已被丢掉)
    let files: [QuarkFileEntry]

    private enum CodingKeys: String, CodingKey {
        case status, errno, reqID = "req_id"
        case errorInfo = "error_info"
        case data
    }

    private struct Payload: Decodable, Sendable {
        let totalCount: Int?
        let files: [Entry]?

        private enum CodingKeys: String, CodingKey {
            case totalCount = "total_count"
            case files
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalCount = QuarkDecoding.int(container, .totalCount)
            files = try? container.decodeIfPresent([Entry].self, forKey: .files)
        }
    }

    /// `data.files[]`(`docs/QUARK_API.md` §5.1)。
    struct Entry: Decodable, Sendable {
        let fid: String?
        let parentFid: String?
        let filename: String?
        let size: Int64?
        /// `1` = 目录
        let isDirectoryFlag: Int?
        /// `1` = 视频(取直链时据此判断,§6.2)
        let category: Int?
        /// 时长。⚠️ 单位只有【推断】是秒(`docs/QUARK_API.md` §5.1 未实测),⛔ 不据此显示时长
        let duration: Int?
        /// **毫秒**时间戳,与百度(秒)、115(秒)都不同(§5.1)
        let createdAtMilliseconds: Int64?
        let updatedAtMilliseconds: Int64?
        let thumbnailURL: String?

        private enum CodingKeys: String, CodingKey {
            case fid
            case parentFid = "parent_fid"
            case filename
            case size
            case isDirectoryFlag = "isdir"
            case category
            case duration
            case createdAtMilliseconds = "created_at"
            case updatedAtMilliseconds = "updated_at"
            case thumbnailURL = "thumbnail_url"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fid = QuarkDecoding.string(container, .fid)
            parentFid = QuarkDecoding.string(container, .parentFid)
            filename = try? container.decodeIfPresent(String.self, forKey: .filename)
            size = QuarkDecoding.int64(container, .size)
            isDirectoryFlag = QuarkDecoding.int(container, .isDirectoryFlag)
            category = QuarkDecoding.int(container, .category)
            duration = QuarkDecoding.int(container, .duration)
            createdAtMilliseconds = QuarkDecoding.int64(container, .createdAtMilliseconds)
            updatedAtMilliseconds = QuarkDecoding.int64(container, .updatedAtMilliseconds)
            thumbnailURL = try? container.decodeIfPresent(String.self, forKey: .thumbnailURL)
        }

        var entry: QuarkFileEntry? {
            guard let id = fid, !id.isEmpty, let name = filename, !name.isEmpty else {
                return nil
            }
            let seconds: Double? = duration.map { Double($0) }
            let thumbnail: URL? = {
                guard let raw = self.thumbnailURL, !raw.isEmpty else { return nil }
                return URL(string: raw)
            }()
            return QuarkFileEntry(
                fid: id,
                parentFid: parentFid ?? QuarkEndpoint.rootFid,
                name: name,
                sizeBytes: size,
                isDirectory: (isDirectoryFlag ?? 0) == 1,
                category: category,
                durationSeconds: seconds,
                modifiedAt: Self.date(milliseconds: updatedAtMilliseconds),
                createdAt: Self.date(milliseconds: createdAtMilliseconds),
                thumbnailURL: thumbnail
            )
        }

        /// ⚠️ 毫秒转秒再转 `Date`(`docs/QUARK_API.md` §5.1)
        static func date(milliseconds: Int64?) -> Date? {
            guard let milliseconds, milliseconds > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        }
    }

    init(from decoder: any Decoder) throws {
        envelope = try QuarkEnvelope(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try? container.decodeIfPresent(Payload.self, forKey: .data)
        totalCount = payload?.totalCount
        var decoded: [QuarkFileEntry] = []
        for item in payload?.files ?? [] {
            if let entry = item.entry { decoded.append(entry) }
        }
        files = decoded
    }
}

// MARK: - 取直链(§6.1)

/// `GET /file?method=download` 的响应。
struct QuarkDownloadResponse: Decodable, Sendable {
    let envelope: QuarkEnvelope
    let fid: String?
    let fileName: String?
    let size: Int64?
    let downloadURL: String?

    private enum CodingKeys: String, CodingKey {
        case status, errno, reqID = "req_id"
        case errorInfo = "error_info"
        case data
    }

    private struct Payload: Decodable, Sendable {
        let fid: String?
        let fileName: String?
        let size: Int64?
        let downloadURL: String?

        private enum CodingKeys: String, CodingKey {
            case fid
            case fileName = "file_name"
            case size
            case downloadURL = "download_url"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fid = QuarkDecoding.string(container, .fid)
            fileName = try? container.decodeIfPresent(String.self, forKey: .fileName)
            size = QuarkDecoding.int64(container, .size)
            downloadURL = try? container.decodeIfPresent(String.self, forKey: .downloadURL)
        }
    }

    init(from decoder: any Decoder) throws {
        envelope = try QuarkEnvelope(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try? container.decodeIfPresent(Payload.self, forKey: .data)
        fid = payload?.fid
        fileName = payload?.fileName
        size = payload?.size
        downloadURL = payload?.downloadURL
    }
}
