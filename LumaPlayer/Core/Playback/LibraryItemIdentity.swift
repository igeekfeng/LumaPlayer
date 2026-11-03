import Foundation

/// 文件树来源(百度 / 115 / 本地文件夹)在播放期的**作品身份**:作品名、集号、季号、TMDB id。
/// 弹幕匹配 / 手动搜索 / 在线字幕搜索一律用它,⛔ 不从单集文件名反推(`docs/DANMAKU.md` §3)。
///
/// 网盘里同一部剧的各集文件名跟剧名常不是一回事:发布组命名、另一种语言、或者整个只有集号
/// (`灵笼/第1季/07.mp4`)。按单集名去搜弹幕库,剧名对不上就落空,纯集号还会被当成一部叫「07」的电影。
/// 以**剧集名称**为准。
///
/// 事实来自片库层已经算好的 `SourceItem`,⛔ 不在这里另起一套解析
/// (`BaiduPanMetadataSynthesizer` 按**整个目录**判定:集号可能只来自目录结构,`灵笼/01.mp4` 是第 1 集;
/// 剧集条目的 `title` 就是剧名)。
///
/// Emby 不用它:`SeriesName` / `IndexNumber` / `ProviderIds` 服务端直接给。
struct LibraryItemIdentity: Sendable, Equatable {

    /// 作品名。剧集 = 剧名,电影 / 单条视频 = 片名。
    let title: String
    /// 正片集号。nil = 不是某一集(电影 / 单条视频)
    let episodeNumber: Int?
    /// nil = 不知道是第几季(⛔ 不填 1 冒充)
    let seasonNumber: Int?
    /// `{tmdbid-N}` 或刮削回填的 id。名字对不上时走 `/search/episodes?tmdbId=`。
    let tmdbID: Int?
}

extension LibraryItemIdentity {

    /// 作品名取不到(条目没标题)时返回 nil,调用方退回按文件名解析。
    ///
    /// - Parameters:
    ///   - item: 片库条目。只有 `.episode` 才认集号 / 季号,与 `FileSourceViewModel.episodeQueue`
    ///     收进换集队列的判据一致。
    ///   - seriesTitle: 剧集详情页顶上那个剧名,比条目自己的标题更权威。只有剧集认它。
    ///     ⛔ 不要传单集标题 —— 那正是这里要规避的东西。
    init?(item: SourceItem, seriesTitle: String? = nil) {
        func trimmed(_ text: String?) -> String {
            (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let isEpisode = item.kind == .episode
        let knownSeries = isEpisode ? trimmed(seriesTitle) : ""
        let ownTitle = trimmed(item.title)
        guard let title = [knownSeries, ownTitle].first(where: { !$0.isEmpty }) else { return nil }
        self.title = title
        self.episodeNumber = isEpisode ? item.episodeNumber : nil
        self.seasonNumber = isEpisode ? item.seasonNumber : nil
        self.tmdbID = item.tmdbID
    }

    var isEpisode: Bool { episodeNumber != nil }
}
