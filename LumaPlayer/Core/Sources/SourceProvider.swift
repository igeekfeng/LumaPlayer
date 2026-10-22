import Foundation

/// 一个来源能提供的内容能力(列库 / 列条目)。
///
/// 播放不走这里,走 `PlaybackSessionPreparing`(随 `PlaybackRequest` 进播放页,生命周期不同)。
/// 是 `Actor`:实现要复用 `ServerConnection` / `BaiduPanConnection` 这些 actor 的状态。
protocol SourceProvider: Actor {
    /// 路由与图片缓存 key 用
    nonisolated var sourceID: UUID { get }
    func libraries() async throws -> [SourceLibrary]
    func items(in library: SourceLibraryRef) async throws -> [SourceItem]
}

/// 文件树来源(百度网盘 / 本地文件夹)一次目录读取的完整结果。
///
/// 连原始文件一起交回:播放与进目录要的 `path` / 真实文件名不在 `SourceItem` 里,
/// ⛔ 不能让调用方再列一次目录(百度配额,`docs/BAIDU_PAN_API.md` §7)。
///
/// 本地文件夹也用 `BaiduPanFile` 这个形状(来源内稳定 id + 路径 + 名字 + 大小 / 修改时间),
/// 见 `LocalFolderListing` 对 `fsID` 的说明。
struct FileSourceDirectoryContent: Sendable {
    let items: [SourceItem]
    /// `fs_id` → 原始文件
    let filesByID: [UInt64: BaiduPanFile]
    /// `fs_id` → 时长(秒),只含这一次取到的。落盘缓存要连它一起存。
    let durations: [UInt64: Double]
}

/// 文件树来源浏览页(`FileSourceViewModel`)要的内容能力。缓存 / 封面怎么取是实现自己的事。
protocol FileSourceBrowsing: SourceProvider {
    /// 合成条目,含能当场拿到的封面 / 时长。
    func content(directory: String) async throws -> FileSourceDirectoryContent
    /// 第二趟:在线刮削(TMDB)补封面 / 简介。⛔ 不抛错,失败原样返回。
    func scrape(items: [SourceItem]) async -> [SourceItem]
    /// nil = 没失败
    func lastScrapeFailureDescription() async -> String?
}
