import Foundation

// MARK: - 领域模型

/// 百度网盘里的文件或目录(字段见 `docs/BAIDU_PAN_API.md` §4)。能缺的字段一律可选,⛔ 不填假默认值。
struct BaiduPanFile: Sendable, Equatable, Identifiable, Codable {

    /// `fs_id`。解码时数字或字符串都认(见 `BaiduPanFileMeta`)
    let fsID: UInt64

    /// 绝对路径,`/` 开头;各接口都按它定位
    let path: String

    /// `server_filename` 缺失时退回路径最后一段
    let name: String

    /// 字节;目录为 nil
    let sizeBytes: UInt64?

    let isDirectory: Bool

    /// `1` 视频 / `2` 音频 / `3` 图片 / `4` 文档 / `5` 应用 / `6` 其他 / `7` 种子;nil = 服务端没给
    let category: Int?

    let modifiedAt: Date?

    /// 图片条目的缩略图。只解码不使用:它是有时效、要带 token 的临时地址。
    let thumbnailURL: URL?

    var id: String { String(fsID) }

    /// `category` 优先,没有时看扩展名(`BAIDU_PAN_API.md` §5)
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

    /// 小写、不带点;没有时为 `""`
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
    /// 列出但不给播放入口(百度会回 `31301 非音视频文件`)
    case other

    var isPlayable: Bool { self != .other }

    /// 只决定给不给播放入口,不参与播放决策(那是 `PlaybackDecisionEngine` 的事)
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "ts", "m2ts", "mts",
        "webm", "rmvb", "rm", "mpg", "mpeg", "3gp", "vob",
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "flac", "aac", "m4a", "wav", "ape", "ogg", "opus", "wma",
    ]
}

/// `category` 取值(`BAIDU_PAN_API.md` §4)
enum BaiduPanCategory {
    static let video = 1
    static let audio = 2
}

/// 账号信息(`method=uinfo`,`BAIDU_PAN_API.md` §4)。
struct BaiduPanAccount: Sendable, Equatable {
    let uk: String?
    let displayName: String?
    let avatarURL: URL?
    /// 0 普通 / 1 会员 / 2 超级会员(`vip_version=v2`)。非会员播放会撞 `errno=133`(§5),
    /// 但不按这里拦:它只是快照,可能过期。
    let vipType: Int?

    var isMember: Bool { (vipType ?? 0) >= 1 }
}

/// 授权令牌,整体作为一个 JSON 存进凭据文件(`BAIDU_PAN_API.md` §6)。
/// `refresh_token` 只能用一次,刷新后必须落盘新值;`expires_in` 换算成绝对时间存。
struct BaiduPanTokenBundle: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scope: String?

    /// 提前量只需盖住一次请求耗时(access_token 有效 30 天)
    func needsRefresh(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

/// 设备码授权的第一步结果(`BAIDU_PAN_API.md` §2.1)。
struct BaiduPanDeviceCode: Sendable, Equatable {
    let deviceCode: String
    /// 用户手输的短码
    let userCode: String
    let verificationURL: URL?
    /// 官方二维码图片地址,不是二维码内容;不用于渲染,只供排障对照
    let qrCodeImageURL: URL?
    /// 有效期(秒),官方给 300
    let expiresIn: Int
    /// 轮询间隔(秒),官方给 5;⛔ 不得小于它(`BAIDU_PAN_API.md` §2.1)
    let interval: Int

    /// 二维码内容,拼法是官方写明的。本地渲染(`CIQRCodeGenerator`),省掉下载 `qrcode_url` 那次请求。
    var qrCodeContent: String {
        "https://openapi.baidu.com/device?display=mobile&code=\(userCode)"
    }
}

/// 用户在开放平台建应用后自己填。⛔ 仓库不含真实密钥;`secretKey` 留在客户端,自用可接受,发布要重新评估。
struct BaiduPanAppCredentials: Sendable, Equatable {
    let appKey: String
    let secretKey: String
    /// 第三方应用只能访问 `/apps/{应用目录名}`(§3),须与建应用时填的一致
    let folderName: String

    static let scope = "basic,netdisk"
}

// MARK: - 授权状态

/// 授权页显示哪一屏。缺密钥(去开放平台建应用)与缺授权(扫码)要分开。
enum BaiduPanAuthorization: Sendable, Equatable {
    case unconfigured
    /// 密钥齐了,但没有 token 或已失效
    case needsAuthorization(folderName: String)
    /// `account` 要另发 `uinfo` 才有;没有就是 nil,⛔ 不编占位账号
    case authorized(account: BaiduPanAccount?)
}

extension BaiduPanAuthorization {
    var accountName: String? {
        if case .authorized(let account) = self { return account?.displayName }
        return nil
    }
}

/// 路径规则(纯字符串判断,不依赖 `BaiduPanConnection`)
enum BaiduPanPath {

    /// `path` 在应用目录内或就是它。用 `root + "/"` 前缀,避免 `/apps/LumaPlayerXX` 被算进 `/apps/LumaPlayer`。
    static func isInside(_ path: String, applicationRoot root: String) -> Bool {
        guard !path.isEmpty, !root.isEmpty else { return false }
        if path == root { return true }
        return path.hasPrefix(root + "/")
    }

    static func directory(ofFilePath path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// `locator` 是不是 `path` 本身,或(`path` 是目录时)落在它下面(同删除接口的递归语义,§2.4)。
    /// 文件只认完全相等。用于删除条目时清观看记录、隐藏目录时滤续播卡。
    static func covers(path: String, locator: String, isDirectory: Bool) -> Bool {
        guard !path.isEmpty, !locator.isEmpty else { return false }
        guard isDirectory else { return locator == path }
        return isInside(locator, applicationRoot: path)
    }

    /// 文件所属剧的目录:父目录名整个是季标记(`第1季` / `Season 2` / `S0`)时再往上一层,
    /// 否则就是父目录(同 `BaiduPanMetadataSynthesizer.seriesFolder` 判据 1)。
    /// 用于续播卡进详情页、倍速记忆认「同一部剧」(`PlaybackSpeedScope.baiduPan`)。
    static func seriesDirectory(ofFilePath path: String) -> String {
        let parent = directory(ofFilePath: path)
        let parentName = (parent as NSString).lastPathComponent
        guard BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName: parentName) != nil else {
            return parent
        }
        let grandparent = directory(ofFilePath: parent)
        return grandparent.isEmpty || grandparent == "/" ? parent : grandparent
    }
}

// MARK: - 线格式(Decodable)

/// `method=list` 的响应。
struct BaiduPanListResponse: Decodable, Sendable {
    let errno: Int
    let list: [BaiduPanFileMeta]?
    let showMessage: String?

    enum CodingKeys: String, CodingKey {
        case errno
        case list
        case showMessage = "show_msg"
    }
}

/// `multimedia?method=filemetas` 的响应(`BaiduPanEndpoint.fileMeta`)。
/// ⛔ 不要换回 `method=meta`:它的响应没有 `errno`。
struct BaiduPanMetaResponse: Decodable, Sendable {
    let errno: Int
    let list: [BaiduPanFileMeta]?
    let showMessage: String?

    enum CodingKeys: String, CodingKey {
        case errno
        case list
        case showMessage = "show_msg"
        /// `filemetas` 的失败描述字段
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

/// `method=filemanager&opera=delete` 的响应(`docs/BAIDU_PAN_API.md` §2.4)。
/// 顶层 `errno` 只表示受理,逐条结果在 `info`,两者都要看。
struct BaiduPanFileManagerResponse: Decodable, Sendable {
    /// 只在 `async=0` 时有;缺失 = 说不清删没删成
    struct Info: Decodable, Sendable {
        let errno: Int
        let path: String
    }

    let errno: Int
    let info: [Info]?
    let requestID: UInt64?
    /// 只在 `async≠0` 时有;本项目固定 `async=0`,不依赖它
    let taskID: UInt64?

    enum CodingKeys: String, CodingKey {
        case errno
        case info
        case requestID = "request_id"
        case taskID = "taskid"
    }
}

/// 列表 / 元信息里的一个条目。全部可选且容错:很多字段按条目类型才返回(目录没有 `size`,
/// 图片才有 `thumbs`),取不到就是没有,⛔ 不猜值、不让整条解码失败。
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
    /// `filemetas` 的文件名(列表接口用 `server_filename`)
    let filename: String?
    /// 秒,`needmedia=1` 时给在条目上(`BAIDU_PAN_API.md` §4)
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
        // 官方标 `uint64`,也见过字符串
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
        // 数字或字符串都认
        duration = (try? container.decode(Double.self, forKey: .duration))
            ?? (try? container.decode(String.self, forKey: .duration)).flatMap(Double.init)
    }

    /// 秒。条目级 `duration` 优先,`media_info` 只是兼容
    var durationSeconds: Double? { duration ?? mediaInfo?.durationSeconds }

    /// `fs_id` 或 `path` 缺失时为 nil,由调用方跳过
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
            // 服务端对目录固定给 `size: 0`,不是真实大小
            sizeBytes: isDirectory ? nil : size,
            isDirectory: isDirectory,
            category: category,
            modifiedAt: serverMTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            thumbnailURL: thumbs.flatMap { $0["url2"] ?? $0["url1"] ?? $0["url3"] }
                .flatMap(URL.init(string:))
        )
    }
}

/// `media_info` 嵌套形状,实测响应里没有,仅作兼容;时长看条目级 `duration`。⛔ 新字段不要往这里加。
struct BaiduPanMediaInfo: Decodable, Sendable, Equatable {
    /// 秒;`duration_ms` 会换算
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

/// 设备码授权第一步的响应(`BAIDU_PAN_API.md` §2.1)
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
            // 官方要求轮询间隔不低于 5 秒
            interval: max(interval ?? 5, 5)
        )
    }
}

/// 设备码换 token、授权码换 token、刷新三处同一形状(`BAIDU_PAN_API.md` §2.1)
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
        // §6:旧 `refresh_token` 刷新成功即失效,⛔ 不沿用;响应里没有新的就当授权不可用
        guard let refreshToken, !refreshToken.isEmpty else { return nil }
        return BaiduPanTokenBundle(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(expiresIn),
            scope: scope
        )
    }
}

/// OAuth 失败响应(`{"error":"invalid_grant","error_description":"..."}`)
struct BaiduPanOAuthErrorResponse: Decodable, Sendable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// 兜底 `errno` 信封:`streaming` 失败等不是 m3u8 文本的响应(`BAIDU_PAN_API.md` §4)
struct BaiduPanErrnoEnvelope: Decodable, Sendable {
    let errno: Int?
    let adTime: Int?
    let adToken: String?
    let ltime: Int?
    /// `show_msg`(列表 / 播放流)与 `errmsg`(`filemetas`)两个名字都要认
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
