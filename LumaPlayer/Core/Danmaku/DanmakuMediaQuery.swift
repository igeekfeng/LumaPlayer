import Foundation

/// 「这一条正在播的视频」在弹幕侧的身份与匹配线索(纯函数构造,单测覆盖)。
///
/// 播放层的 `PlaybackSource` 各来源语义不同,这里归一成弹幕匹配需要的几样东西,
/// `DanmakuService` 只认它,⛔ 不再回头判断是 Emby 还是百度。
///
/// ## 匹配线索从哪来
///
/// - **百度**:有真实文件名 → 去扩展名直接给 `/match`(这正是接口设计的输入)。
/// - **Emby**:`MediaSource.Path` 按 `API_CONTRACT.md` 4.3 **不用**,拿不到文件名 →
///   用剧名 + 季集**合成**一个场景命名风格的名字(`剧名 S01E03`)。
///   手动选一次之后按剧记住作品(`seriesKey`),后续集数不再依赖它。
/// - **TMDB ID**:`ProviderIds`(`API_CONTRACT.md` 3.4)里的语言无关身份。
///   文件名 / 合成名对不上时,`/search/episodes?tmdbId=` 是第二层保险
///   (`DANMAKU.md` §6)。没有就是 nil,⛔ 不猜。
/// - **Hash**:接口要「文件前 16 MB 的 MD5」。算真 Hash 要多拉 16 MB,
///   是否值得见 `DanmakuFingerprint` 的说明;拿不到就退回文件名匹配。
struct DanmakuMediaQuery: Sendable, Equatable {

    /// 这**一集 / 一部**的绑定键:用户手选过的弹幕库按它记住。
    let itemKey: String
    /// 这**一部剧**的绑定键:选过一集后按它记住作品,其余集按集号自动对上。
    /// nil = 不是剧集(电影 / 单条视频),或认不出集号。
    let seriesKey: String?
    /// 集号(用于在作品的剧集列表里对上 `episodeNumber`)
    let episodeNumber: Int?
    /// 季号(用于过滤「第二季第 5 话」与「第一季第 5 话」这类同名不同季的候选)
    let seasonNumber: Int?
    /// 作品名(标题软校验 + 手动搜索框初始值)
    let title: String
    /// 目标是电影(剧场版与剧集是不同作品)
    let isMovie: Bool
    /// TMDB ID;没有就是 nil
    let tmdbID: Int?
    /// 给 `/match` 的文件名(不含目录与扩展名)
    let matchFileName: String
    /// 文件大小(字节);未知为 nil
    let fileSize: Int64?

    /// 手动搜索框的初始关键词(剧名 / 片名)
    var searchKeyword: String { title }

    /// 匹配器要的目标事实(`DanmakuCandidateMatcher.Target`)。
    var matcherTarget: DanmakuCandidateMatcher.Target {
        DanmakuCandidateMatcher.Target(
            title: title, episodeNumber: episodeNumber, seasonNumber: seasonNumber,
            isFinalSeason: isFinalSeason, isMovie: isMovie)
    }

    /// 目标是最终季(Emby 没有这个字段,靠文件名解析;百度同理)
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
            let base = BaiduPanMetadataSynthesizer.baseName(file.name)
            let parsed = BaiduPanMetadataSynthesizer.parse(name: file.name)
            let episode = parsed.episode
            return DanmakuMediaQuery(
                itemKey: "baidu|fsid:\(file.fsID)",
                // 同一剧目录 = 同一部剧(与 `ManualMarkersScope` 同一启发式,只认强信号 `parsed.episode`)
                seriesKey: episode == nil
                    ? nil : "baidu|dir:\((file.path as NSString).deletingLastPathComponent)",
                episodeNumber: episode,
                seasonNumber: parsed.season,
                title: parsed.title.isEmpty ? base : parsed.title,
                isMovie: episode == nil && parsed.season == nil,
                tmdbID: parsed.tmdbID,
                matchFileName: base,
                fileSize: file.sizeBytes.flatMap { Int64(exactly: $0) })
        }
    }

    /// `剧名 S01E03`;不知道季号时 `剧名 03`。
    static func synthesizedEpisodeName(series: String, season: Int?, episode: Int?) -> String {
        guard let episode else { return series }
        let ep = String(format: "%02d", episode)
        guard let season else { return "\(series) \(ep)" }
        return "\(series) S\(String(format: "%02d", season))E\(ep)"
    }
}
