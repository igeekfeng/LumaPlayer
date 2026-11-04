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

/// 文件树来源(百度网盘 / 115 网盘 / 本地文件夹)一次目录读取的完整结果。
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

/// 合成出来的条目(还没贴封面 / 时长)。
///
/// 封面与时长要另发请求(百度的 `dlink` 8 小时过期,`filemetas` 是配额大头),所以合成与取元信息分成两步。
struct FileSourceComposedContent: Sendable {
    let items: [SourceItem]
    let filesByID: [UInt64: BaiduPanFile]
    /// 条目 id → 它的封面文件 `fs_id`。⛔ 封面地址要由 `enrich` 取回来再贴上。
    /// 115 恒空(不取封面,§6);本地文件夹的封面是同目录的图,⛔ 不发请求。
    let coverFileIDs: [String: UInt64]
}/// 贴好封面 / 时长的结果。
struct FileSourceEnrichedContent: Sendable {
    let items: [SourceItem]
    /// `fs_id` → 时长(秒)
    let durations: [UInt64: Double]
}

/// 列目录的一页(浏览页按需翻页用)。
///
/// ⚠️ 两家网盘的判据不同,⛔ 不要互相套用:
/// - 百度 `method=list` 的响应**没有**总数字段(既无 `total` 也无 `has_more` —— 那两个是
///   `method=listall` 的字段,`docs/BAIDU_PAN_API.md` §2.2),所以 `hasMore` 只能靠
///   「这一页不满」推断,`totalCount` 恒 nil。
/// - 115 的 `count` **是目录总条目数**(官方 SDK 注释「当前目录文件数量」),
///   所以 `hasMore` 是精确的,`totalCount` 有值。
struct FileSourcePage: Sendable {
    /// 这一页的原始文件
    let files: [BaiduPanFile]
    /// 还有没有下一页
    let hasMore: Bool
    /// 下一页的偏移量。⛔ 用它推进,不要自行累加固定步长
    /// (115 服务端会回显它认的 `offset`,自行累加可能回绕)。
    let nextOffset: Int
    /// 目录总条目数。nil = 来源没给总数
    let totalCount: Int?
}

/// 合并两批原始文件,按 `fs_id` 去重(保留先出现的)。
///
/// ⚠️ 去重是必要的:游标不可信时(老落盘缓存复原出来的偏移量是 0,见
/// `FileSourceDirectoryState.restoring`),这一页可能与已有内容重叠,直接相加会出现重复条目。
func mergingFileSources(_ existing: [BaiduPanFile], _ new: [BaiduPanFile]) -> [BaiduPanFile] {
    var seen = Set(existing.map(\.fsID))
    var result = existing
    for file in new where seen.insert(file.fsID).inserted {
        result.append(file)
    }
    return result
}

/// 从翻页状态里**剔除**一条(删掉的文件),⛔ 不是整个丢掉。
///
/// ⚠️ 丢掉整个状态会让 `hasMoreItems` 变 false → 页脚消失 → 用户以为目录就这些,
/// 而这一层其余几百条还在屏幕上、却再也翻不出后面的页。
/// 游标不动:删一条不改变服务端的位置(它只是从目录里少了一项)。
func removingFileSource(
    _ fsID: UInt64, from state: FileSourceDirectoryState
) -> FileSourceDirectoryState {
    guard state.files.contains(where: { $0.fsID == fsID }) else { return state }
    let remaining = state.files.filter { $0.fsID != fsID }
    let content = FileSourceDirectoryContent(
        items: state.content.items.filter { $0.ref.itemID != String(fsID) },
        filesByID: state.content.filesByID.filter { $0.key != fsID },
        durations: state.content.durations.filter { $0.key != fsID }
    )
    return FileSourceDirectoryState(
        content: content,
        files: remaining,
        hasMore: state.hasMore,
        nextOffset: state.nextOffset,
        totalCount: state.totalCount
    )
}

/// 浏览页里一个目录的状态:已列出的内容 + 翻页游标。
struct FileSourceDirectoryState: Sendable {
    /// 已合成并贴好封面 / 时长的内容
    var content: FileSourceDirectoryContent
    /// 累计的原始文件(有序)。⛔ 合成要拿**整套**文件,不能只留最后那一页
    /// (见 `FileSourceBrowsing.compose`)。
    var files: [BaiduPanFile]
    /// 还有没有下一页
    var hasMore: Bool
    /// 下一页的偏移量
    var nextOffset: Int
    /// 目录总条目数。nil = 来源没给
    var totalCount: Int?

    /// 从一份**不完整**的内容复原(落盘缓存命中时用)。
    ///
    /// 落盘缓存只存文件与时长,⛔ 存不了翻页游标(百度那一侧连总数都没有)。
    /// 所以复原时:「还没列完」= true,下一页的偏移量按**已有条数**算。
    ///
    /// ⚠️ 为什么「已有条数」就是对的偏移量:
    /// 百度 `list` 的 `start` 就是「跳过前 N 条」,而服务端是**先全目录排序再切片**
    /// (`docs/BAIDU_PAN_API.md` §7.1)。⇒ 列到第 N 条,下一页的起点就是 N。
    /// 老版本写的缓存也是按这个口径列的(自动翻页到不满一页为止),
    /// 所以它存下的条数同样对得上位置 —— 即便目录大到被 `maxPages` 截断,
    /// 截掉的也是**尾部**,⛔ 不影响前面条目的位置。
    ///
    /// - Parameter isComplete: 这一份是不是**整层**。整层 ⇒ 没有下一页。
    static func restoring(
        _ content: FileSourceDirectoryContent,
        isComplete: Bool
    ) -> FileSourceDirectoryState {
        let files = content.filesByID.values.sorted { $0.fsID < $1.fsID }
        return FileSourceDirectoryState(
            content: content,
            files: files,
            hasMore: !isComplete,
            // 已有条数 = 服务端的下一个起点
            nextOffset: files.count,
            // 百度拿不到总数,⛔ 不猜
            totalCount: nil
        )
    }
}

/// 文件树来源浏览页(`FileSourceViewModel`)要的内容能力。缓存 / 封面怎么取是实现自己的事。
protocol FileSourceBrowsing: SourceProvider {
    /// 一次读完整层,含能当场拿到的封面 / 时长。
    ///
    /// ⛔ 只给「必须拿到整层」的场景用(季文件夹的分集清单、集数统计那些 —— 目录不大)。
    /// 浏览页走 `page` + `compose` 按需翻,⛔ 不一次把整个目录拉完。
    func content(directory: String) async throws -> FileSourceDirectoryContent

    /// 列一页原始文件。
    ///
    /// ⛔ 只发一次请求就返回,⛔ 不自动翻页:浏览页滚到底再取下一页。
    func page(directory: String, offset: Int, limit: Int) async throws -> FileSourcePage

    /// 把**累计**的整套原始文件合成为条目(纯本地,不发请求)。
    ///
    /// ⛔ 必须传整套而不是一页:合成器拿整个目录判断「成串的集号」
    /// (`looksLikeEpisodeSequence`)并配对同目录封面(`poster.jpg`),只给一页会判错
    /// (单集的 `01.mp4` 会被当成电影,封面也会配不上)。
    ///
    /// `nonisolated`:纯函数,不碰 actor 状态。
    nonisolated func compose(files: [BaiduPanFile]) -> FileSourceComposedContent

    /// 贴上封面与时长。
    ///
    /// - Parameter composed: `compose` 的结果。⛔ 要传**累计**的那份,不是只传一页 ——
    ///   返回的 `items` 是整套的,只给一页的话页面上的旧条目会集体丢封面。
    /// - Parameter newFiles: 这一页**新增**的原始文件。它们的时长与封面地址要从这里取。
    /// - Parameter known: 上一轮的结果。⛔ 用来避免重复取已经拿到的东西(配额,§7),
    ///   同时让「封面文件在后面的页」这种情形能补上(见实现里的注释)。
    func enrich(
        _ composed: FileSourceComposedContent,
        newFiles: [BaiduPanFile],
        known: FileSourceDirectoryContent?
    ) async -> FileSourceEnrichedContent

    /// 第二趟:在线刮削(TMDB)补封面 / 简介。⛔ 不抛错,失败原样返回。
    func scrape(items: [SourceItem]) async -> [SourceItem]
    /// nil = 没失败
    func lastScrapeFailureDescription() async -> String?
}
