import Foundation

/// LumaPlayer 用到的 Emby 端点(API_CONTRACT.md 3.1、3.2、3.3、4、5)。
///
/// ⛔ 端点路径、方法、字段名一律以 API_CONTRACT.md 为准,不得发明
/// (CLAUDE.md「禁止发明 Emby 接口」)。本文件不出现任何文档之外的路径。
enum EmbyEndpoint: Sendable, Equatable {
    /// GET /System/Info/Public —— 免认证探测 ✅(API_CONTRACT.md 1.4)
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
    /// (官方 OpenAPI 核实 2026-09-22)
    ///
    /// ⚠️ 本地 4.9.5.0 实测:该端点**必须带 `IncludeItemTypes`**,否则恒返回 0 条;
    /// 且类型只能是 Movie / Episode / Video / MusicVideo 这类「可播放叶子类型」,
    /// 掺进 Series / Season / BoxSet / Audio / Book 会重新归零。用户那台 4.7.11.0
    /// 不带该参数也能返回。详见 `PITFALLS.md 第 3 节「继续观看」`。
    case resume(userID: String, query: EmbyItemsQuery)
    /// GET /Users/{UserId}/Items/Latest —— 最近添加 ✅
    /// (官方 OpenAPI 核实 2026-09-22;该端点无 StartIndex / SortBy,见 `EmbyLatestQuery`)
    case latest(userID: String, query: EmbyLatestQuery)
    /// GET /Shows/NextUp —— 剧集「接着看哪一集」 ✅
    /// (官方 OpenAPI 4.1.1.0 核实 2026-09-23;⚠️ 路径里没有 `{Id}`,
    /// `SeriesId` 走查询参数,见 `EmbyNextUpQuery`)
    case nextUp(query: EmbyNextUpQuery)
    /// GET /Shows/{Id}/Seasons —— 剧集的季列表 ✅(官方 OpenAPI 核实 2026-09-22)
    case seasons(seriesID: String, userID: String?)
    /// GET /Shows/{Id}/Episodes —— 剧集的分集列表 ✅(官方 OpenAPI 核实 2026-09-22)
    case episodes(seriesID: String, query: EmbyEpisodesQuery)
    /// GET /Items/{Id}/Images/{Type} —— 媒体项图片 ✅
    ///
    /// ⚠️ 「图片端点是否需要认证头」仍未核实(docs/KNOWN_ISSUES.md Q12)。
    /// 核实前一律**带上**完整认证头(多带无害,漏带会 401),因此
    /// `requiresAuth` 为 true,且图片只能由 `Components/PosterImage.swift` 发起。
    case image(itemID: String, type: EmbyImageType, query: EmbyImageQuery)
    /// POST /Items/{Id}/PlaybackInfo —— 播放信息 ✅(API_CONTRACT.md 4.3;
    /// 请求体与响应字段 2026-09-22 经官方 OpenAPI 核实)
    case playbackInfo(itemID: String, request: PlaybackInfoRequest)
    /// POST /Sessions/Playing —— 开始播放上报 ✅(API_CONTRACT.md 第 5 节)
    case sessionsPlaying(PlaybackReportBody)
    /// POST /Sessions/Playing/Progress —— 进度上报 ✅。
    /// body 的 `eventName` 必须非 nil(5.2),由 `PlaybackProgressReporter` 构造保证。
    case sessionsPlayingProgress(PlaybackReportBody)
    /// POST /Sessions/Playing/Stopped —— 停止上报 ✅
    case sessionsPlayingStopped(PlaybackReportBody)
    /// GET /Items/{Id}/Similar —— 相似推荐 ✅(API_CONTRACT.md 3.2;
    /// 官方 OpenAPI 4.1.1.0 + 本地 4.9.5.0 核实 2026-09-23)
    case similar(itemID: String, query: EmbySimilarQuery)
    /// POST / DELETE /Users/{UserId}/PlayedItems/{Id} —— 标记已看 / 未看 ✅(5.5)
    case setPlayed(userID: String, itemID: String, played: Bool)
    /// POST / DELETE /Users/{UserId}/FavoriteItems/{Id} —— 收藏 / 取消收藏 ✅(5.6)
    case setFavorite(userID: String, itemID: String, favorite: Bool)
    /// POST /Users/{UserId}/Items/{Id}/HideFromResume?Hide={true|false} —— 移出 / 放回继续观看 ✅(5.7)
    ///
    /// ⚠️ 两个方向都是 POST(不是「POST 设上、DELETE 取消」),`Hide` 必须显式带上:
    /// 本地 4.9.5.0 实测不带该参数也返回 200 但**不生效**;GET 请求 404。
    /// 只隐藏、不清进度 —— 与「标记已看」不是一回事(5.7)。
    case hideFromResume(userID: String, itemID: String, hide: Bool)

    /// POST 请求体。
    ///
    /// 两种形态并存:登录是「值全为字符串的扁平表」;PlaybackInfo 需要
    /// 真正的 JSON 布尔值(把 `false` 写成 `"false"` 有被服务端拒收的风险),
    /// 所以走结构化编码,⛔ 不要图省事统一成字符串表。
    enum EmbyRequestBody: Sendable, Equatable {
        case fields([String: String])
        case playbackInfo(PlaybackInfoRequest)
        case playbackReport(PlaybackReportBody)
    }

    /// 诊断用端点名。**不含路径参数与任何凭据**,可安全进日志
    /// (CLAUDE.md「安全与隐私」:日志不得泄露 token/密码)。
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
             // 5.7:移出与放回都走 POST,方向由查询参数 `Hide` 表达
             .hideFromResume:
            return "POST"
        // 5.5 / 5.6:同一路径,POST = 设上,DELETE = 取消
        case .setPlayed(_, _, let on), .setFavorite(_, _, let on):
            return on ? "POST" : "DELETE"
        }
    }

    /// 不含 baseURL 与 `/emby` 前缀的相对路径(拼接在 EmbyRequestBuilder 里)
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
        // 季端点只有一个可选 `UserId`,直接拼在这里
        case .seasons(_, let userID):
            return userID.map { [EmbyQueryItem("UserId", $0)] } ?? []
        // 5.7:`Hide` 必须显式带上,不带服务端返回 200 但不生效
        case .hideFromResume(_, _, let hide):
            return [EmbyQueryItem("Hide", hide ? "true" : "false")]
        case .publicSystemInfo, .systemInfo, .authenticateByName, .logout,
             .userViews, .item, .playbackInfo,
             .sessionsPlaying, .sessionsPlayingProgress, .sessionsPlayingStopped,
             .setPlayed, .setFavorite:
            return []
        }
    }

    /// POST 请求体字段。键名即 API_CONTRACT.md 里的拼写,禁止改写。
    ///
    /// `Pw` 的大小写已 ✅(2026-09-22 在 4.7.11.0 上实测返回 200,
    /// 见 docs/PITFALLS.md Q10)。换服务器若登录失败,按 0.2 核实后再改文档,
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

    /// 响应是否可进本地缓存(allowlist,见 `EmbyResponseCache`)。
    ///
    /// 只列**浏览类 GET**:这些端点的数据按小时级变化,TTL 内复用即秒出内容。
    /// ⛔ 不在名单里的一律实时:
    /// - `publicSystemInfo` / `systemInfo`:探测与连通性判断必须实时;
    /// - `playbackInfo` / 三个播放上报 / `setPlayed` / `setFavorite`:POST 写操作;
    /// - `image`:二进制,走独立的 `PosterDiskCache`(API_CONTRACT.md 3.3)。
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

    /// 是否需要认证头里的 `UserId` 段与 `X-Emby-Token`。
    /// 探测与登录本身是免认证的(API_CONTRACT.md 2.1:未登录时省略 UserId)。
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
