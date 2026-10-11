import Foundation

/// 一个**播放来源**的身份与**非敏感**配置。
///
/// 这是「来源抽象」改造的核心类型:Emby 与百度网盘是它的两个 case,
/// 将来加第三个来源(其它网盘 / 本地目录 / WebDAV)= 加一个 case,
/// 编译器会逼你处理所有 `switch` 点。
///
/// ⚠️ **只放非敏感配置**:token / 密码 / AppKey 一律进凭据文件
/// (`CredentialStore`),与本类型一起持久化的东西可以安全出现在诊断输出里
/// (与 `ServerProfile` 同一条约定)。
///
/// 为什么 `emby` 直接复用 `ServerProfile` 而不改名:那个类型在 39 个文件里,
/// 改名是零收益的机械劳动 —— 见 `docs/SOURCE_ABSTRACTION_PLAN.md` §6.2。
enum SourceProfile: Codable, Sendable, Equatable, Hashable, Identifiable {
    case emby(ServerProfile)
    case baiduPan(BaiduPanSource)

    var id: UUID {
        switch self {
        case .emby(let profile): return profile.id
        case .baiduPan(let source): return source.id
        }
    }

    var displayName: String {
        switch self {
        case .emby(let profile): return profile.displayName
        case .baiduPan(let source): return source.displayName
        }
    }

    /// 最近使用时间。**归注册表独占**,只有 `SourceRegistry.markUsed` 能改
    /// (与旧的 `ServerProfile.lastUsedAt` 语义一致)。
    var lastUsedAt: Date? {
        switch self {
        case .emby(let profile): return profile.lastUsedAt
        case .baiduPan(let source): return source.lastUsedAt
        }
    }

    /// 返回替换了 `lastUsedAt` 的副本。
    ///
    /// 枚举是值类型、不能有存储属性,所以注册表改这个字段时必须整条替换。
    func settingLastUsedAt(_ date: Date?) -> SourceProfile {
        switch self {
        case .emby(var profile):
            profile.lastUsedAt = date
            return .emby(profile)
        case .baiduPan(var source):
            source.lastUsedAt = date
            return .baiduPan(source)
        }
    }

    /// 列表里给用户看的一句话来源类型。
    var kindDescription: String {
        switch self {
        case .emby: return "Emby 服务器"
        case .baiduPan: return "百度网盘"
        }
    }

    /// Emby 来源才有(其它来源返回 nil)。
    /// 与 `PlaybackSource` 上同名访问器分工相同:把 `switch` 收在一处。
    var embyServer: ServerProfile? {
        if case .emby(let profile) = self { return profile }
        return nil
    }

    var baiduPanSource: BaiduPanSource? {
        if case .baiduPan(let source) = self { return source }
        return nil
    }
}

/// 百度网盘来源。一个 App 对应开放平台上一个应用、一个用户授权一次
/// (也就是「只有一份」,不像 Emby 那样按服务器分)。
///
/// ⚠️ **不含任何密钥**:AppKey / SecretKey / token / 片库根都在凭据文件里,
/// 按 `id` 取(见 `CredentialStore` 里百度那一段)。
struct BaiduPanSource: Codable, Sendable, Equatable, Hashable {
    let id: UUID
    var displayName: String

    /// 应用目录名(开放平台控制台里的「应用名称」)。
    /// 第三方应用只能访问 `/apps/{应用目录名}` 下的文件 —— 这个值就是那一段,
    /// 必须与开放平台里建应用时填的名字完全一致。
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
