import Foundation

/// 一次播放请求要播的**是哪一路来源**上的内容。
///
/// ⚠️ 为什么是枚举而不是「给 `PlaybackRequest` 加两个可选字段」:
/// Emby 与百度网盘**没有共同的语义** —— Emby 有服务器 / Item / 服务端进度,
/// 百度只有一条文件与 `fs_id`。做成两个可选字段就会出现「既没服务器也没文件」
/// 这种不可能的状态,而每个调用点都要先判一遍。
enum PlaybackSource: Sendable, Equatable {
    case emby(server: ServerProfile, item: EmbyItem)
    case baiduPan(file: BaiduPanFile)

    /// Emby 来源才有(其它来源返回 nil)
    var embyServer: ServerProfile? {
        if case .emby(let server, _) = self { return server }
        return nil
    }

    var embyItem: EmbyItem? {
        if case .emby(_, let item) = self { return item }
        return nil
    }

    var baiduFile: BaiduPanFile? {
        if case .baiduPan(let file) = self { return file }
        return nil
    }

    /// 上报 / 日志用的内容标识。Emby 是 Item Id,百度是 `fs_id`。
    var contentID: String {
        switch self {
        case .emby(_, let item): return item.id
        case .baiduPan(let file): return String(file.fsID)
        }
    }
}

/// 一次「请播放器窗口播这一项」的请求(`AppState.nowPlaying`)。
///
/// 播放器是**单实例的独立窗口**(CLAUDE.md「架构主线」):详情页只负责
/// 写入请求并唤起窗口,窗口按 `id` 重建播放页 —— 换一集 = 换一个请求,
/// 旧播放页随之消失并走完收尾上报。`id` 每次新建都不同,所以同一项
/// 再点一次播放也会得到一个新会话,而不是被当成「没变」忽略。
struct PlaybackRequest: Identifiable, Equatable {
    let id = UUID()
    let source: PlaybackSource
    /// 「从头播放」:忽略记录的续播位置(Emby 是服务端进度,百度是本地续播库)
    var startFromBeginning = false

    init(source: PlaybackSource, startFromBeginning: Bool = false) {
        self.source = source
        self.startFromBeginning = startFromBeginning
    }

    /// 既有 Emby 调用点的形状(首页 / 媒体库 / 详情 / 搜索)。
    init(server: ServerProfile, item: EmbyItem, startFromBeginning: Bool = false) {
        self.source = .emby(server: server, item: item)
        self.startFromBeginning = startFromBeginning
    }

    init(baiduFile: BaiduPanFile, startFromBeginning: Bool = false) {
        self.source = .baiduPan(file: baiduFile)
        self.startFromBeginning = startFromBeginning
    }

    var embyServer: ServerProfile? { source.embyServer }
    var embyItem: EmbyItem? { source.embyItem }
    var baiduFile: BaiduPanFile? { source.baiduFile }
}

/// 一次播放的收尾上报(最终 Progress + Stopped)**已经发完**。
///
/// 详情页 / 首页据此向服务端重读续播位置与已看状态(docs/PITFALLS.md Q22):
/// 早于 Stopped 到达就读,拿到的仍是起播前的旧进度。
/// 播放器挪到独立窗口后不能再用闭包回调给详情页,改为经 `AppState` 广播。
struct FinishedPlayback: Equatable {
    /// 对应 `PlaybackRequest.id`;观察方只用它判断「是不是新的一次」
    let requestID: UUID
    /// Emby 来源才有(百度来源没有服务器)。观察方按它过滤「是不是本页那台」。
    let serverID: UUID?
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

/// 播放画面上的短暂提示(非交互玻璃胶囊,DesignTokens.swift「界面规则」)。
struct PlayerOSD: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let systemImage: String
}
