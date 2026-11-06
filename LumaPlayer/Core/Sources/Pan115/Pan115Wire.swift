import Foundation

/// 115 的线格式(`docs/PAN115_API.md` §2 - §4)。
///
/// 115 的响应有几个特点,决定了这里的写法:
/// - 成功/失败用 `state: 1/0`(数字,不是布尔);错误码字段名不统一(`errno` / `errNo` / `code`)。
/// - 数字字段有时是字符串(`s`、`fid`、`cid`),⛔ 不能直接 `UInt64`。
/// - 列表接口把数组放在 `data` 上,但 `data` 也可能是对象(错误时是空对象)。
///
/// 所有类型都是**全容错**:字段缺失不抛错,由上层判断「拿到的够不够用」。
/// `CLAUDE.md` 硬规则要求不静默吞错 —— 这里只是不把「字段缺失」当解码错误,
/// 真正缺关键字段时由 `Pan115APIClient` 抛 `Pan115Error.decoding`。

// MARK: - 宽容解码

/// 115 把同一个字段在数字与字符串之间来回换(`115driver pkg/driver/types.go:8-70` 用
/// `StringInt` / `IntString` / `BoolInt` 之类包装器逐字段兜)。这里统一走一套。
enum Pan115Decoding {
    /// 整数,或能转成整数的字符串。
    static func int<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(text)
        }
        return nil
    }

    /// 字符串,或数字(转成十进制字符串)。
    static func string<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) -> String? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return text }
        if let number = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return String(number)
        }
        return nil
    }

    /// 布尔,或 `0` / `1` 的数字与字符串。
    static func bool<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let number = int(container, key) { return number != 0 }
        return nil
    }
}

// MARK: - 通用信封

/// 115 所有响应的公共外壳。
///
/// `state` 在响应里三种形态都出现过:`1`/`0` 的数字、`"1"`/`"0"` 的字符串、
/// 以及**布尔 `true`/`false`**。`115driver pkg/driver/response.go:292-298` 的 `QRCodeBasicResp`
/// 与 `:33-40` 的 `BasicResp` 都按 `int` / `bool` 收;本项目走 `Pan115Decoding.bool` 一次兜住。
///
/// ⚠️ **必须认得布尔 `false`**:`webapi.115.com/files` 系列在 Cookie 失效时会回
/// `{"state":false,"error":"请先登录"}`(§3 实测)。只解 `Int` 会让它变成 `nil` 被 `validate()` 静默放过,
/// 错误响应随后被当成正常响应交给业务解码 —— 表现就是「响应里没有 cid」而不是「请重新登录」。
struct Pan115Envelope: Decodable, Sendable {
    /// true = 成功,false = 业务失败,nil = 响应里没有这个字段(不当失败)。
    let state: Bool?
    let code: Int?
    let errno: Int?
    let errNo: Int?
    let message: String?
    let error: String?

    var isSuccess: Bool { state == true }
    /// 显式失败(`state` 出现且为 false)。nil / true 都不算。
    var isFailure: Bool { state == false }

    /// 错误码按 `115driver` 的取值顺序:`errno` → `errNo` → `code`。
    var errorCode: Int? { errno ?? errNo ?? code }

    var errorMessage: String? {
        let text = message ?? error
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private enum CodingKeys: String, CodingKey {
        case state, code, errno, errNo, message, error
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = Pan115Decoding.bool(container, .state)
        code = Pan115Decoding.int(container, .code)
        errno = Pan115Decoding.int(container, .errno)
        errNo = Pan115Decoding.int(container, .errNo)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
    }
}

// MARK: - 扫码登录(§2.2)

/// 第 1 步 `GET /api/1.0/{app}/1.0/token` 的 `data`。
struct Pan115QRCodeTokenResponse: Decodable, Sendable {
    let data: Payload?

    struct Payload: Decodable, Sendable {
        let uid: String?
        let time: Int?
        let sign: String?
        /// 要编进二维码的文本,不是图片地址(`115driver pkg/driver/qrcode.go:12-18`)
        let qrcode: String?

        private enum CodingKeys: String, CodingKey { case uid, time, sign, qrcode }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uid = Pan115Decoding.string(container, .uid)
            time = Pan115Decoding.int(container, .time)
            sign = try? container.decodeIfPresent(String.self, forKey: .sign)
            qrcode = try? container.decodeIfPresent(String.self, forKey: .qrcode)
        }

        var session: Pan115QRCodeSession? {
            guard let uid, let time, let sign, let qrcode,
                  !uid.isEmpty, !sign.isEmpty, !qrcode.isEmpty else { return nil }
            return Pan115QRCodeSession(uid: uid, time: time, sign: sign, content: qrcode)
        }
    }
}

/// 第 3 步 `GET /get/status/` 的 `data`。
struct Pan115QRCodeStatusResponse: Decodable, Sendable {
    let data: Payload?

    struct Payload: Decodable, Sendable {
        let status: Int?
        let msg: String?
        let version: String?

        private enum CodingKeys: String, CodingKey { case status, msg, version }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = Pan115Decoding.int(container, .status)
            msg = try? container.decodeIfPresent(String.self, forKey: .msg)
            version = Pan115Decoding.string(container, .version)
        }

        var value: Pan115QRCodeStatus? {
            guard let status else { return nil }
            return Pan115QRCodeStatus(raw: status)
        }
    }
}

/// 第 4 步 `POST /app/1.0/{app}/1.0/login/qrcode` 的 `data`。
///
/// ⚠️ 四件套在 `data.cookie` 里(`115driver pkg/driver/response.go:315-320` `Credential Credential \`json:"cookie"\``)。
struct Pan115QRCodeLoginResponse: Decodable, Sendable {
    let data: Payload?

    struct Payload: Decodable, Sendable {
        let cookie: Cookie?
        let userID: String?
        let userName: String?

        struct Cookie: Decodable, Sendable {
            let uid: String?
            let cid: String?
            let seid: String?
            let kid: String?

            private enum CodingKeys: String, CodingKey {
                case uid = "UID"
                case cid = "CID"
                case seid = "SEID"
                case kid = "KID"
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                uid = Pan115Decoding.string(container, .uid)
                cid = Pan115Decoding.string(container, .cid)
                seid = try? container.decodeIfPresent(String.self, forKey: .seid)
                kid = try? container.decodeIfPresent(String.self, forKey: .kid)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case cookie
            case userID = "user_id"
            case userName = "user_name"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cookie = try? container.decodeIfPresent(Cookie.self, forKey: .cookie)
            userID = Pan115Decoding.string(container, .userID)
            userName = try? container.decodeIfPresent(String.self, forKey: .userName)
        }

        var credential: Pan115Credential? {
            guard let cookie, let uid = cookie.uid, let cid = cookie.cid, let seid = cookie.seid,
                  !uid.isEmpty, !cid.isEmpty, !seid.isEmpty else { return nil }
            return Pan115Credential(uid: uid, cid: cid, seid: seid, kid: cookie.kid)
        }
    }
}

// MARK: - 登录态(§2.3)

/// `GET my.115.com/?ct=ajax&ac=nav` 的 `data`(`115driver pkg/driver/response.go:235-261`)。
struct Pan115UserInfoResponse: Decodable, Sendable {
    let data: Payload?

    struct Payload: Decodable, Sendable {
        let userID: String?
        let userName: String?
        /// `vip`:`1` = 会员
        let vip: Int?

        private enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case userName = "user_name"
            case vip
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userID = Pan115Decoding.string(container, .userID)
            userName = try? container.decodeIfPresent(String.self, forKey: .userName)
            vip = Pan115Decoding.int(container, .vip)
        }

        var account: Pan115Account {
            Pan115Account(
                userID: userID,
                userName: userName,
                isVip: (vip ?? 0) > 0
            )
        }
    }
}

// MARK: - 目录(§3)

/// `GET webapi.115.com/files` 的响应(`115driver pkg/driver/response.go:73-88`)。
///
/// ⚠️ 文件数组在 `data` 上,而 `cid` / `count` 在外层。
struct Pan115FileListResponse: Decodable, Sendable {
    let cid: String?
    /// 该目录的**总条目数**(官方 SDK 的注释是「当前目录文件数量」;`get_file_count`
    /// 更是用 `page_size=1` 只取一条却从 `count` 读出总数)。⛔ 它是**当前查询条件下**的总数,
    /// 过滤参数(`show_dir` / `nf` / `type`…)一变它就变 —— 翻页时要与翻页请求用同一套参数。
    let count: Int?
    /// 服务端确认的偏移量(`115driver` 的 `FileListResp.Offset` / `115-sdk-go` 的 `GetFilesResp.Offset`)。
    /// ⚠️ 要用它推进而不是自行累加:aps 接口的文档明写 offset 越界会「相当于 offset=0,从头开始」,
    /// 自行累加会静默回绕成死循环。
    let offset: Int?
    let data: [Entry]?

    private enum CodingKeys: String, CodingKey { case cid, count, offset, data }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cid = Pan115Decoding.string(container, .cid)
        count = Pan115Decoding.int(container, .count)
        offset = Pan115Decoding.int(container, .offset)
        data = try? container.decodeIfPresent([Entry].self, forKey: .data)
    }

    struct Entry: Decodable, Sendable {
        let fid: String?
        let cid: String?
        let name: String?
        let size: String?
        let pickCode: String?
        let sha1: String?
        /// `te`,**unix 秒整数**(`p115client tool/attr.py:245-246` 直接 `int(info["te"])`;`115driver` 的
        /// `FileInfo` 没有这个字段,所以只以 p115client 为准)。⛔ 不是 `yyyy-MM-dd HH:mm:ss` 字符串 ——
        /// 那个形态是 `t`(创建时间),两个字段语义不同,别混。
        let modifiedAtSeconds: Int?
        let isVideo: Int?

        private enum CodingKeys: String, CodingKey {
            case fid
            case cid
            case name = "n"
            case size = "s"
            case pickCode = "pc"
            case sha1 = "sha"
            case modifiedAtSeconds = "te"
            // web 端是 `iv`,app 端是 `isv`(p115client tool/attr.py:290 / :424)
            case isVideo = "iv"
            case isVideoApp = "isv"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fid = Pan115Decoding.string(container, .fid)
            cid = Pan115Decoding.string(container, .cid)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            size = Pan115Decoding.string(container, .size)
            pickCode = try? container.decodeIfPresent(String.self, forKey: .pickCode)
            sha1 = try? container.decodeIfPresent(String.self, forKey: .sha1)
            modifiedAtSeconds = Pan115Decoding.int(container, .modifiedAtSeconds)
            isVideo = Pan115Decoding.int(container, .isVideo)
                ?? Pan115Decoding.int(container, .isVideoApp)
        }

        var entry: Pan115FileEntry? {
            guard let cid else { return nil }
            return Pan115FileEntry(
                fid: fid ?? "",
                cid: cid,
                name: name ?? "",
                size: size,
                pickCode: pickCode,
                sha1: sha1,
                modifiedAtSeconds: modifiedAtSeconds,
                isVideo: (isVideo ?? 0) != 0
            )
        }
    }

    /// 解出可用的条目。⛔ 缺 `cid` 的条目直接丢(连父目录都不知道,拿不到 id)。
    var entries: [Pan115FileEntry] { (data ?? []).compactMap(\.entry) }
}

/// `GET webapi.115.com/files/getid?path=` 的响应。
struct Pan115DirectoryIDResponse: Decodable, Sendable {
    let state: Int?
    let cid: String?
    let id: String?

    private enum CodingKeys: String, CodingKey { case state, cid, id }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = Pan115Decoding.int(container, .state)
        cid = Pan115Decoding.string(container, .cid)
        id = Pan115Decoding.string(container, .id)
    }

    var directoryID: String? { cid ?? id }
}

// MARK: - 取直链(§4.1)

/// `POST proapi.115.com/app/chrome/downurl` 的响应。
///
/// `data` 是 **m115 加密串**(不是 JSON),要用请求时的同一个 key 解开(`115driver pkg/driver/response.go:217-220`)。
struct Pan115DownloadURLResponse: Decodable, Sendable {
    let state: Int?
    let data: String?

    private enum CodingKeys: String, CodingKey { case state, data }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = Pan115Decoding.int(container, .state)
        data = try? container.decodeIfPresent(String.self, forKey: .data)
    }
}

/// 解开 `data` 之后的形状:`{fileID: {…}}`(`115driver pkg/driver/download.go:26-42`)。
struct Pan115DownloadInfo: Decodable, Sendable {
    let fileName: String?
    let fileSize: Int64?
    let pickCode: String?
    let url: URL?

    private enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case fileSize = "file_size"
        case pickCode = "pick_code"
        case url
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try? container.decodeIfPresent(String.self, forKey: .fileName)
        if let value = try? container.decodeIfPresent(Int64.self, forKey: .fileSize) {
            fileSize = value
        } else if let text = Pan115Decoding.string(container, .fileSize) {
            fileSize = Int64(text)
        } else {
            fileSize = nil
        }
        pickCode = try? container.decodeIfPresent(String.self, forKey: .pickCode)
        // `url` 是对象 `{"url": "…"}`;文件失效时是 `false`(`115driver` 专门做了容错)
        if let object = try? container.decodeIfPresent(URLObject.self, forKey: .url) {
            url = object.url.flatMap(URL.init(string:))
        } else {
            url = nil
        }
    }

    struct URLObject: Decodable, Sendable {
        let url: String?

        private enum CodingKeys: String, CodingKey { case url }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try? container.decodeIfPresent(String.self, forKey: .url)
        }
    }
}
