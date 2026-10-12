import Foundation

/// 播放页上「可切换的一集」——**来源无关**。
///
/// Emby 与百度网盘都把自己的剧集折成它,于是播放页(上一集 / 下一集 / 选集面板)
/// ⛔ 不再按来源分支 —— 与 `PlaybackSessionPreparing` / `PlaybackReporting` 同一条分层:
/// 新增来源时改的是组合根,不是播放页。
struct PlaybackEpisode: Sendable, Equatable, Identifiable {
    /// 来源内 id(Emby = `ItemId`;百度 = `fs_id`)
    let id: String
    /// 「S1E2」/「第 3 集」这类集标识;认不出就是 nil(⛔ 不占位,同 `EmbyItem.episodeLabel`)
    let label: String?
    /// 列表里显示的名字(Emby = 集名;百度 = 集名,没有集名时是剧名)
    let title: String
    /// 播它所需的**完整来源**(Emby 带 server + item;百度带 file)
    let source: PlaybackSource
    /// 本地续播库要记的展示快照来源。
    ///
    /// 百度来源带它(标题 / 封面就来自这个 `SourceItem`);Emby 走服务端进度,为 nil。
    /// 换集时靠它补记「继续观看」的展示信息 —— ⛔ 不回头再列一遍网盘(未审核应用
    /// 配额 10 次/小时,见 `docs/BAIDU_PAN_API.md`)。
    let resumeItem: SourceItem?
    /// 选集面板里的封面(16:9 剧照优先)。
    ///
    /// 来源:Emby 是分集自己的 `Primary`(剧照截图);百度是 `SourceItem.poster`
    /// —— 同目录的同名图,或 TMDB 刮回来的分集剧照。nil = 没有可用的图,
    /// 面板按 `PosterImage` 的既定处置降级成占位图(⛔ 不假装有封面)。
    ///
    /// ⚠️ 百度侧**没配 TMDB token 时逐集剧照是拿不到的**:合成器只给「目录卡片」
    /// 挑同目录封面,不逐集配(`docs/KNOWN_ISSUES.md`)。Emby 不受影响。
    let poster: ImageDescriptor?

    init(
        id: String,
        label: String?,
        title: String,
        source: PlaybackSource,
        resumeItem: SourceItem? = nil,
        poster: ImageDescriptor? = nil
    ) {
        self.id = id
        self.label = label
        self.title = title
        self.source = source
        self.resumeItem = resumeItem
        self.poster = poster
    }
}

/// 本次播放**可切换的剧集队列**(有序)。
///
/// 装配点按来源:
/// - 百度 —— 浏览页在起播那一刻用**当前目录已列的条目**装配(零额外请求);
/// - Emby —— 播放页查当前季的分集(既有 `Shows/{Id}/Episodes`)。
///
/// 队列是「同剧兄弟集」这一个概念的**唯一载体**:上一集 / 下一集是它的相邻项,
/// 选集面板列的是它的全部成员。换集时队列原样带进新请求,所以百度不必为了
/// 「下一集」再列一次网盘。
struct EpisodeQueue: Sendable, Equatable {
    /// 有序成员(Emby 按服务端返回序;百度按浏览页当前排序)
    let episodes: [PlaybackEpisode]
    /// 当前这一集在 `episodes` 里的下标;nil / 越界 = 定位不到(上一集 / 下一集都为空)
    let currentIndex: Int?

    init(episodes: [PlaybackEpisode], currentIndex: Int?) {
        self.episodes = episodes
        self.currentIndex = currentIndex
    }

    var current: PlaybackEpisode? {
        guard let currentIndex, episodes.indices.contains(currentIndex) else { return nil }
        return episodes[currentIndex]
    }

    /// 上一集;已是首集(或定位不到)时为 nil —— ⛔ 不绕回末集。
    var previous: PlaybackEpisode? {
        guard let currentIndex, episodes.indices.contains(currentIndex), currentIndex > 0 else {
            return nil
        }
        return episodes[currentIndex - 1]
    }

    /// 下一集;已是末集(或定位不到)时为 nil。
    var next: PlaybackEpisode? {
        guard let currentIndex, episodes.indices.contains(currentIndex),
              episodes.indices.contains(currentIndex + 1) else { return nil }
        return episodes[currentIndex + 1]
    }

    /// 换到某一集之后的队列:成员不变,只把当前下标挪过去。
    /// 这一集不在队列里(如 Emby 跨季边界集)时返回 nil —— 由新播放页自己重新定位。
    func selecting(_ episode: PlaybackEpisode) -> EpisodeQueue? {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }) else { return nil }
        return EpisodeQueue(episodes: episodes, currentIndex: index)
    }
}
