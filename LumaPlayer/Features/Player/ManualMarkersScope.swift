import Foundation

/// 手动片头 / 片尾的共用范围键:同一部剧的每一集共用一份,不同剧不串。
///
/// - Emby:`SeriesId`,没有则用自己的 `Id`(同 `PlaybackSpeedStore.scopeID`);服务器 id 进键,防跨服务器撞 Id。
/// - 百度 / 本地文件夹:没有 `SeriesId`,是一集时按剧目录归组(同 `PlaybackSpeedScope`,换季也沿用),
///   否则按文件自己。判据二选一:调用方已知是剧集(`isEpisode`),或文件名给出强信号
///   (`parse(name:).episode` 或纯集号 `01.mp4`);⛔ 不用 `bareEpisodeNumber` 的弱信号
///   (`300.1080p.BluRay.mkv` 会被误判,且它要求同目录成串,播放期拿不到)。
///   代价:同一目录混着多部剧时会被当成同一部,只能靠播放页菜单清除。
enum ManualMarkersScope {

    /// - Parameter isEpisode: 播放页已知这是一集(`PlaybackRequest.isEpisodeSeries`)。
    ///   文件名不带集号的形状(`02-4K.mp4`)只看文件名判不出剧,靠它才按剧目录归组 ——
    ///   ⛔ 不能省:否则同一部剧的每一集各存一份,片头片尾不会跨集生效。
    static func key(for source: PlaybackSource, isEpisode: Bool = false) -> String {
        switch source {
        case .emby(let server, let item):
            return "emby|\(server.id.uuidString)|\(item.seriesID ?? item.id)"
        case .baiduPan(let file):
            return fileKey(file, isolation: "baidu", isEpisode: isEpisode)
        case .pan115(let file):
            // 115 只有一份 Cookie(一个网盘),隔离段与百度分开即可
            return fileKey(file, isolation: "pan115", isEpisode: isEpisode)
        case .quark(let file):
            // 夸克同样只有一份登录态(一个网盘),隔离段与另外两家分开
            return fileKey(file, isolation: "quark", isEpisode: isEpisode)
        case .localFolder(let file, let source):
            // 来源 id 进键:两个来源里同名目录不是同一部剧
            return fileKey(file, isolation: "local|\(source.id.uuidString)", isEpisode: isEpisode)
        }
    }

    /// 旧版本留下、需要迁移的键,按优先级排列(前面的整部剧共用,后面的只对一条文件生效):
    /// 1. 父目录键 —— 旧版本不认剧目录,季文件夹里的剧按季存;
    /// 2. `fsid:` 键 —— 旧版本判不出集号时按文件存(`02-4K.mp4`)。
    ///
    /// 空数组 = 没有旧形状(Emby 一直是剧范围键)。
    static func legacyKeys(for source: PlaybackSource) -> [String] {
        switch source {
        case .emby:
            return []
        case .baiduPan(let file):
            return legacyKeys(file, isolation: "baidu")
        case .pan115(let file):
            return legacyKeys(file, isolation: "pan115")
        case .quark(let file):
            return legacyKeys(file, isolation: "quark")
        case .localFolder(let file, let source):
            return legacyKeys(file, isolation: "local|\(source.id.uuidString)")
        }
    }

    private static func fileKey(
        _ file: BaiduPanFile, isolation: String, isEpisode: Bool
    ) -> String {
        guard isEpisode || isEpisodeLike(file) else { return "\(isolation)|fsid:\(file.fsID)" }
        return "\(isolation)|\(BaiduPanPath.seriesDirectory(ofFilePath: file.path))"
    }

    private static func legacyKeys(_ file: BaiduPanFile, isolation: String) -> [String] {
        [
            "\(isolation)|\((file.path as NSString).deletingLastPathComponent)",
            "\(isolation)|fsid:\(file.fsID)",
        ]
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
