import Foundation

/// 正在播的视频在弹幕侧的身份与匹配线索(纯函数构造)。`DanmakuService` 只认它,⛔ 不回头判断来源。
///
/// - 文件树(百度 / 115 / 本地文件夹):**作品名取库里条目的剧名**(`seriesTitle` / `SourceItem.title`),
///   ⛔ 不用单集文件名 —— 两者常不是一回事(语言、发布名、`01.mp4` 这种只有集号的存法),
///   按文件名搜弹幕库搜不到,还会把这一集当成电影(`DANMAKU.md` §3)。集号 / 季号 / TMDB id 同理取条目上的。
///   `/match` 的 `fileName` 仍是真实文件名(`DANDANPLAY_API.md` §2 的字段语义)。
/// - Emby:不用 `MediaSource.Path`(`API_CONTRACT.md` 4.3),合成 `剧名 S01E03`;手选一次后按剧记住作品。
/// - TMDB ID(`ProviderIds`,`API_CONTRACT.md` 3.4):名字对不上时走 `/search/episodes?tmdbId=`
///   (`DANMAKU.md` §6)。没有就是 nil,⛔ 不猜。
/// - Hash 见 `DanmakuFingerprint`。
struct DanmakuMediaQuery: Sendable, Equatable {

    /// 这一集 / 一部的绑定键。
    let itemKey: String
    /// 整部剧的绑定键;nil = 不是剧集或认不出集号。
    let seriesKey: String?
    let episodeNumber: Int?
    /// nil = 不知道是第几季(⛔ 不填 1 冒充)
    let seasonNumber: Int?
    /// 作品名:标题软校验用,去掉年份后作手动搜索框初始值。
    /// 文件树来源取**剧名**(`LibraryItemIdentity`),⛔ 不是单集文件名。
    let title: String
    let isMovie: Bool
    let tmdbID: Int?
    /// 不含目录与扩展名
    let matchFileName: String
    /// 字节
    let fileSize: Int64?

    var searchKeyword: String { DanmakuSearchKeyword.removingYear(title) }

    var matcherTarget: DanmakuCandidateMatcher.Target {
        DanmakuCandidateMatcher.Target(
            title: title, episodeNumber: episodeNumber, seasonNumber: seasonNumber,
            isFinalSeason: isFinalSeason, isMovie: isMovie)
    }

    /// Emby 没有这个字段,只能从文件名解析
    let isFinalSeason: Bool

    init(
        itemKey: String,
        seriesKey: String?,
        episodeNumber: Int?,
        seasonNumber: Int? = nil,
        title: String,
        isMovie: Bool = false,
        isFinalSeason: Bool = false,
        tmdbID: Int? = nil,
        matchFileName: String,
        fileSize: Int64?
    ) {
        self.itemKey = itemKey
        self.seriesKey = seriesKey
        self.episodeNumber = episodeNumber
        self.seasonNumber = seasonNumber
        self.title = title
        self.isMovie = isMovie
        self.isFinalSeason = isFinalSeason
        self.tmdbID = tmdbID
        self.matchFileName = matchFileName
        self.fileSize = fileSize
    }

    static func make(
        for source: PlaybackSource,
        libraryItem: LibraryItemIdentity? = nil
    ) -> DanmakuMediaQuery {
        switch source {
        case .emby(let server, let item):
            let isolation = "emby|\(server.id.uuidString)"
            let isEpisode = item.seriesID != nil && item.indexNumber != nil
            let keyword = (item.seriesName?.isEmpty == false ? item.seriesName : nil) ?? item.name
            return DanmakuMediaQuery(
                itemKey: "\(isolation)|\(item.id)",
                seriesKey: isEpisode ? item.seriesID.map { "\(isolation)|series:\($0)" } : nil,
                episodeNumber: isEpisode ? item.indexNumber : nil,
                seasonNumber: isEpisode ? item.parentIndexNumber : nil,
                title: keyword,
                isMovie: item.kind == .movie,
                tmdbID: item.tmdbID,
                matchFileName: isEpisode
                    ? synthesizedEpisodeName(
                        series: keyword, season: item.parentIndexNumber, episode: item.indexNumber)
                    : item.name,
                fileSize: nil)
        case .baiduPan(let file):
            // 百度的键没有来源段:一份授权下 `fs_id` 全局唯一,且已有绑定都是这个形状,⛔ 不改
            return fileQuery(file, isolation: "baidu", libraryItem: libraryItem)
        case .pan115(let file):
            // 同百度:一份 Cookie 对应一个网盘,`fid` 在网盘内唯一,键里不带来源段
            return fileQuery(file, isolation: "pan115", libraryItem: libraryItem)
        case .localFolder(let file, let source):
            // 本地 id 只在本来源内唯一:来源 id 进键,删来源时按前缀清
            return fileQuery(
                file, isolation: "local|\(source.id.uuidString)", libraryItem: libraryItem)
        }
    }

    /// 文件树来源。作品名 / 集号 / 季号 / TMDB id 优先取片库条目(`libraryItem`),⛔ 不从单集文件名反推。
    ///
    /// `libraryItem` 为 nil 时(调用方没带条目,如「继续观看」卡片重建的请求)退回按文件名解析 ——
    /// 那是**降级**,不是等价路径:文件名与剧名不是一回事时就是它搜不到。
    ///
    /// `matchFileName` 仍是真实文件名:那是 `/match` 的字段语义(`DANDANPLAY_API.md` §2),服务端拿它
    /// 比 Hash 记录、并按发布名做模糊匹配 —— 发布名常是另一套语言,换成剧名只会更差。
    private static func fileQuery(
        _ file: BaiduPanFile,
        isolation: String,
        libraryItem: LibraryItemIdentity?
    ) -> DanmakuMediaQuery {
        let base = BaiduPanMetadataSynthesizer.baseName(file.name)
        let parsed = BaiduPanMetadataSynthesizer.parse(name: file.name)
        let episode = libraryItem?.episodeNumber ?? parsed.episode
        let season = libraryItem?.seasonNumber ?? parsed.season
        // 片库认定是剧集 → 不是电影。否则沿用「认不出集号 / 季号就算电影」的旧判据:
        // `灵笼/第1季/07.mp4` 这种单集名里没有集号,按文件名判会把它当成一部叫「07」的电影
        let isMovie = libraryItem?.isEpisode == true ? false : episode == nil && season == nil
        return DanmakuMediaQuery(
            itemKey: "\(isolation)|fsid:\(file.fsID)",
            // 同一目录 = 同一部剧(同 `ManualMarkersScope`,只认强信号 `episode`)
            seriesKey: episode == nil
                ? nil : "\(isolation)|dir:\((file.path as NSString).deletingLastPathComponent)",
            episodeNumber: episode,
            seasonNumber: season,
            title: libraryItem?.title ?? (parsed.title.isEmpty ? base : parsed.title),
            isMovie: isMovie,
            tmdbID: libraryItem?.tmdbID ?? parsed.tmdbID,
            matchFileName: base,
            fileSize: file.sizeBytes.flatMap { Int64(exactly: $0) })
    }

    /// `剧名 S01E03`;不知道季号时 `剧名 03`。
    static func synthesizedEpisodeName(series: String, season: Int?, episode: Int?) -> String {
        guard let episode else { return series }
        let ep = String(format: "%02d", episode)
        guard let season else { return "\(series) \(ep)" }
        return "\(series) S\(String(format: "%02d", season))E\(ep)"
    }
}
