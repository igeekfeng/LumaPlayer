import Foundation

/// 条目在**来源内**的身份。路由与图片缓存 key 都用它。
/// 与 `PlaybackSource` 分工:那边装要播的全部东西(含重对象),这里只装身份,可进 `NavigationStack` path。
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

/// 条目的媒体分类。⛔ 判不出来就是 `.unknown` —— 不猜(`CLAUDE.md` 硬规则 4)。
enum SourceItemKind: String, Sendable, Equatable, Hashable {
    case movie
    case episode
    case video
    case audio
    /// 图片(`poster.jpg` 一类)。⚠️ 合成器**不**给它们成卡 —— 是封面来源,不是片单成员。
    case image
    case folder
    case unknown

    var isPlayable: Bool {
        switch self {
        case .movie, .episode, .video, .audio: return true
        case .image, .folder, .unknown: return false
        }
    }

    var isContainer: Bool { self == .folder }
}

/// 元数据的来源。用于诊断(标题是解析出来的还是服务端给的)与 UI 取舍(解析出的标题不冒充「官方名称」)。
enum MetadataOrigin: String, Sendable, Equatable, Hashable {
    case server
    /// 同目录的 `.nfo`。⚠️ 目前**没有生产者**:读它要先换 `dlink` 再下载,配额下不划算
    /// (见 `docs/BAIDU_PAN_API.md` 配额说明);契约先在场,免得将来接上时改动所有分支。
    case sidecarNFO
    case filename
    case none
}

/// 来源无关的媒体条目。⛔ 所有可选字段缺就是缺,不填假值(`CLAUDE.md` 硬规则 4)。
/// 百度只给文件名,所以 `overview` 恒为 nil、`year` 多半没有 —— 这不是缺陷,是如实。
struct SourceItem: Sendable, Equatable, Hashable, Identifiable {
    let ref: SourceItemRef
    /// 必有:Emby 是 `Name`;百度是去掉扩展名与发布组后缀的文件名
    let title: String
    let kind: SourceItemKind
    let overview: String?
    let year: Int?
    /// 名称里**显式写出**的 TMDB id(`一拳超人 (2015) {tmdbid-63926}`)。
    /// 来源有二:文件名 / 目录名的 `{tmdbid-N}` 标签(`extractExplicitTMDBID`,刮削层直接按 id 查,
    /// 跳过搜索与标题匹配),或刮削命中后回填(`withScrapedMetadata`),让下游不必再搜一次。
    /// ⚠️ 标签本身**不区分影 / 剧**,这一格只说「是这个 id」,查哪个端点由刮削层按上下文决定。
    let tmdbID: Int?
    /// 集号。`nil` = 不是剧集 / 不知道是第几集。
    /// 来源:文件名里的 `S01E02` / `第12集`,或**剧集文件夹结构**(`琅琊榜/01.mp4` ——
    /// 目录名给剧名,集号必须单独留一格,否则被 `title` 占掉就分不清了;见 `BaiduPanMetadataSynthesizer.mediaItem`)。
    let episodeNumber: Int?
    /// 季号。`nil` = 不知道是第几季。来源:文件名的 `Show.S02E07`,或**季文件夹**
    /// (`琅琊榜/第13季/01.mp4` —— 季号判错会拿第 1 季的分集剧照去配第 13 季的文件)。
    /// ⚠️ 解析不出来时**留 nil**,⛔ 不在模型层填 1 冒充;取哪一季由 `BaiduPanMetadataScraper` 决定。
    let seasonNumber: Int?
    /// 集名(`第 3 集` 的那个名字)。`nil` = 还不知道。
    /// ⚠️ 与 `title` **分开**:剧集文件夹结构下 `title` 是剧名,集名只有 TMDB 分集数据里有(未命中 / 未配 token 即 nil)。
    let episodeTitle: String?
    let durationSeconds: Double?
    /// 封面。nil = 这个条目没找到任何可用的图 → UI 降级成图标卡
    let poster: ImageDescriptor?
    let metadataOrigin: MetadataOrigin

    var id: SourceItemRef { ref }

    /// 播放 / 上报用的内容标识(Emby 是 ItemId,百度是 `fs_id`)
    var contentID: String { ref.itemID }

    /// 换一张封面。百度侧要先取 `dlink` 才有地址,而合成器是纯函数、不认识网络,
    /// 所以由 `BaiduPanSourceProvider` 取到地址后回填。
    func withPoster(_ poster: ImageDescriptor?) -> SourceItem {
        SourceItem(
            ref: ref,
            title: title,
            kind: kind,
            overview: overview,
            year: year,
            tmdbID: tmdbID,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            episodeTitle: episodeTitle,
            durationSeconds: durationSeconds,
            poster: poster,
            metadataOrigin: metadataOrigin
        )
    }

    /// 补上时长。百度 `method=list` 不给时长,要另问 `filemetas`(`needmedia=1`),
    /// 合成器不联网,故由 `BaiduPanSourceProvider` 批量取回后回填。
    /// ⚠️ 只补**原来没有值**的那一格:已由 `authoritativeDurationSeconds` 填过的不覆盖。
    func withDuration(_ seconds: Double?) -> SourceItem {
        guard let seconds, seconds > 0, durationSeconds == nil else { return self }
        return SourceItem(
            ref: ref,
            title: title,
            kind: kind,
            overview: overview,
            year: year,
            tmdbID: tmdbID,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            episodeTitle: episodeTitle,
            durationSeconds: seconds,
            poster: poster,
            metadataOrigin: metadataOrigin
        )
    }

    /// 补上**在线刮削**(TMDB)取回来的字段。⚠️ 只补**原来没有值**的那几个:本地合成出来的东西优先。
    /// ⛔ 封面不能被 TMDB 盖掉 —— 网盘目录里的 `poster.jpg` 是用户**故意**配的。
    /// - Parameter tmdbID: 搜索命中的 TMDB id。**回填它是为了下游**:详情页要按 id
    ///   取剧级信息与演职员(`TMDBSeriesProfile`)。名称里本来就写了显式 id 时以**原来的**为准。
    func withScrapedMetadata(
        poster: ImageDescriptor?,
        overview: String?,
        year: Int?,
        episodeTitle: String? = nil,
        tmdbID: Int? = nil
    ) -> SourceItem {
        SourceItem(
            ref: ref,
            title: title,
            kind: kind,
            overview: self.overview ?? overview,
            year: self.year ?? year,
            tmdbID: self.tmdbID ?? tmdbID,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            episodeTitle: self.episodeTitle ?? episodeTitle,
            durationSeconds: durationSeconds,
            poster: self.poster ?? poster,
            metadataOrigin: metadataOrigin
        )
    }
}
