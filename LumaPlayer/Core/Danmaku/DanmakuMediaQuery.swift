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
///   ⚠️ 弹弹play 的文件名解析对这种形状的命中率**未在真实服务验证**(`KNOWN_ISSUES.md` Q45)。
///   手动选一次之后按剧记住作品(`seriesKey`),后续集数不再依赖它。
/// - **Hash**:接口要「文件前 16 MB 的 MD5」。两路来源都只能经网络流拿到字节,
///   为了匹配多拉 16 MB(对别人的 Emby / 百度配额都是负担)不划算 → 不算真实 Hash,
///   按服务端的硬要求填 32 位占位串(`DandanplayMatchRequest.placeholderFileHash`),仍只用 `fileNameOnly`。
struct DanmakuMediaQuery: Sendable, Equatable {

    /// 这**一集 / 一部**的绑定键:用户手选过的弹幕库按它记住。
    let itemKey: String
    /// 这**一部剧**的绑定键:选过一集后按它记住作品,其余集按集号自动对上。
    /// nil = 不是剧集(电影 / 单条视频),或认不出集号。
    let seriesKey: String?
    /// 集号(用于在作品的剧集列表里对上 `episodeNumber`)
    let episodeNumber: Int?
    /// 给 `/match` 的文件名(不含目录与扩展名)
    let matchFileName: String
    /// 文件大小(字节);未知为 nil
    let fileSize: Int64?
    /// 手动搜索框的初始关键词(剧名 / 片名)
    let searchKeyword: String

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
                matchFileName: isEpisode
                    ? synthesizedEpisodeName(series: keyword, season: item.parentIndexNumber, episode: item.indexNumber)
                    : item.name,
                fileSize: nil,
                searchKeyword: keyword)
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
                matchFileName: base,
                fileSize: file.sizeBytes.flatMap { Int64(exactly: $0) },
                searchKeyword: parsed.title.isEmpty ? base : parsed.title)
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
