import Foundation

/// 一次「请播放器窗口播这一项」的请求(`AppState.nowPlaying`)。
///
/// 播放器是**单实例的独立窗口**(ARCHITECTURE.md 7.5):详情页只负责
/// 写入请求并唤起窗口,窗口按 `id` 重建播放页 —— 换一集 = 换一个请求,
/// 旧播放页随之消失并走完收尾上报。`id` 每次新建都不同,所以同一项
/// 再点一次播放也会得到一个新会话,而不是被当成「没变」忽略。
struct PlaybackRequest: Identifiable, Equatable {
    let id = UUID()
    let server: ServerProfile
    let item: EmbyItem
    /// 「从头播放」:忽略服务端记录的续播位置
    var startFromBeginning = false
}

/// 一次播放的收尾上报(最终 Progress + Stopped)**已经发完**。
///
/// 详情页 / 首页据此向服务端重读续播位置与已看状态(docs/PITFALLS.md Q22):
/// 早于 Stopped 到达就读,拿到的仍是起播前的旧进度。
/// 播放器挪到独立窗口后不能再用闭包回调给详情页,改为经 `AppState` 广播。
struct FinishedPlayback: Equatable {
    /// 对应 `PlaybackRequest.id`;观察方只用它判断「是不是新的一次」
    let requestID: UUID
    let serverID: UUID
    let itemID: String
}

/// 「下一集」查找(纯函数,无网络):在服务端返回的有序列表里取紧跟其后的一项。
///
/// 顺序完全以服务端为准(`Shows/{Id}/Episodes` 与 `Shows/{Id}/Seasons`
/// 本身就按集号 / 季号排好),这里不按 `IndexNumber` 重排 ——
/// 集号缺失或重复时自己排只会排错。
enum NextEpisodeResolver {
    static func item(after id: String, in items: [EmbyItem]) -> EmbyItem? {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items.indices.contains(index + 1) else { return nil }
        return items[index + 1]
    }

    /// 紧挨在前面的一项(上一集 / 上一季)
    static func item(before id: String, in items: [EmbyItem]) -> EmbyItem? {
        guard let index = items.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return items[index - 1]
    }
}

/// 播放画面上的短暂提示(非交互玻璃胶囊,UI_DESIGN.md 4.1)。
struct PlayerOSD: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let systemImage: String
}
