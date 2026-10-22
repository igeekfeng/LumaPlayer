import Foundation

/// 匹配用的附加线索(`docs/DANMAKU.md` §3);「这一集是谁」在 `DanmakuMediaQuery`。
/// 字段随时可能是 nil,`DanmakuService` 缺任一项都要能退回文件名匹配,⛔ 不当必填前提。
struct DanmakuMatchContext: Sendable, Equatable {

    /// `ProviderIds.Tmdb`
    let tmdbID: Int?
    /// 决定 `tmdbIdType`
    let isMovie: Bool
    /// nil = 没算 / 拿不到
    let fileHash: String?

    static let empty = DanmakuMatchContext(tmdbID: nil, isMovie: false, fileHash: nil)

    init(tmdbID: Int?, isMovie: Bool, fileHash: String?) {
        self.tmdbID = tmdbID
        self.isMovie = isMovie
        self.fileHash = fileHash
    }

    /// 指纹与 TMDB 只影响怎么查,不影响怎么判:判据从 `query` 取。
    func target(for query: DanmakuMediaQuery) -> DanmakuCandidateMatcher.Target {
        query.matcherTarget
    }
}

/// 播放页提供的可选线索,nil = 不知道;由 `DanmakuController` 与 `query` 合并(这里优先)。
/// ⛔ 不改成直接传 `DanmakuMatchContext`:不让 ViewModel 依赖编排层内部结构。
struct DanmakuMatchHints: Sendable, Equatable {
    let tmdbID: Int?
    let isMovie: Bool?

    static let none = DanmakuMatchHints(tmdbID: nil, isMovie: nil)
}
