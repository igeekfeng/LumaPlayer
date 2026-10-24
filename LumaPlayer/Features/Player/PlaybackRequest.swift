import Foundation

/// 一次播放请求的内容来源。做成枚举而非可选字段:Emby 与文件树来源没有共同语义,
/// 可选字段会允许「既没服务器也没文件」的不可能状态。
enum PlaybackSource: Sendable, Equatable {
    case emby(server: ServerProfile, item: EmbyItem)
    case baiduPan(file: BaiduPanFile)
    /// 带上来源:打开文件要它的书签(`LocalFolderAccess`),范围键(倍速 / 片头片尾 / 弹幕绑定)要它的 id 隔离。
    case localFolder(file: BaiduPanFile, source: LocalFolderSource)

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

    /// 文件树来源(百度 / 本地文件夹)的文件;Emby 为 nil。两者共用本地收尾
    /// (`AppContainer.settleFileSourceEpisode`)。
    var file: BaiduPanFile? {
        switch self {
        case .emby: return nil
        case .baiduPan(let file), .localFolder(let file, _): return file
        }
    }

    /// 上报 / 日志用:Emby 是 Item Id,文件树来源是 `fs_id`。
    var contentID: String {
        switch self {
        case .emby(_, let item): return item.id
        case .baiduPan(let file), .localFolder(let file, _): return String(file.fsID)
        }
    }
}

/// 请播放器窗口播这一项(`AppState.nowPlaying`)。
///
/// - `id`:一次播放会话。每次新建都不同,同一项再点播放也是新会话(新 ViewModel、新 mpv、新一轮上报)。
/// - `pageID`:播放页。播放页内换集沿用上一集的(页面不动,只换会话,旧会话照样收尾上报)。
struct PlaybackRequest: Identifiable, Equatable {
    let id: UUID
    let pageID: UUID
    let source: PlaybackSource
    /// 忽略记录的续播位置(Emby 是服务端进度,百度是本地续播库)
    var startFromBeginning = false
    /// 见 `EpisodeQueue`。Emby 由播放页自己查(`PlayerViewModel.loadEpisodeQueue`)。
    /// nil = 没有兄弟集(电影、单条视频、百度「继续观看」卡片)。
    var episodeQueue: EpisodeQueue?

    /// 同目录外挂字幕(百度侧;Emby 恒为空)。装文件而非地址:换 `dlink` 是
    /// `BaiduPanSessionPreparer` 的活,配对只需文件名。
    var subtitleFiles: [BaiduPanFile] = []

    /// - Parameter continuingPage: 播放页内换集时传当前 `pageID`;nil = 新开播放页。
    init(
        source: PlaybackSource,
        startFromBeginning: Bool = false,
        episodeQueue: EpisodeQueue? = nil,
        subtitleFiles: [BaiduPanFile] = [],
        continuingPage: UUID? = nil
    ) {
        let id = UUID()
        self.id = id
        self.pageID = continuingPage ?? id
        self.source = source
        self.startFromBeginning = startFromBeginning
        self.episodeQueue = episodeQueue
        self.subtitleFiles = subtitleFiles
    }

    init(server: ServerProfile, item: EmbyItem, startFromBeginning: Bool = false) {
        self.init(source: .emby(server: server, item: item), startFromBeginning: startFromBeginning)
    }

    init(
        baiduFile: BaiduPanFile,
        subtitleFiles: [BaiduPanFile] = [],
        startFromBeginning: Bool = false,
        episodeQueue: EpisodeQueue? = nil
    ) {
        self.init(
            source: .baiduPan(file: baiduFile),
            startFromBeginning: startFromBeginning,
            episodeQueue: episodeQueue,
            subtitleFiles: subtitleFiles)
    }

    var embyServer: ServerProfile? { source.embyServer }
    var embyItem: EmbyItem? { source.embyItem }
    var baiduFile: BaiduPanFile? { source.baiduFile }
}

/// 一次播放的收尾上报(最终 Progress + Stopped)已发完,经 `AppState` 广播。
/// 详情页 / 首页据此重读续播位置与已看状态;早于 Stopped 读会拿到旧进度(docs/PITFALLS.md Q22)。
struct FinishedPlayback: Equatable {
    /// 对应 `PlaybackRequest.id`,观察方只用它判断是不是新的一次
    let requestID: UUID
    /// Emby 来源才有,观察方按它过滤服务器
    let serverID: UUID?
    let itemID: String
}

/// 在服务端返回的有序列表里取相邻项(纯函数)。
/// ⛔ 不按 `IndexNumber` 重排:服务端已排好,集号缺失或重复时自己排只会排错。
enum NextEpisodeResolver {
    static func item(after id: String, in items: [EmbyItem]) -> EmbyItem? {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items.indices.contains(index + 1) else { return nil }
        return items[index + 1]
    }

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
