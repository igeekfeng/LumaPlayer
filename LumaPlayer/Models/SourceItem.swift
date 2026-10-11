import Foundation

/// 条目在**来源内**的身份。路由与图片缓存 key 都用它。
///
/// 与 `PlaybackSource` 的分工:`PlaybackSource` 装的是「**要播这一项**」所需的
/// 全部东西(含 `EmbyItem` / `BaiduPanFile` 这类重对象);这里只装身份,
/// 可以安全地进 `NavigationStack` 的 path、当 `Identifiable` 的 id。
struct SourceItemRef: Sendable, Equatable, Hashable, Codable {
    let sourceID: UUID
    /// 来源内的 id:Emby 是 `ItemId`;百度是 `fs_id`
    let itemID: String

    init(sourceID: UUID, itemID: String) {
        self.sourceID = sourceID
        self.itemID = itemID
    }

    init(sourceID: UUID, fsID: UInt64) {
        self.sourceID = sourceID
        self.itemID = String(fsID)
    }
}

/// 条目的媒体分类。
///
/// ⛔ 判不出来就是 `.unknown` —— 不猜(`CLAUDE.md` 硬规则 4)。
enum SourceItemKind: String, Sendable, Equatable, Hashable {
    case movie
    case episode
    case video
    case audio
    /// 图片(百度目录里的 `poster.jpg` 一类)。
    /// ⚠️ 合成器**不**给它们成卡 —— 它们是封面来源,不是片单成员。
    /// 留着这个 case 是为了「这个文件确实存在且是图片」这件事有处安放。
    case image
    case folder
    case unknown

    /// 能不能直接播(目录与图片不行)
    var isPlayable: Bool {
        switch self {
        case .movie, .episode, .video, .audio: return true
        case .image, .folder, .unknown: return false
        }
    }

    /// 能不能进去(目录)
    var isContainer: Bool { self == .folder }
}

/// 元数据是从哪来的。
///
/// 用途有二:诊断(「这个标题是解析出来的还是服务端给的」),
/// 以及 UI 做取舍(文件名解析出来的标题不冒充「官方名称」)。
enum MetadataOrigin: String, Sendable, Equatable, Hashable {
    /// 服务端给的(Emby)
    case server
    /// 同目录的 `.nfo`(Kodi / Emby 风格 sidecar)。
    /// ⚠️ 目前**没有生产者**:读 `.nfo` 要先向百度换 `dlink` 再下载内容,
    /// 在配额下这笔账不划算(见 `docs/BAIDU_PAN_API.md` 的配额说明)。
    /// 契约先在场,免得将来接上时又要动一遍 `MetadataOrigin` 的所有分支。
    case sidecarNFO
    /// 从文件名解析出来的
    case filename
    /// 没有元数据可合成
    case none
}

/// 来源无关的媒体条目。
///
/// **所有可选字段缺就是缺**,⛔ 不填假值(`CLAUDE.md` 硬规则 4;
/// 与 `EmbyItem`「`Name` 不是文件名」的教训一致)。百度只给文件名,
/// 所以它的 `overview` 恒为 nil、`year` 只有能从文件名解析出来时才有值 ——
/// 这不是缺陷,是**如实**。
struct SourceItem: Sendable, Equatable, Hashable, Identifiable {
    let ref: SourceItemRef
    /// 必有:Emby 是 `Name`;百度是去掉扩展名与发布组后缀的文件名
    let title: String
    let kind: SourceItemKind
    let overview: String?
    let year: Int?
    let durationSeconds: Double?
    /// 封面。nil = 这个条目没找到任何可用的图 → UI 降级成图标卡
    let poster: ImageDescriptor?
    let metadataOrigin: MetadataOrigin

    var id: SourceItemRef { ref }

    /// 播放 / 上报用的内容标识(Emby 是 ItemId,百度是 `fs_id`)
    var contentID: String { ref.itemID }

    /// 换一张封面。
    ///
    /// 为什么需要它:百度侧的封面要**先取 `dlink` 才有地址**,而合成器是纯函数、
    /// 不认识网络。所以合成器先出条目(`poster == nil`),再由
    /// `BaiduPanSourceProvider` 批量取地址后回填 —— 那里就用这个方法。
    func withPoster(_ poster: ImageDescriptor?) -> SourceItem {
        SourceItem(
            ref: ref,
            title: title,
            kind: kind,
            overview: overview,
            year: year,
            durationSeconds: durationSeconds,
            poster: poster,
            metadataOrigin: metadataOrigin
        )
    }
}
