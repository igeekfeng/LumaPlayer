import Foundation

/// 一次匹配用到的**附加线索**(`docs/DANMAKU.md` §3)。
///
/// 与 `DanmakuMediaQuery` 分开:后者是「这一集是谁」(身份与文案,UI 也要用),
/// 这里只服务匹配本身 —— TMDB ID、季、电影标记、以及可能算出来的媒体指纹。
/// 这些字段**随时可能是 nil**(ProviderIds 缺失、指纹拿不到),`DanmakuService`
/// 必须能在缺任意一项时退回文件名匹配,⛔ 不能把它们当成必填前提。
struct DanmakuMatchContext: Sendable, Equatable {

    /// TMDB ID(`ProviderIds.Tmdb`);nil = 不知道
    let tmdbID: Int?
    /// 目标是电影(剧场版与剧集是不同作品,`tmdbIdType` 也因此不同)
    let isMovie: Bool
    /// 文件前 16 MiB 的 MD5;nil = 没算 / 拿不到
    let fileHash: String?

    static let empty = DanmakuMatchContext(tmdbID: nil, isMovie: false, fileHash: nil)

    init(tmdbID: Int?, isMovie: Bool, fileHash: String?) {
        self.tmdbID = tmdbID
        self.isMovie = isMovie
        self.fileHash = fileHash
    }

    /// 由查询补上「身份侧」的字段(季 / 集 / 标题),给候选匹配器用。
    ///
    /// 指纹与 TMDB 只影响**怎么查**,不影响**怎么判**:判据永远是
    /// 「这一集是谁」,所以这里从 `query` 取,不从 context 取。
    func target(for query: DanmakuMediaQuery) -> DanmakuCandidateMatcher.Target {
        query.matcherTarget
    }
}

/// 播放页能提供给匹配的**可选**线索。字段为 nil 表示「这一路不知道」,
/// 由 `DanmakuController` 与 `query` 上的值合并(显式的 context 优先)。
///
/// 单独一个类型而不是直接传 `DanmakuMatchContext`:后者在 `Core/Danmaku` 里,
/// 是编排层的输入;这个类型是 `Features/Player` 侧的出口,⛔ 不让 ViewModel
/// 依赖编排层的内部结构。
struct DanmakuMatchHints: Sendable, Equatable {
    let tmdbID: Int?
    let isMovie: Bool?

    static let none = DanmakuMatchHints(tmdbID: nil, isMovie: nil)
}
