import Foundation

// 弹弹play 请求 / 响应 DTO(`docs/DANDANPLAY_API.md`,字段名对照官方 OpenAPI 规格)。
// 规格没有 required 字段,除作 id 的整数外一律可选;⛔ 不在这里补假默认值。只解要读的字段。

/// 规格 `MatchRequest`(§2)。nil 字段不出现在 JSON 里。
struct DandanplayMatchRequest: Encodable, Sendable, Equatable {
    /// 不含文件夹名与扩展名
    let fileName: String
    /// 文件前 16 MiB 的 MD5。有真实指纹(`DanmakuFingerprint`)配 `hashAndFileName`,
    /// 没有就填 `placeholderFileHash` 配 `fileNameOnly`。
    let fileHash: String?
    /// 字节;未知时不传
    let fileSize: Int64?
    /// 秒;未知时不传
    let videoDuration: Int32?
    /// `hashAndFileName` / `fileNameOnly` / `hashOnly`
    let matchMode: String

    static let hashAndFileName = "hashAndFileName"
    static let fileNameOnly = "fileNameOnly"

    /// 占位 Hash:32 个 `0`。服务端实际要求 `fileHash` 是 32 位字符串,`fileNameOnly` 也一样
    /// (规格没写,缺了回 `errorCode 2`;据 `open-ani/animeko#3506`,未用自有凭据复验,Q48)。
    /// 服务端按 Hash 查不到就回落到文件名匹配;全 `0` 是官方示例里的「无 Hash」写法,不会命中真实文件。
    static let placeholderFileHash = String(repeating: "0", count: 32)
}

/// 规格 `ResponseBase` 的状态字段。`errorDetail` 只在参数校验失败时有值,指向具体字段。
protocol DandanplayStatusResponse {
    var errorCode: Int? { get }
    var success: Bool? { get }
    var errorMessage: String? { get }
    var errorDetail: String? { get }
}

/// 规格 `MatchResponseV2`。
struct DandanplayMatchResponse: Decodable, Sendable, DandanplayStatusResponse {
    let errorCode: Int?
    let success: Bool?
    let errorMessage: String?
    let errorDetail: String?
    /// true = 已精确关联,`matches` 只有一项,直接采用(§2)
    let isMatched: Bool?
    let matches: [DandanplayMatch]?
}

/// 规格 `MatchResultV2`。
struct DandanplayMatch: Decodable, Sendable, Equatable {
    let episodeId: Int64
    let animeId: Int64
    let animeTitle: String?
    let episodeTitle: String?
    /// `AnimeType` 枚举字符串。剧场版与剧集是不同作品。
    let type: String?
    let typeDescription: String?
    /// 弹幕偏移(秒):弹幕应延迟多少秒出现,负数为提前
    let shift: Double?
}

/// 规格 `SearchEpisodesResponse`。
struct DandanplaySearchEpisodesResponse: Decodable, Sendable, DandanplayStatusResponse {
    let errorCode: Int?
    let success: Bool?
    let errorMessage: String?
    let errorDetail: String?
    /// 结果被截断,应提示用户填更详细的关键词
    let hasMore: Bool?
    let animes: [DandanplaySearchAnime]?
}

/// 规格 `SearchEpisodesAnime`。
struct DandanplaySearchAnime: Decodable, Sendable, Equatable {
    let animeId: Int64
    let animeTitle: String?
    /// 同 `DandanplayMatch.type`
    let type: String?
    let typeDescription: String?
    let episodes: [DandanplaySearchEpisode]?
}

/// 规格 `SearchEpisodeDetails`。
struct DandanplaySearchEpisode: Decodable, Sendable, Equatable {
    let episodeId: Int64
    let episodeTitle: String?
}

/// 规格 `BangumiDetailsResponse`。
struct DandanplayBangumiResponse: Decodable, Sendable, DandanplayStatusResponse {
    let errorCode: Int?
    let success: Bool?
    let errorMessage: String?
    let errorDetail: String?
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
    /// 不一定是纯数字(如 `S1` / `C1`)
    let episodeNumber: String?
}

/// 规格 `CommentResponseV2`,没有 `ResponseBase`。
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
