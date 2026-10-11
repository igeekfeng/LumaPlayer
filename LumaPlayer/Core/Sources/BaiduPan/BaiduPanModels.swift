import Foundation

// MARK: - 领域模型

/// 百度网盘里的一个条目(文件或目录)。
///
/// 字段来源:`获取文件列表` 官方页,见 `docs/BAIDU_PAN_API.md` §4:
/// `errno` / `list[]`(含 `fs_id` / `path` / `server_filename` / `size` /
/// `isdir` / `category` / `md5` / `server_mtime` / `thumbs`)。
///
/// ⚠️ 与 `EmbyItem` 的立场一致:能缺的字段一律可选,⛔ 不填假默认值。
struct BaiduPanFile: Sendable, Equatable, Identifiable {

    /// 云端唯一 ID。`fs_id` 是 `uint64`,但某些响应里会给字符串,
    /// 所以解码走「数字或字符串都认」(见 `BaiduPanFileMeta` 的解码实现)。
    let fsID: UInt64

    /// 绝对路径,`/` 开头。`method=list` / `filemetas` / `streaming` 全按它定位。
    let path: String

    /// 文件名。`server_filename` 缺失时退回路径最后一段 ——
    /// ⛔ 不编名字(与 Emby 那边「Name 不是文件名」的教训同理)。
    let name: String

    /// 文件大小(字节)。目录为 nil。
    let sizeBytes: UInt64?

    let isDirectory: Bool

    /// `1` 视频 / `2` 音频 / `3` 图片 / `4` 文档 / `5` 应用 / `6` 其他 / `7` 种子。
    /// nil = 服务端没给这一项。
    let category: Int?

    let modifiedAt: Date?

    /// `web=1` 时图片条目会给三档缩略图。
    /// ⚠️ 本项目**没有**接缩略图(见 `docs/SOURCE_ABSTRACTION_PLAN.md` §4.5:
    /// 缩略图是有时效、要带 token 的临时地址,缓存通路与 Emby 不同),
    /// 这里只解码不使用 —— 留着是为了「字段确实存在」这件事有据可查。
    let thumbnailURL: URL?

    var id: String { String(fsID) }

    /// 列表里展示/判定的归类。
    ///
    /// 判据优先级:`category`(服务端给的)> 扩展名。
    /// 扩展名这一路是 `BAIDU_PAN_API.md` §5 明确允许的 —— 百度侧的媒体类型
    /// 从 `meta` 的 `media_info`(要 `detail=1`)或**文件名后缀**拿。
    var kind: BaiduPanFileKind {
        switch category {
        case BaiduPanCategory.video: return .video
        case BaiduPanCategory.audio: return .audio
        case .some: return .other
        case nil: break
        }
        let ext = fileExtension
        if BaiduPanFileKind.videoExtensions.contains(ext) { return .video }
        if BaiduPanFileKind.audioExtensions.contains(ext) { return .audio }
        return .other
    }

    /// 小写、不带点的扩展名;没有扩展名时为 `""`。
    var fileExtension: String {
        let last = (path as NSString).lastPathComponent
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return "" }
        return String(last[last.index(after: dot)...]).lowercased()
    }
}

/// 条目归类。只服务 UI 分支与「能不能播」,不是对 `category` 的全集枚举。
enum BaiduPanFileKind: Sendable, Equatable {
    case video
    case audio
    /// 图片 / 文档 / 种子 / 其他 —— 列表里列出来(用户放错了东西要看得见),
    /// 但不给播放入口(百度会回 `31301 非音视频文件`)。
    case other

    var isPlayable: Bool { self != .other }

    /// ⚠️ 这张表**只**用来判断「要不要给播放入口」,不参与播放决策:
    /// 决策由 `PlaybackDecisionEngine` 的能力判断做,⛔ 这里不另立一份白名单。
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "ts", "m2ts", "mts",
        "webm", "rmvb", "rm", "mpg", "mpeg", "3gp", "vob",
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "flac", "aac", "m4a", "wav", "ape", "ogg", "opus", "wma",
    ]
}

/// `category` 的取值(`BAIDU_PAN_API.md` §4:`1` 视频、`2` 音频…)。
enum BaiduPanCategory {
    static let video = 1
    static let audio = 2
}

/// 账号信息(`method=uinfo`,`BAIDU_PAN_API.md` §4)。
struct BaiduPanAccount: Sendable, Equatable {
    /// 用户唯一 ID
    let uk: String?
    let displayName: String?
    let avatarURL: URL?
    /// 0 普通 / 1 会员 / 2 超级会员(`vip_version=v2`)。
    /// ⚠️ 非会员会在播放时撞 `errno=133`(§5),但**不在这里拦** ——
    /// 判定要在起播前做,而这里只是个快照,可能已经过期。
    let vipType: Int?

    var isMember: Bool { (vipType ?? 0) >= 1 }
}

/// 换个来源的**授权令牌**。整体作为一个 JSON 存进凭据文件。
///
/// ⚠️ `BAIDU_PAN_API.md` §6 的三条坑决定了它的形状:
/// - `refresh_token` **只能用一次**,刷新后必须把响应里的新值落盘,
///   所以它必须是 `var`;
/// - `expires_in` 是相对秒数,落盘要换算成绝对时间,否则重启后
///   「还剩多久」无从判断 —— 所以存 `expiresAt` 而不是 `expiresIn`。
struct BaiduPanTokenBundle: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// `scope`(响应里有就带上,便于诊断)
    var scope: String?

    /// 判定「该刷新了」。提前 5 分钟:access_token 有效期 30 天,
    /// 提前量只要盖住一次请求的耗时即可,不需要更复杂。
    func needsRefresh(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

/// 设备码授权的第一步结果(`BAIDU_PAN_API.md` §2.1)。
struct BaiduPanDeviceCode: Sendable, Equatable {
    /// 轮询换 token 用
    let deviceCode: String
    /// 让用户手输的短码
    let userCode: String
    /// 用户手输 `user_code` 的授权页(`verification_url`)
    let verificationURL: URL?
    /// 官方给的二维码**图片**地址(`qrcode_url`)。
    /// ⚠️ 这是图片地址,**不是**要编进二维码的内容 —— 本项目不用它渲染
    /// (理由见 `qrCodeContent`),留着是为了排障时能对着官方图核一眼。
    let qrCodeImageURL: URL?
    /// 有效期(秒),官方给 300
    let expiresIn: Int
    /// 轮询间隔(秒),官方给 5;⛔ 不得小于它(`BAIDU_PAN_API.md` §2.1)
    let interval: Int

    /// 要编进二维码的内容。
    ///
    /// 拼接规则是官方页面写明的:
    /// `https://openapi.baidu.com/device?display=mobile&code=<user_code>`。
    ///
    /// 为什么**本地渲染**而不是直接显示 `qrcode_url` 那张图:那张图要多发一次
    /// 请求、跨一次主机,而内容规则是确定的字符串 —— 本地渲染既离线可得,
    /// 也不引入一个新的失败点(CoreImage 的 `CIQRCodeGenerator`)。
    var qrCodeContent: String {
        "https://openapi.baidu.com/device?display=mobile&code=\(userCode)"
    }
}

/// 应用凭据(AppKey / SecretKey)。用户自己在开放平台控制台建应用后拿到。
///
/// ⚠️ **本项目不含任何真实密钥**。`secretKey` 会落在客户端二进制里 ——
/// 自用可接受,发布要重新评估。
struct BaiduPanAppCredentials: Sendable, Equatable {
    let appKey: String
    let secretKey: String
    /// 应用目录名。第三方应用只能访问 `/apps/{应用目录名}`(§3),
    /// 这个值就是那一段 —— 必须与开放平台里建应用时填的名字一致。
    let folderName: String

    static let scope = "basic,netdisk"
}

// MARK: - 授权状态

/// 授权页要显示哪一屏。三态而不是布尔:缺密钥与缺授权是**两件不同的事**
/// (一个要去开放平台建应用,一个扫码就行),合成一个「未授权」会让人找不到北。
enum BaiduPanAuthorization: Sendable, Equatable {
    /// 还没填 AppKey / SecretKey / 应用目录名
    case unconfigured
    /// 密钥齐了,但没有 token(或 token 已失效)
    case needsAuthorization(folderName: String)
    /// 已授权。
    ///
    /// ⚠️ `account` 是可选的:从凭据文件里只知道「有 token」,账号昵称要另发
    /// 一次 `uinfo` 才有。⛔ 不编一个占位账号 —— 没有就是 nil,UI 显示
    /// 「已授权」而不显示昵称。
    case authorized(account: BaiduPanAccount?)
}

extension BaiduPanAuthorization {
    /// 已授权时的账号昵称;没有(或还没取到)为 nil。
    var accountName: String? {
        if case .authorized(let account) = self { return account?.displayName }
        return nil
    }
}

/// 路径规则。抽成一个独立的小类型,只为一条纯字符串判断:
/// ⛔ 没必要为了它去构造一个 `BaiduPanConnection`(actor),那样它就没法被单测直接调到。
enum BaiduPanPath {

    /// `path` 是否落在应用目录之内(或就是它本身)。
    ///
    /// 判断用 `root + "/"` 前缀而不是 `hasPrefix(root)`:后者会把
    /// `/apps/LumaPlayerXX` 也算进 `/apps/LumaPlayer` 的范围里 ——
    /// 而那种路径第三方应用一样访问不到(§3),放进片库根就是个必然打不开的入口。
    static func isInside(_ path: String, applicationRoot root: String) -> Bool {
        guard !path.isEmpty, !root.isEmpty else { return false }
        if path == root { return true }
        return path.hasPrefix(root + "/")
    }
}

// MARK: - 线格式(Decodable)

/// `method=list` 的响应。
struct BaiduPanListResponse: Decodable, Sendable {
    let errno: Int
    let list: [BaiduPanFileMeta]?
    /// 失败时的可展示描述
    let showMessage: String?

    enum CodingKeys: String, CodingKey {
        case errno
        case list
        case showMessage = "show_msg"
    }
}

/// `multimedia?method=filemetas` 的响应(`BaiduPanEndpoint.fileMeta`)。
///
/// ⚠️ **不再是 `method=meta` 的形状**:2026-10-10 实测 `method=meta&dlink=1`
/// 的响应顶层只有 `list` / `request_id`,**没有 `errno`** —— 按 `errno` 必填解
/// 会直接「缺少字段 errno」。换到 `filemetas` 之后 `errno` 又回来了,所以这里仍是必填。
struct BaiduPanMetaResponse: Decodable, Sendable {
    let errno: Int
    let list: [BaiduPanFileMeta]?
    let showMessage: String?

    enum CodingKeys: String, CodingKey {
        case errno
        case list
        case showMessage = "show_msg"
        /// `filemetas` 的失败描述用这个名字(`show_msg` 是 `list` / 旧 `meta` 的)
        case errmsg
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errno = try container.decode(Int.self, forKey: .errno)
        list = try? container.decode([BaiduPanFileMeta].self, forKey: .list)
        showMessage = (try? container.decode(String.self, forKey: .showMessage))
            ?? (try? container.decode(String.self, forKey: .errmsg))
    }
}

/// 列表 / 元信息里的一个条目。
///
/// ⚠️ 解码策略:除 `errno` 外**全部可选且容错**。理由有两条:
/// 1. 官方页明确「条目存在时才返回」某些字段(目录没有 `size`/`md5`,
///    图片才有 `thumbs`),把它们写成必填会整条解失败;
/// 2. `media_info` 的内层字段名**未在官方页逐字段核实**,所以那一段一律 `try?`
///    取值:取不到就是没有,⛔ 不猜值、也不让整条挂掉。
struct BaiduPanFileMeta: Decodable, Sendable {
    let fsID: UInt64?
    let path: String?
    let serverFilename: String?
    let size: UInt64?
    let isDirectoryFlag: Int?
    let category: Int?
    let serverMTime: UInt64?
    let dirEmpty: Int?
    let dlink: String?
    let thumbs: [String: String]?
    let mediaInfo: BaiduPanMediaInfo?
    /// `filemetas` 给的文件名(列表接口用的是 `server_filename`)
    let filename: String?
    /// `needmedia=1` 时给的时长(秒)。**实测**由 `filemetas` 直接给在条目上,
    /// 不走 `media_info`(`BAIDU_PAN_API.md` §4)。
    let duration: Double?

    enum CodingKeys: String, CodingKey {
        case fsID = "fs_id"
        case path
        case serverFilename = "server_filename"
        case size
        case isDirectoryFlag = "isdir"
        case category
        case serverMTime = "server_mtime"
        case dirEmpty = "dir_empty"
        case dlink
        case thumbs
        case mediaInfo = "media_info"
        case filename
        case duration
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `fs_id` 官方标 `uint64`,但社区实现里见过字符串形式 → 两种都认
        fsID = (try? container.decode(UInt64.self, forKey: .fsID))
            ?? (try? container.decode(String.self, forKey: .fsID)).flatMap(UInt64.init)
        path = try? container.decode(String.self, forKey: .path)
        serverFilename = try? container.decode(String.self, forKey: .serverFilename)
        size = (try? container.decode(UInt64.self, forKey: .size))
            ?? (try? container.decode(String.self, forKey: .size)).flatMap(UInt64.init)
        isDirectoryFlag = try? container.decode(Int.self, forKey: .isDirectoryFlag)
        category = try? container.decode(Int.self, forKey: .category)
        serverMTime = try? container.decode(UInt64.self, forKey: .serverMTime)
        dirEmpty = try? container.decode(Int.self, forKey: .dirEmpty)
        dlink = try? container.decode(String.self, forKey: .dlink)
        thumbs = try? container.decode([String: String].self, forKey: .thumbs)
        mediaInfo = try? container.decode(BaiduPanMediaInfo.self, forKey: .mediaInfo)
        filename = try? container.decode(String.self, forKey: .filename)
        // `duration` 实测是数字;见过给字符串的接口,两种都认(与 `size` 同一手法)
        duration = (try? container.decode(Double.self, forKey: .duration))
            ?? (try? container.decode(String.self, forKey: .duration)).flatMap(Double.init)
    }

    /// 总时长(秒)。两个来源,`filemetas` 的条目级 `duration` 优先
    /// (实测它直接给;**`media_info` 实测不存在**,留着只为兼容旧形状)。
    var durationSeconds: Double? { duration ?? mediaInfo?.durationSeconds }

    /// 转成领域模型。`fs_id` 与 `path` 缺一就没法定位文件 —— 返回 nil,
    /// 由调用方跳过这一条(⛔ 不用 `path` 反推 fs_id 这类假数据)。
    var file: BaiduPanFile? {
        guard let path, !path.isEmpty else { return nil }
        guard let fsID else { return nil }
        let isDirectory = (isDirectoryFlag ?? 0) == 1
        let name = [filename, serverFilename]
            .compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }
            .first
            ?? (path as NSString).lastPathComponent
        return BaiduPanFile(
            fsID: fsID,
            path: path,
            name: name,
            // 目录没有「大小」:服务端对目录固定给 `size: 0`,而 0 字节是
            // 「一个空文件」的意思 —— 报 nil 才是实话(列表行也只对文件显示体积)。
            sizeBytes: isDirectory ? nil : size,
            isDirectory: isDirectory,
            category: category,
            modifiedAt: serverMTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            thumbnailURL: thumbs.flatMap { $0["url2"] ?? $0["url1"] ?? $0["url3"] }
                .flatMap(URL.init(string:))
        )
    }
}

/// `meta` 带的媒体信息。
///
/// ⚠️ **2026-10-10 实测:`filemetas` 与旧 `meta` 的响应里都没有 `media_info`**
/// —— 时长是**条目级**的 `duration`(见 `BaiduPanFileMeta.durationSeconds`)。
/// 这个类型只留着兼容「万一某个接口版本仍给嵌套形状」,⛔ 新字段不要再往这里加。
struct BaiduPanMediaInfo: Decodable, Sendable, Equatable {
    /// 时长(秒)。`duration` 与 `duration_ms` 两个都试,单位按名字区分。
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case duration
        case durationMS = "duration_ms"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let seconds = try? container.decode(Double.self, forKey: .duration) {
            durationSeconds = seconds
        } else if let milliseconds = try? container.decode(Double.self, forKey: .durationMS) {
            durationSeconds = milliseconds / 1000
        } else {
            durationSeconds = nil
        }
    }
}

/// `method=uinfo` 的响应(`BAIDU_PAN_API.md` §4)。
struct BaiduPanUserInfoResponse: Decodable, Sendable {
    let errno: Int?
    let uk: UInt64?
    let netdiskName: String?
    let avatarURL: String?
    let vipType: Int?
    let showMessage: String?

    enum CodingKeys: String, CodingKey {
        case errno
        case uk
        case netdiskName = "netdisk_name"
        case avatarURL = "avatar_url"
        case vipType = "vip_type"
        case showMessage = "show_msg"
    }

    var account: BaiduPanAccount {
        BaiduPanAccount(
            uk: uk.map(String.init),
            displayName: netdiskName,
            avatarURL: avatarURL.flatMap(URL.init(string:)),
            vipType: vipType
        )
    }
}

/// 设备码授权第一步的响应(`BAIDU_PAN_API.md` §2.1 的字段名)。
struct BaiduPanDeviceCodeResponse: Decodable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String?
    let qrCodeURL: String?
    let expiresIn: Int?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURL = "verification_url"
        case qrCodeURL = "qrcode_url"
        case expiresIn = "expires_in"
        case interval
    }

    var deviceCodeValue: BaiduPanDeviceCode {
        BaiduPanDeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL.flatMap(URL.init(string:)),
            qrCodeImageURL: qrCodeURL.flatMap(URL.init(string:)),
            expiresIn: expiresIn ?? 300,
            // ⛔ 不采信小于 5 的 interval:官方明说轮询间隔「一般不能低于 5 秒」
            interval: max(interval ?? 5, 5)
        )
    }
}

/// token 响应:设备码换 token、授权码换 token、刷新,**三处同一个形状**
/// (`BAIDU_PAN_API.md` §2.1)。
struct BaiduPanTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }

    func bundle(now: Date = Date()) -> BaiduPanTokenBundle? {
        // ⚠️ §6:`refresh_token` 只能用一次,刷新响应必然带新的。
        // 拿不到就当这次授权不可用 —— ⛔ 不沿用旧的 refresh_token:
        // 官方明说旧的在刷新成功那一刻已失效,沿用它第二次刷新必挂。
        guard let refreshToken, !refreshToken.isEmpty else { return nil }
        return BaiduPanTokenBundle(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(expiresIn),
            scope: scope
        )
    }
}

/// OAuth 失败响应(`{"error":"invalid_grant","error_description":"..."}`)。
struct BaiduPanOAuthErrorResponse: Decodable, Sendable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// 兜底的 `errno` 信封:`streaming` 失败、以及任何「不是 m3u8 文本」的响应
/// (`BAIDU_PAN_API.md` §4 的失败响应)。
struct BaiduPanErrnoEnvelope: Decodable, Sendable {
    let errno: Int?
    let adTime: Int?
    let adToken: String?
    let ltime: Int?
    /// 服务端给的失败描述。`show_msg`(列表 / 播放流)与 `errmsg`(`filemetas`)
    /// 是两个名字,⛔ 别只认一个 —— 只认一个的结果是错误码带出来、描述丢了。
    var showMessage: String? { storedShowMessage ?? storedErrmsg }

    private let storedShowMessage: String?
    private let storedErrmsg: String?

    enum CodingKeys: String, CodingKey {
        case errno
        case adTime
        case adToken
        case ltime
        case storedShowMessage = "show_msg"
        case storedErrmsg = "errmsg"
    }
}
