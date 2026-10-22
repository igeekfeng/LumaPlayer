import Foundation

/// 「手动片头 / 片尾按哪一部剧共用」的范围键(纯函数,单测覆盖)。
///
/// 用户要求:**同一部剧的每一集共用一份**手动标注,不同剧之间不串。
///
/// - **Emby** 有可靠的剧身份 `SeriesId`,与 `PlaybackSpeedStore.scopeID` 同口径
///   (`SeriesId` 优先,电影等没有 `SeriesId` 的项退回自己的 `Id`,等价于「这一部」)。
///   服务器一起进键是沿用「每台服务器完全隔离」—— 不同服务器上的 Item Id 可能撞车。
/// - **百度 / 本地文件夹**没有 `SeriesId`(见 `docs/BAIDU_PAN_API.md`),只能用启发式:文件名明确是
///   剧集的一集时按**父目录**归组(同一目录 = 同一部剧),否则退回这一条文件自己。
///   ⚠️ 这是本功能唯一的近似,判据刻意只取**强信号**:`parse(name:).episode != nil`
///   (`S01E02` / `第12集`)或纯集号(`01.mp4`)。
///   ⛔ 不用 `bareEpisodeNumber` 的「集号 + 发布标记」弱信号 —— `300.1080p.BluRay.mkv`
///   会被误判成第 300 集;那个信号本来就要求「同目录成串」才成立,而播放期拿不到同目录列表。
///   代价:一整个目录里混着多部剧(或一堆电影)时会被当成同一部,只能靠播放页菜单清除。
enum ManualMarkersScope {

    static func key(for source: PlaybackSource) -> String {
        switch source {
        case .emby(let server, let item):
            return "emby|\(server.id.uuidString)|\(item.seriesID ?? item.id)"
        case .baiduPan(let file):
            if isEpisodeLike(file) {
                return "baidu|\((file.path as NSString).deletingLastPathComponent)"
            }
            return "baidu|fsid:\(file.fsID)"
        case .localFolder(let file, let source):
            // 与百度同一启发式;来源 id 进键 —— 两个来源里同名的目录不是同一部剧
            let isolation = "local|\(source.id.uuidString)"
            if isEpisodeLike(file) {
                return "\(isolation)|\((file.path as NSString).deletingLastPathComponent)"
            }
            return "\(isolation)|fsid:\(file.fsID)"
        }
    }

    /// 文件名能不能**明确**看出是剧集的一集(判据见类型注释)。
    private static func isEpisodeLike(_ file: BaiduPanFile) -> Bool {
        if BaiduPanMetadataSynthesizer.parse(name: file.name).episode != nil { return true }
        let base = BaiduPanMetadataSynthesizer.baseName(file.name)
            .trimmingCharacters(in: .whitespaces)
        // 纯集号:`01.mp4` / `1.mkv`(1–3 位;4 位是年份的形状,见 bareEpisodeNumber 的注释)
        return (1...3).contains(base.count)
            && base.allSatisfy { $0.isASCII && $0.isNumber }
            && (Int(base) ?? 0) > 0
    }
}
