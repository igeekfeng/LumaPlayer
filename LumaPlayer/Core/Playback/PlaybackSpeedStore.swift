import Foundation

/// 「同一部剧沿用同一个倍速」的内存记录。
///
/// 只活在本次 App 运行里:倍速是「这一部这次要怎么看」的临时意图,不是长期偏好,
/// 所以 ⛔ 不落 `UserDefaults`,重启 App 一律从 1× 开始。
///
/// 键是**服务器 + 剧集**。剧集取 `SeriesId`,同一部剧的每一集因此共用同一个倍速;
/// 电影等没有 `SeriesId` 的项退回自己的 `Id`(等价于「这一部」)。
/// 服务器一起进键是沿用「每台服务器完全隔离」—— 不同服务器上的 Item Id 可能撞车,
/// 不隔离会串台。
@MainActor
final class PlaybackSpeedStore {

    /// 同一部剧的判定键(`SeriesId` 优先)。纯函数,单测直接引用。
    static func scopeID(for item: EmbyItem) -> String {
        item.seriesID ?? item.id
    }

    /// 记住 `item` 所属剧集的倍速。
    ///
    /// 1× 等于「没设过」,直接删条目:用户手动调回正常速度后,
    /// 这部剧后面的集数不该再自己弹回他之前设过的高倍速。
    func remember(_ speed: Double, for item: EmbyItem, on server: ServerProfile) {
        let key = Key(serverID: server.id, scopeID: Self.scopeID(for: item))
        if speed == 1 {
            speeds.removeValue(forKey: key)
        } else {
            speeds[key] = speed
        }
    }

    /// `item` 所属剧集记下的倍速;没设过时为 nil(1× 那个默认值由调用方补)。
    func speed(for item: EmbyItem, on server: ServerProfile) -> Double? {
        speeds[Key(serverID: server.id, scopeID: Self.scopeID(for: item))]
    }

    private var speeds: [Key: Double] = [:]

    private struct Key: Hashable {
        let serverID: UUID
        let scopeID: String
    }
}
