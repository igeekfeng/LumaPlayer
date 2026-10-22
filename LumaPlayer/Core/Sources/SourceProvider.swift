import Foundation

/// 一个来源能提供的**内容**能力(列库 / 列条目)。
///
/// ## 为什么播放不走这里
///
/// 取播放会话那条路走 `PlaybackSessionPreparing`:它要按来源装配,
/// 并随 `PlaybackRequest` 一起进播放页,生命周期与「浏览」不同。
/// 硬塞进同一个协议会让「谁在什么时候被调」变得说不清。
///
/// ## 为什么是 `Actor` 而不是值类型
///
/// 实现要复用 `ServerConnection` / `BaiduPanConnection` 的状态
/// (token 不共享,`CLAUDE.md`「架构主线」),那两个都是 actor。
protocol SourceProvider: Actor {
    /// 来源身份(路由与图片缓存 key 用)
    nonisolated var sourceID: UUID { get }
    /// 库入口
    func libraries() async throws -> [SourceLibrary]
    /// 列一个库 / 目录下的条目
    func items(in library: SourceLibraryRef) async throws -> [SourceItem]
}

/// **文件树来源**(百度网盘 / 本地文件夹)一次目录读取的完整结果。
///
/// 这两个来源都只有一棵目录树、没有服务端的媒体结构,所以浏览页
/// (`FileSourceViewModel`)对它们是同一套:列一层 → 合成条目 → 刮削补图。
///
/// 为什么把原始文件一起交回去:合成后的 `SourceItem` 只保留展示所需字段,
/// 而播放与「进目录」要的 `path` / 真实文件名不在里面。
/// ⛔ 让调用方**再列一次目录**去拿它们是不可接受的 ——
/// 百度的配额见 §7(`docs/BAIDU_PAN_API.md`)。
///
/// ⚠️ 文件统一用 `BaiduPanFile` 这个形状装(本地文件夹也是):字段语义是
/// 「来源内稳定 id + 来源内路径 + 文件名 + 大小 / 修改时间」,两边都有;
/// 名字是百度先落地留下的,见 `LocalFolderListing` 对 `fsID` 的说明。
struct FileSourceDirectoryContent: Sendable {
    let items: [SourceItem]
    /// `fs_id` → 原始文件
    let filesByID: [UInt64: BaiduPanFile]
    /// `fs_id` → 时长(秒)。只含这一次取到的(**百度列表接口本身不给时长**,
    /// 本地文件夹则是读文件头读得出来的那些)。
    /// 落盘缓存要连它一起存 —— 否则冷启动的卡片上又只剩标题没有时长。
    let durations: [UInt64: Double]
}

/// 文件树来源浏览页(`FileSourceViewModel`)要的内容能力。
///
/// 两个实现:`BaiduPanSourceProvider`(网盘,配额紧)与 `LocalFolderSourceProvider`
/// (本机目录,读盘)。浏览页只认这个协议 —— 「列这一层要不要缓存 / 封面怎么取」
/// 是实现自己的事。
protocol FileSourceBrowsing: SourceProvider {
    /// 列一个目录 → 合成条目(含能当场拿到的封面 / 时长)。
    func content(directory: String) async throws -> FileSourceDirectoryContent
    /// 第二趟:在线刮削(TMDB)补封面 / 简介。⛔ 不抛错,失败原样返回。
    func scrape(items: [SourceItem]) async -> [SourceItem]
    /// 上一次刮削失败的原因(nil = 没失败)。
    func lastScrapeFailureDescription() async -> String?
}
