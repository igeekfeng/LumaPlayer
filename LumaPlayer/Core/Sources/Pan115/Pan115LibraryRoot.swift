import Foundation

/// 115 源的片库根:进入这个来源时先落在这个目录。
///
/// 与百度不同,115 的 Cookie 能读**整个网盘**(`cid=0` 是根,`docs/PAN115_API.md` §3),
/// 没有 `/apps/{应用名}` 那种隔离,所以片库根纯粹是书签 —— 用户把自己的影音目录挑出来当起点。
/// 一个来源只有一个(要两个起点就加两个来源,多来源共用同一份 Cookie)。
///
/// 存的是**路径**而不是 `cid`:115 的 `files` 接口按 `cid` 取目录,但 `cid` 在改名 / 移动后不变而
/// 路径会变 —— 反过来说,`cid` 用户看不见也选不了,而浏览页、续播快照、剧集归属全都按路径串起来
/// (`BaiduPanFile.path`、`BaiduPanPath.seriesDirectory`)。路径 → `cid` 的映射由
/// `Pan115Connection` 在内存里维护,失效了用 `files/getid` 重换一次(§3)。
struct Pan115LibraryRoot: Codable, Sendable, Equatable {
    /// 从网盘根算起的完整路径,`"/"` 是根。
    var path: String
    /// 目录名,只作展示;根目录是空串。
    var name: String

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    /// 115 的根目录(`files?cid=0`,§3)。
    static let root = Pan115LibraryRoot(path: "/", name: "")

    var isRoot: Bool { path == Self.root.path }

    /// 路径显示用。115 没有稳定的路径概念,这里只拼一层给人看。
    var displayName: String { isRoot ? "115 网盘" : name }
}
