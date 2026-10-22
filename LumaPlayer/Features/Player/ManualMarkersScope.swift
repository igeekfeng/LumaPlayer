import Foundation

/// 手动片头 / 片尾的共用范围键:同一部剧的每一集共用一份,不同剧不串。
///
/// - Emby:`SeriesId`,没有则用自己的 `Id`(同 `PlaybackSpeedStore.scopeID`);服务器 id 进键,防跨服务器撞 Id。
/// - 百度 / 本地文件夹:没有 `SeriesId`,文件名明确是一集时按父目录归组,否则按文件自己。
///   只取强信号(`parse(name:).episode` 或纯集号 `01.mp4`);⛔ 不用 `bareEpisodeNumber` 的弱信号
///   (`300.1080p.BluRay.mkv` 会被误判,且它要求同目录成串,播放期拿不到)。
///   代价:同一目录混着多部剧时会被当成同一部,只能靠播放页菜单清除。
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
            // 来源 id 进键:两个来源里同名目录不是同一部剧
            let isolation = "local|\(source.id.uuidString)"
            if isEpisodeLike(file) {
                return "\(isolation)|\((file.path as NSString).deletingLastPathComponent)"
            }
            return "\(isolation)|fsid:\(file.fsID)"
        }
    }

    private static func isEpisodeLike(_ file: BaiduPanFile) -> Bool {
        if BaiduPanMetadataSynthesizer.parse(name: file.name).episode != nil { return true }
        let base = BaiduPanMetadataSynthesizer.baseName(file.name)
            .trimmingCharacters(in: .whitespaces)
        // 纯集号 1–3 位;4 位是年份的形状
        return (1...3).contains(base.count)
            && base.allSatisfy { $0.isASCII && $0.isNumber }
            && (Int(base) ?? 0) > 0
    }
}
