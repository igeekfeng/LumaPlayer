import Foundation

/// LumaPlayer 用到的 Emby 端点(API_CONTRACT.md 3.1、3.2、3.3、4、5)。
/// ⛔ 路径、方法、字段名一律以 API_CONTRACT.md 为准,不得发明。
enum EmbyEndpoint: Sendable, Equatable {
    /// GET /System/Info/Public —— 免认证探测 ✅(1.4)
    case publicSystemInfo
    /// GET /System/Info —— 需认证 ✅
    case systemInfo
    /// POST /Users/AuthenticateByName —— ✅
    case authenticateByName(username: String, password: String)
    /// POST /Sessions/Logout —— ✅
    case logout
    /// GET /Users/{UserId}/Views —— ✅
    case userViews(userID: String)
    /// GET /Users/{UserId}/Items —— 列表 / 分页 / 搜索 ✅
    case items(userID: String, query: EmbyItemsQuery)
    /// GET /Users/{UserId}/Items/{Id} —— 单项完整详情 ✅
    case item(userID: String, itemID: String)
    /// GET /Users/{UserId}/Items/Resume —— 继续观看 ✅
    /// ⚠️ 不带参数恒返回 0 条,参数见 `ServerConnection.resume`(`PITFALLS.md` 第 3 节「继续观看」)。
    case resume(userID: String, query: EmbyItemsQuery)
    /// GET /Users/{UserId}/Items/Latest —— 最近添加 ✅(无 StartIndex / SortBy)
    case latest(userID: String, query: EmbyLatestQuery)
    /// GET /Shows/NextUp —— 接着看哪一集 ✅(⚠️ 路径里没有 `{Id}`,`SeriesId` 走查询参数)
    case nextUp(query: EmbyNextUpQuery)
    /// GET /Shows/{Id}/Seasons ✅
    case seasons(seriesID: String, userID: String?)
    /// GET /Shows/{Id}/Episodes ✅
    case episodes(seriesID: String, query: EmbyEpisodesQuery)
    /// GET /Items/{Id}/Images/{Type} ✅
    /// 是否需要认证头未核实(Q12),一律带上;只能由 `PosterImage` 发起。
    case image(itemID: String, type: EmbyImageType, query: EmbyImageQuery)
    /// POST /Items/{Id}/PlaybackInfo ✅(4.3)
    case playbackInfo(itemID: String, request: PlaybackInfoRequest)
    /// POST /Sessions/Playing —— 开始播放上报 ✅(第 5 节)
    case sessionsPlaying(PlaybackReportBody)
    /// POST /Sessions/Playing/Progress —— 进度上报 ✅。
    /// body 的 `eventName` 必须非 nil(5.2),由 `PlaybackProgressReporter` 构造保证。
    case sessionsPlayingProgress(PlaybackReportBody)
    /// POST /Sessions/Playing/Stopped —— 停止上报 ✅
    case sessionsPlayingStopped(PlaybackReportBody)
    /// GET /Items/{Id}/Similar —— 相似推荐 ✅(3.2)
    case similar(itemID: String, query: EmbySimilarQuery)
    /// POST / DELETE /Users/{UserId}/PlayedItems/{Id} —— 标记已看 / 未看 ✅(5.5)
    case setPlayed(userID: String, itemID: String, played: Bool)
    /// POST / DELETE /Users/{UserId}/FavoriteItems/{Id} —— 收藏 / 取消收藏 ✅(5.6)
    case setFavorite(userID: String, itemID: String, favorite: Bool)
    /// POST /Users/{UserId}/Items/{Id}/HideFromResume?Hide={true|false} —— 移出 / 放回继续观看 ✅(5.7)
    /// ⚠️ 两个方向都是 POST;`Hide` 必须显式带上,不带返回 200 但不生效。只隐藏、不清进度。
    case hideFromResume(userID: String, itemID: String, hide: Bool)

    /// 登录是字符串扁平表;PlaybackInfo / 上报要真正的 JSON 布尔值,
    /// ⛔ 不要统一成字符串表(`"false"` 可能被服务端拒收)。
    enum EmbyRequestBody: Sendable, Equatable {
        case fields([String: String])
        case playbackInfo(PlaybackInfoRequest)
        case playbackReport(PlaybackReportBody)
    }

    /// 诊断用端点名。不含路径参数与凭据,可安全进日志。
    var name: String {
        switch self {
        case .publicSystemInfo: return "System/Info/Public"
        case .systemInfo: return "System/Info"
        case .authenticateByName: return "Users/AuthenticateByName"
        case .logout: return "Sessions/Logout"
        case .userViews: return "Users/{UserId}/Views"
        case .items: return "Users/{UserId}/Items"
        case .item: return "Users/{UserId}/Items/{Id}"
        case .resume: return "Users/{UserId}/Items/Resume"
        case .latest: return "Users/{UserId}/Items/Latest"
        case .nextUp: return "Shows/NextUp"
        case .seasons: return "Shows/{Id}/Seasons"
        case .episodes: return "Shows/{Id}/Episodes"
        case .image: return "Items/{Id}/Images/{Type}"
        case .playbackInfo: return "Items/{Id}/PlaybackInfo"
        case .sessionsPlaying: return "Sessions/Playing"
        case .sessionsPlayingProgress: return "Sessions/Playing/Progress"
        case .sessionsPlayingStopped: return "Sessions/Playing/Stopped"
        case .similar: return "Items/{Id}/Similar"
        case .setPlayed: return "Users/{UserId}/PlayedItems/{Id}"
        case .setFavorite: return "Users/{UserId}/FavoriteItems/{Id}"
        case .hideFromResume: return "Users/{UserId}/Items/{Id}/HideFromResume"
        }
    }

    var method: String {
        switch self {
        case .publicSystemInfo, .systemInfo, .userViews, .items, .item,
             .resume, .latest, .nextUp, .seasons, .episodes, .image, .similar:
            return "GET"
        case .authenticateByName, .logout, .playbackInfo,
             .sessionsPlaying, .sessionsPlayingProgress, .sessionsPlayingStopped,
             // 5.7:方向由查询参数 `Hide` 表达
             .hideFromResume:
            return "POST"
        // 5.5 / 5.6:同一路径,POST = 设上,DELETE = 取消
        case .setPlayed(_, _, let on), .setFavorite(_, _, let on):
            return on ? "POST" : "DELETE"
        }
    }

    /// 不含 baseURL 与 `/emby` 前缀
    var path: String {
        switch self {
        case .publicSystemInfo: return "/System/Info/Public"
        case .systemInfo: return "/System/Info"
        case .authenticateByName: return "/Users/AuthenticateByName"
        case .logout: return "/Sessions/Logout"
        case .userViews(let userID): return "/Users/\(userID)/Views"
        case .items(let userID, _): return "/Users/\(userID)/Items"
        case .item(let userID, let itemID): return "/Users/\(userID)/Items/\(itemID)"
        case .resume(let userID, _): return "/Users/\(userID)/Items/Resume"
        case .latest(let userID, _): return "/Users/\(userID)/Items/Latest"
        case .nextUp: return "/Shows/NextUp"
        case .seasons(let seriesID, _): return "/Shows/\(seriesID)/Seasons"
        case .episodes(let seriesID, _): return "/Shows/\(seriesID)/Episodes"
        case .image(let itemID, let type, _): return "/Items/\(itemID)/Images/\(type.rawValue)"
        case .playbackInfo(let itemID, _): return "/Items/\(itemID)/PlaybackInfo"
        case .sessionsPlaying: return "/Sessions/Playing"
        case .sessionsPlayingProgress: return "/Sessions/Playing/Progress"
        case .sessionsPlayingStopped: return "/Sessions/Playing/Stopped"
        case .similar(let itemID, _): return "/Items/\(itemID)/Similar"
        case .setPlayed(let userID, let itemID, _): return "/Users/\(userID)/PlayedItems/\(itemID)"
        case .setFavorite(let userID, let itemID, _): return "/Users/\(userID)/FavoriteItems/\(itemID)"
        case .hideFromResume(let userID, let itemID, _): return "/Users/\(userID)/Items/\(itemID)/HideFromResume"
        }
    }

    var queryItems: [EmbyQueryItem] {
        switch self {
        case .items(_, let query): return query.queryItems
        case .resume(_, let query): return query.queryItems
        case .latest(_, let query): return query.queryItems
        case .nextUp(let query): return query.queryItems
        case .episodes(_, let query): return query.queryItems
        case .image(_, _, let query): return query.queryItems
        case .similar(_, let query): return query.queryItems
        case .seasons(_, let userID):
            return userID.map { [EmbyQueryItem("UserId", $0)] } ?? []
        // 5.7:必须显式带上
        case .hideFromResume(_, _, let hide):
            return [EmbyQueryItem("Hide", hide ? "true" : "false")]
        case .publicSystemInfo, .systemInfo, .authenticateByName, .logout,
             .userViews, .item, .playbackInfo,
             .sessionsPlaying, .sessionsPlayingProgress, .sessionsPlayingStopped,
             .setPlayed, .setFavorite:
            return []
        }
    }

    /// 键名即 API_CONTRACT.md 里的拼写。`Pw` 大小写 ✅(PITFALLS.md Q10);
    /// ⛔ 不要自动降级成小写 `pw` 重试。
    var body: EmbyRequestBody? {
        switch self {
        case .authenticateByName(let username, let password):
            return .fields(["Username": username, "Pw": password])
        case .playbackInfo(_, let request):
            return .playbackInfo(request)
        case .sessionsPlaying(let body):
            return .playbackReport(body)
        case .sessionsPlayingProgress(let body):
            return .playbackReport(body)
        case .sessionsPlayingStopped(let body):
            return .playbackReport(body)
        case .publicSystemInfo, .systemInfo, .logout, .userViews, .items, .item,
             .resume, .latest, .nextUp, .seasons, .episodes, .image,
             .similar, .setPlayed, .setFavorite, .hideFromResume:
            return nil
        }
    }

    /// 响应能否进本地缓存(allowlist,见 `EmbyResponseCache`)。只列浏览类 GET。
    /// ⛔ 其余一律实时:探测要实时,写操作不缓存,`image` 走独立的 `PosterDiskCache`。
    var isResponseCacheable: Bool {
        switch self {
        case .userViews, .items, .item, .resume, .latest, .nextUp, .seasons, .episodes, .similar:
            return true
        case .publicSystemInfo, .systemInfo, .authenticateByName, .logout, .image,
             .playbackInfo, .sessionsPlaying, .sessionsPlayingProgress, .sessionsPlayingStopped,
             .setPlayed, .setFavorite, .hideFromResume:
            return false
        }
    }

    /// 是否需要 `UserId` 段与 `X-Emby-Token`。探测与登录免认证(API_CONTRACT.md 2.1)。
    var requiresAuth: Bool {
        switch self {
        case .publicSystemInfo, .authenticateByName: return false
        case .systemInfo, .logout, .userViews, .items, .item, .resume, .latest,
             .nextUp,
             .seasons, .episodes, .image, .playbackInfo,
             .sessionsPlaying, .sessionsPlayingProgress, .sessionsPlayingStopped,
             .similar, .setPlayed, .setFavorite, .hideFromResume: return true
        }
    }
}
