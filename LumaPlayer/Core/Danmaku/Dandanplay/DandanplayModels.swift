import Foundation

// 弹弹play 的请求 / 响应 DTO(`docs/DANDANPLAY_API.md`)。
//
// 字段名逐个对着官方 OpenAPI 规格(2026-10-15 取 `api.dandanplay.net/swagger/v2/swagger.json`):
// 规格里**没有任何 required 字段**,所以除了作 id 用的整数,一律按可选解 ——
// 缺字段时由上层决定怎么展示,⛔ 不在这里补假默认值(CLAUDE.md 硬规则 4)。
// 只解真正要读的字段。

/// `POST /api/v2/match` 的请求体(规格 `MatchRequest`,§2)。
///
/// 可选字段为 nil 时**不出现在 JSON 里**(合成的 `Encodable` 对可选值用 `encodeIfPresent`)。
struct DandanplayMatchRequest: Encodable, Sendable, Equatable {
    /// 视频文件名,**不含文件夹名与扩展名**
    let fileName: String
    /// 文件前 16 MB 的 MD5。本项目拿不到(见 `DanmakuMediaQuery` 的注释),恒为 nil
    let fileHash: String?
    /// 文件总长度(字节);未知时不传
    let fileSize: Int64?
    /// 视频时长(秒,32 位整数);未知时不传
    let videoDuration: Int32?
    /// 匹配模式:`hashAndFileName` / `fileNameOnly` / `hashOnly`
    let matchMode: String

    /// 没有 Hash 时只能按文件名匹配
    static let fileNameOnly = "fileNameOnly"
}

/// 带 `ResponseBase` 的响应共有的状态字段(`errorCode` / `success` / `errorMessage`)。
protocol DandanplayStatusResponse {
    var errorCode: Int? { get }
    var success: Bool? { get }
    var errorMessage: String? { get }
}

/// `POST /api/v2/match` 的响应(规格 `MatchResponseV2`)。
struct DandanplayMatchResponse: Decodable, Sendable, DandanplayStatusResponse {
    let errorCode: Int?
    let success: Bool?
    let errorMessage: String?
    /// true = 已精确关联(此时 `matches` 只有一项,客户端应直接采用,§2)
    let isMatched: Bool?
    let matches: [DandanplayMatch]?
}

/// 规格 `MatchResultV2`。
struct DandanplayMatch: Decodable, Sendable, Equatable {
    let episodeId: Int64
    let animeId: Int64
    let animeTitle: String?
    let episodeTitle: String?
    let typeDescription: String?
    /// 弹幕偏移(秒):弹幕应延迟多少秒出现,负数为提前
    let shift: Double?
}

/// `GET /api/v2/search/episodes` 的响应(规格 `SearchEpisodesResponse`)。
struct DandanplaySearchEpisodesResponse: Decodable, Sendable, DandanplayStatusResponse {
    let errorCode: Int?
    let success: Bool?
    let errorMessage: String?
    /// 结果太多被截断:应提示用户填更详细的关键词
    let hasMore: Bool?
    let animes: [DandanplaySearchAnime]?
}

/// 规格 `SearchEpisodesAnime`。
struct DandanplaySearchAnime: Decodable, Sendable, Equatable {
    let animeId: Int64
    let animeTitle: String?
    let typeDescription: String?
    let episodes: [DandanplaySearchEpisode]?
}

/// 规格 `SearchEpisodeDetails`。
struct DandanplaySearchEpisode: Decodable, Sendable, Equatable {
    let episodeId: Int64
    let episodeTitle: String?
}

/// `GET /api/v2/bangumi/{animeId}` 的响应(规格 `BangumiDetailsResponse`)。
struct DandanplayBangumiResponse: Decodable, Sendable, DandanplayStatusResponse {
    let errorCode: Int?
    let success: Bool?
    let errorMessage: String?
    let bangumi: DandanplayBangumi?
}

/// 规格 `BangumiDetails`(只解剧集列表与标题)。
struct DandanplayBangumi: Decodable, Sendable, Equatable {
    let animeId: Int64?
    let animeTitle: String?
    let episodes: [DandanplayBangumiEpisode]?
}

/// 规格 `BangumiEpisode`。
struct DandanplayBangumiEpisode: Decodable, Sendable, Equatable {
    let episodeId: Int64
    let episodeTitle: String?
    /// 剧集短标题,**不一定是纯数字**(可能含字母,如 `S1` / `C1`)
    let episodeNumber: String?
}

/// `GET /api/v2/comment/{episodeId}` 的响应(规格 `CommentResponseV2`,**没有** `ResponseBase`)。
struct DandanplayCommentResponse: Decodable, Sendable {
    let count: Int?
    let comments: [DandanplayComment]?
}

/// 规格 `CommentData`。`p` 的格式见 `DanmakuComment.init?(dandanplay:)`。
struct DandanplayComment: Decodable, Sendable, Equatable {
    let cid: Int64
    let p: String?
    let m: String?
}
