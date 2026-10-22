import Foundation

/// 正在播的视频在弹幕侧的身份与匹配线索(纯函数构造)。`DanmakuService` 只认它,⛔ 不回头判断来源。
///
/// - 百度 / 本地文件夹:真实文件名去扩展名直接给 `/match`。
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
    let seasonNumber: Int?
    /// 作品名(标题软校验 + 手动搜索框初始值)
    let title: String
    let isMovie: Bool
    let tmdbID: Int?
    /// 不含目录与扩展名
    let matchFileName: String
    /// 字节
    let fileSize: Int64?

    var searchKeyword: String { title }

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

    static func make(for source: PlaybackSource) -> DanmakuMediaQuery {
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
            return fileQuery(file, isolation: "baidu")
        case .localFolder(let file, let source):
            // 本地 id 只在本来源内唯一:来源 id 进键,删来源时按前缀清
            return fileQuery(file, isolation: "local|\(source.id.uuidString)")
        }
    }

    private static func fileQuery(_ file: BaiduPanFile, isolation: String) -> DanmakuMediaQuery {
        let base = BaiduPanMetadataSynthesizer.baseName(file.name)
        let parsed = BaiduPanMetadataSynthesizer.parse(name: file.name)
        let episode = parsed.episode
        return DanmakuMediaQuery(
            itemKey: "\(isolation)|fsid:\(file.fsID)",
            // 同一目录 = 同一部剧(同 `ManualMarkersScope`,只认强信号 `parsed.episode`)
            seriesKey: episode == nil
                ? nil : "\(isolation)|dir:\((file.path as NSString).deletingLastPathComponent)",
            episodeNumber: episode,
            seasonNumber: parsed.season,
            title: parsed.title.isEmpty ? base : parsed.title,
            isMovie: episode == nil && parsed.season == nil,
            tmdbID: parsed.tmdbID,
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
