import Foundation

/// 一个弹幕来源:内置的官方弹弹play,或用户添加的自建弹弹play 兼容服务(如 danmu_api)。
///
/// 各来源的 `episodeId` / `animeId` 是各自的编号,同一个数字在两个来源里是两部不同的作品 ——
/// 绑定与弹幕缓存都按 `id` 分开存(`DanmakuBindingStore` / `DanmakuCommentCache`)。
struct DanmakuSource: Sendable, Equatable, Hashable, Identifiable {

    enum Kind: Sendable, Equatable, Hashable {
        /// `api.dandanplay.net`,要 AppId / AppSecret 签名
        case official
        /// 根地址带令牌路径前缀,不签名
        case custom(baseURL: String)
    }

    let id: String
    let name: String
    let kind: Kind

    /// 官方的 id 固定,⛔ 不改:绑定文件与缓存文件名都靠它区分。
    static let officialID = "dandanplay"
    static let official = DanmakuSource(id: officialID, name: "弹弹play", kind: .official)

    var isOfficial: Bool { kind == .official }
}

/// 用户添加的自建服务。
struct DanmakuCustomSource: Codable, Sendable, Equatable, Identifiable {
    /// 建好后不变,绑定按它归属;改名 / 改地址都不换 id。
    let id: String
    var name: String
    /// 含令牌路径前缀,见 `DandanplayBase`
    var baseURL: String

    init(id: String = UUID().uuidString.lowercased(), name: String, baseURL: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
    }

    var source: DanmakuSource {
        DanmakuSource(id: id, name: name, kind: .custom(baseURL: baseURL))
    }
}

/// 弹幕来源配置,存凭据文件(`CredentialStore.danmakuSourceSettings`):
/// 自建服务的令牌写在地址路径里,按「不在 UserDefaults 里存 token」处理。
struct DanmakuSourceSettings: Codable, Sendable, Equatable {
    var customSources: [DanmakuCustomSource]
    /// nil 或指向已删除的来源 = 官方弹弹play
    var defaultSourceID: String?

    init(customSources: [DanmakuCustomSource] = [], defaultSourceID: String? = nil) {
        self.customSources = customSources
        self.defaultSourceID = defaultSourceID
    }

    /// 官方在前,自建按添加顺序。
    var sources: [DanmakuSource] {
        [.official] + customSources.map(\.source)
    }

    var defaultSource: DanmakuSource {
        defaultSourceID.flatMap(source(id:)) ?? .official
    }

    func source(id: String) -> DanmakuSource? {
        sources.first { $0.id == id }
    }
}
