import Foundation

/// 播放页上「可切换的一集」,来源无关:播放页(上一集 / 下一集 / 选集面板)⛔ 不按来源分支。
struct PlaybackEpisode: Sendable, Equatable, Identifiable {
    /// 来源内 id(Emby = `ItemId`;百度 = `fs_id`)
    let id: String
    /// 「S1E2」/「第 3 集」;认不出就是 nil(⛔ 不占位)
    let label: String?
    /// Emby = 集名;百度 = 集名,没有时是剧名
    let title: String
    let source: PlaybackSource
    /// 本地续播库的展示快照来源(百度有;Emby 走服务端进度,为 nil)。
    /// 换集时靠它补记续播信息,⛔ 不再列一遍网盘(配额 `docs/BAIDU_PAN_API.md` §7)。
    let resumeItem: SourceItem?
    /// 选集面板封面(16:9 剧照优先);nil = 无图,降级成占位图。
    /// 百度侧没配 TMDB token 时没有逐集剧照(`docs/KNOWN_ISSUES.md`)。
    let poster: ImageDescriptor?
    /// 同目录外挂字幕(百度侧;Emby 恒为空)。装配队列那一刻才有兄弟文件列表,
    /// 不随队列带过去就得每集重列网盘。
    let subtitleFiles: [BaiduPanFile]

    init(
        id: String,
        label: String?,
        title: String,
        source: PlaybackSource,
        resumeItem: SourceItem? = nil,
        poster: ImageDescriptor? = nil,
        subtitleFiles: [BaiduPanFile] = []
    ) {
        self.id = id
        self.label = label
        self.title = title
        self.source = source
        self.resumeItem = resumeItem
        self.poster = poster
        self.subtitleFiles = subtitleFiles
    }
}

/// 本次播放可切换的有序剧集队列,上一集 / 下一集 / 选集面板的唯一数据源。
///
/// 百度由浏览页用当前目录已列条目装配(零额外请求);Emby 由播放页查当前季分集。
/// 换集时队列原样带进新请求。
struct EpisodeQueue: Sendable, Equatable {
    /// Emby 按服务端返回序;百度按浏览页当前排序
    let episodes: [PlaybackEpisode]
    /// nil / 越界 = 定位不到(上一集 / 下一集都为空)
    let currentIndex: Int?

    init(episodes: [PlaybackEpisode], currentIndex: Int?) {
        self.episodes = episodes
        self.currentIndex = currentIndex
    }

    var current: PlaybackEpisode? {
        guard let currentIndex, episodes.indices.contains(currentIndex) else { return nil }
        return episodes[currentIndex]
    }

    /// ⛔ 不绕回末集。
    var previous: PlaybackEpisode? {
        guard let currentIndex, episodes.indices.contains(currentIndex), currentIndex > 0 else {
            return nil
        }
        return episodes[currentIndex - 1]
    }

    var next: PlaybackEpisode? {
        guard let currentIndex, episodes.indices.contains(currentIndex),
              episodes.indices.contains(currentIndex + 1) else { return nil }
        return episodes[currentIndex + 1]
    }

    /// 成员不变,只挪当前下标。不在队列里(如 Emby 跨季边界集)返回 nil,由新播放页重新定位。
    func selecting(_ episode: PlaybackEpisode) -> EpisodeQueue? {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }) else { return nil }
        return EpisodeQueue(episodes: episodes, currentIndex: index)
    }
}
