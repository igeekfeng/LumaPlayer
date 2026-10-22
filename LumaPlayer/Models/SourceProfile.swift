import Foundation

/// 一个**播放来源**的身份与**非敏感**配置。
/// 加来源(其它网盘 / WebDAV)= 加一个 case,编译器会逼你处理所有 `switch` 点。
/// ⚠️ **只放非敏感配置**:token / 密码 / AppKey 一律进凭据文件(`CredentialStore`);
/// 与本类型一起持久化的东西会出现在诊断输出里(与 `ServerProfile` 同一条约定)。
enum SourceProfile: Codable, Sendable, Equatable, Hashable, Identifiable {
    case emby(ServerProfile)
    case baiduPan(BaiduPanSource)
    case localFolder(LocalFolderSource)

    var id: UUID {
        switch self {
        case .emby(let profile): return profile.id
        case .baiduPan(let source): return source.id
        case .localFolder(let source): return source.id
        }
    }

    var displayName: String {
        switch self {
        case .emby(let profile): return profile.displayName
        case .baiduPan(let source): return source.displayName
        case .localFolder(let source): return source.displayName
        }
    }

    /// 最近使用时间。**归注册表独占**,只有 `SourceRegistry.markUsed` 能改。
    var lastUsedAt: Date? {
        switch self {
        case .emby(let profile): return profile.lastUsedAt
        case .baiduPan(let source): return source.lastUsedAt
        case .localFolder(let source): return source.lastUsedAt
        }
    }

    /// 返回替换了 `lastUsedAt` 的副本(枚举是值类型,改一个字段就得整条替换)。
    func settingLastUsedAt(_ date: Date?) -> SourceProfile {
        switch self {
        case .emby(var profile):
            profile.lastUsedAt = date
            return .emby(profile)
        case .baiduPan(var source):
            source.lastUsedAt = date
            return .baiduPan(source)
        case .localFolder(var source):
            source.lastUsedAt = date
            return .localFolder(source)
        }
    }

    var kindDescription: String {
        switch self {
        case .emby: return "Emby 服务器"
        case .baiduPan: return "百度网盘"
        case .localFolder: return "本地文件夹"
        }
    }

    /// 只有 Emby 来源才非 nil。
    /// 与 `PlaybackSource` 上同名访问器分工相同:把 `switch` 收在一处。
    var embyServer: ServerProfile? {
        if case .emby(let profile) = self { return profile }
        return nil
    }

    var baiduPanSource: BaiduPanSource? {
        if case .baiduPan(let source) = self { return source }
        return nil
    }

    var localFolderSource: LocalFolderSource? {
        if case .localFolder(let source) = self { return source }
        return nil
    }

    /// 文件树来源(百度网盘 / 本地文件夹)才有 —— 它们共用一个浏览页(`FileSourceViewModel`)。
    var fileSource: FileSource? {
        switch self {
        case .emby: return nil
        case .baiduPan(let source): return .baiduPan(source)
        case .localFolder(let source): return .localFolder(source)
        }
    }
}

/// 百度网盘来源。一个 App 对应开放平台上一个应用、一个用户授权一次(只有一份,不像 Emby 按服务器分)。
/// ⚠️ **不含任何密钥**:AppKey / SecretKey / token / 片库根都在凭据文件里,按 `id` 取(见 `CredentialStore`)。
struct BaiduPanSource: Codable, Sendable, Equatable, Hashable {
    let id: UUID
    var displayName: String

    /// 应用目录名(开放平台控制台的「应用名称」)。第三方应用只能访问 `/apps/{应用目录名}` 下的文件,
    /// 必须与控制台里建应用时填的名字完全一致。
    var folderName: String

    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        displayName: String = "百度网盘",
        folderName: String,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.folderName = folderName
        self.lastUsedAt = lastUsedAt
    }
}

/// 本机上的一个文件夹(含外接盘 / 已挂载的网络卷)。
///
/// 沙盒下跨启动只能靠**安全作用域书签**(`bookmark`):下次启动解析它、
/// `startAccessingSecurityScopedResource()` 之后才读得到(`LocalFolderAccess`;entitlement `files.bookmarks.app-scope`)。
/// ⛔ 绝对路径(`lastKnownPath`)不能拿来访问 —— 沙盒不认路径。
/// ⚠️ 书签只在本机、本 App 内有效,与其余非敏感配置一起进注册表;它与 `lastKnownPath` 同一敏感级。
struct LocalFolderSource: Codable, Sendable, Equatable, Hashable {
    let id: UUID
    var displayName: String

    /// 安全作用域书签。⚠️ 系统报「书签陈旧」时会换一份新的写回来(`AppContainer.localFolderRoot`),所以可变。
    var bookmark: Data

    /// 上一次解析书签得到的绝对路径。**只用于展示**(来源列表 / 设置页),⛔ 不用于访问。
    var lastKnownPath: String

    /// 这棵目录树在 App 内的**根名**:条目路径一律是 `/{rootName}/…`(`rootPath`)。
    /// 不用绝对路径做前缀:外接盘换挂载点(`/Volumes/Disk` → `/Volumes/Disk 1`)、文件夹被挪位都会变,
    /// 而续播 / 隐藏 / 集数 / 刮削缓存这些记录要跟着「这个来源」走。
    /// 取文件夹名而不是常量:平铺在根上的剧集要靠父目录名认剧名(`BaiduPanMetadataSynthesizer` 判据 ②)。
    let rootName: String

    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        displayName: String,
        bookmark: Data,
        lastKnownPath: String,
        rootName: String,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.lastKnownPath = lastKnownPath
        self.rootName = rootName
        self.lastUsedAt = lastUsedAt
    }

    /// 目录树的根(`/{rootName}`)。浏览页能退到的最外层就是它。
    var rootPath: String { "/" + rootName }

    /// 从文件夹名取根名;卷根或取不出名字时退回固定名。⛔ 根名不能为空、不能含 `/`(否则 `rootPath` 会多出一层)。
    static func rootName(forFolderAt url: URL) -> String {
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "/", !name.contains("/") else { return "本地文件夹" }
        return name
    }
}
