import Foundation

/// 「同一部剧沿用同一个倍速」的判定键(**来源无关**)。
///
/// 两段式的理由:两段的来源不同 —— 一截是「跟谁隔离」,一截是「算不算同一部」。
/// 揉成一个拼接字符串之后,谁也说不清中间那一段是从哪切开的
/// (百度那边的路径里本来就有 `/`)。
struct PlaybackSpeedScope: Hashable, Sendable {

    /// 隔离维度:不在同一格里的内容绝不互相影响。
    ///
    /// Emby 是服务器 id(`ServerProfile.id`);百度是账号 —— App 里百度只有一份授权
    /// (`BaiduPanSource`),而网盘路径在账号内全局唯一,所以百度这一格是个常量。
    let isolation: String

    /// 内容维度:同一部剧的每一集共用同一个值。
    ///
    /// Emby 是 `SeriesId`(电影退化成自己的 `Id`);百度是**剧目录**,
    /// 认不出剧时退化成 `fs_id`。
    let content: String
}

extension PlaybackSpeedScope {

    /// Emby:按服务器隔离,同一部剧按 `SeriesId` 认(`PlaybackSpeedStore.scopeID`)。
    static func emby(serverID: UUID, item: EmbyItem) -> PlaybackSpeedScope {
        PlaybackSpeedScope(
            isolation: serverID.uuidString,
            content: PlaybackSpeedStore.scopeID(for: item))
    }

    /// 百度:同一份授权下路径全局唯一,所以隔离那一格取常量。
    ///
    /// `isEpisodeSeries` 决定内容那一格取什么,这是一条**必须**分开的岔路:
    /// - **是剧集**(浏览页装配出了换集队列):取**剧目录** —— 于是点「下一集」进下一集、
    ///   甚至换一季(`琅琊榜/第1季` → `第2季` 归到同一个剧目录),倍速都跟得过去;
    /// - **不是**(电影 / 单条视频,没有可切的兄弟集):取 `fs_id`。⛔ 这时**不能**
    ///   用目录 —— 同一个目录下摆着几部电影时,它们会互相串台(设过 1.5× 的那部
    ///   会让隔壁那部也用 1.5× 起播)。
    static func baiduPan(file: BaiduPanFile, isEpisodeSeries: Bool) -> PlaybackSpeedScope {
        PlaybackSpeedScope(
            isolation: baiduIsolation,
            content: isEpisodeSeries
                ? BaiduPanPath.seriesDirectory(ofFilePath: file.path)
                : String(file.fsID))
    }

    /// 百度侧的隔离维度常量:只有一份授权,这一格没有第二个取值。
    static let baiduIsolation = "baidu-pan"

    /// 本地文件夹:口径与百度相同(剧 = 剧目录,不是剧 = 这一条文件),
    /// 隔离维度是**来源**—— 两个来源里同名的剧目录不是同一部。
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

/// 「同一部剧沿用同一个倍速」的内存记录。
///
/// 只活在本次 App 运行里:倍速是「这一部这次要怎么看」的临时意图,不是长期偏好,
/// 所以 ⛔ 不落 `UserDefaults`,重启 App 一律从 1× 开始。
///
/// 键是 `PlaybackSpeedScope`:Emby 是「服务器 + 剧集」,百度是「剧目录」或 `fs_id`
/// (哪一路、为什么这么取,见那个类型的注释)。
@MainActor
final class PlaybackSpeedStore {

    /// Emby 侧「同一部剧」的判定键(`SeriesId` 优先)。纯函数,单测直接引用。
    ///
    /// `nonisolated`:本类整体是 `@MainActor`,而这个函数只读入参的字段,
    /// 不需要主线程 —— 键的构造(`PlaybackSpeedScope.emby`)会在任意隔离域里调它。
    nonisolated static func scopeID(for item: EmbyItem) -> String {
        item.seriesID ?? item.id
    }

    /// 记住 `scope` 的倍速。
    ///
    /// 1× 等于「没设过」,直接删条目:用户手动调回正常速度后,
    /// 这部剧后面的集数不该再自己弹回他之前设过的高倍速。
    func remember(_ speed: Double, for scope: PlaybackSpeedScope) {
        if speed == 1 {
            speeds.removeValue(forKey: scope)
        } else {
            speeds[scope] = speed
        }
    }

    /// `scope` 记下的倍速;没设过时为 nil(1× 那个默认值由调用方补)。
    func speed(for scope: PlaybackSpeedScope) -> Double? {
        speeds[scope]
    }

    private var speeds: [PlaybackSpeedScope: Double] = [:]
}
