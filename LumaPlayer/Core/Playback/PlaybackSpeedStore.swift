import Foundation

/// 「同一部剧沿用同一个倍速」的判定键(来源无关)。分两段而不拼成字符串:百度路径本身含 `/`。
struct PlaybackSpeedScope: Hashable, Sendable {

    /// 跟谁隔离:Emby 是 `ServerProfile.id`;百度只有一份授权,取常量。
    let isolation: String

    /// 算不算同一部:Emby 是 `SeriesId`(电影退化成 `Id`);百度是剧目录或 `fs_id`。
    let content: String
}

extension PlaybackSpeedScope {

    static func emby(serverID: UUID, item: EmbyItem) -> PlaybackSpeedScope {
        PlaybackSpeedScope(
            isolation: serverID.uuidString,
            content: PlaybackSpeedStore.scopeID(for: item))
    }

    /// 是剧集(有换集队列)取剧目录,换集、换季(`第1季` → `第2季` 同属剧目录)都沿用;
    /// 否则取 `fs_id` —— ⛔ 不能用目录,同目录下几部电影会互相串倍速。
    static func baiduPan(file: BaiduPanFile, isEpisodeSeries: Bool) -> PlaybackSpeedScope {
        PlaybackSpeedScope(
            isolation: baiduIsolation,
            content: isEpisodeSeries
                ? BaiduPanPath.seriesDirectory(ofFilePath: file.path)
                : String(file.fsID))
    }

    static let baiduIsolation = "baidu-pan"

    /// 口径同百度,但按来源隔离(两个来源里同名剧目录不是同一部)。
    static func localFolder(
        sourceID: UUID, file: BaiduPanFile, isEpisodeSeries: Bool
    ) -> PlaybackSpeedScope {
        PlaybackSpeedScope(
            isolation: "local|\(sourceID.uuidString)",
            content: isEpisodeSeries
                ? BaiduPanPath.seriesDirectory(ofFilePath: file.path)
                : String(file.fsID))
    }
}

/// 「同一部剧沿用同一个倍速」的内存记录。倍速是临时意图,⛔ 不落 `UserDefaults`,重启从 1× 开始。
@MainActor
final class PlaybackSpeedStore {

    /// `nonisolated`:只读入参,`PlaybackSpeedScope.emby` 会在任意隔离域调它。
    nonisolated static func scopeID(for item: EmbyItem) -> String {
        item.seriesID ?? item.id
    }

    /// 1× 等于没设过,删条目,后面的集不再弹回之前的高倍速。
    func remember(_ speed: Double, for scope: PlaybackSpeedScope) {
        if speed == 1 {
            speeds.removeValue(forKey: scope)
        } else {
            speeds[scope] = speed
        }
    }

    /// 没设过为 nil,默认值由调用方补。
    func speed(for scope: PlaybackSpeedScope) -> Double? {
        speeds[scope]
    }

    private var speeds: [PlaybackSpeedScope: Double] = [:]
}
