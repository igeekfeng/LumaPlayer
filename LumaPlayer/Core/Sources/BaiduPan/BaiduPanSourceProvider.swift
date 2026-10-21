import Foundation

/// 百度网盘来源的内容能力(列库 / 列条目)。
///
/// ## 它把「一次目录读取」的全部步骤收在一处
///
/// 列目录 → 合成条目 → **批量**换封面地址 → (可选)**在线刮削**补封面。
/// 上层(浏览页)只管拿 `[SourceItem]`,
/// ⛔ 不必知道封面为什么要另外发一次请求、也不必知道刮削走的是哪个服务。
///
/// ⛔ 播放不走它 —— 那条走 `BaiduPanSessionPreparer`(生命周期与浏览不同)。
actor BaiduPanSourceProvider: SourceProvider {

    /// 封面取到多宽。
    ///
    /// ⚠️ 百度 `dlink` 给的是**原图**,没有服务端缩放参数,所以这个值只用于
    /// **缓存 key 分段**(与 `ImageSpec.maxWidth` 的口径一致)——
    /// 它不影响取到的字节数,只是让不同尺寸的卡片各占一格缓存。
    static let coverMaxWidth = 400

    nonisolated let sourceID: UUID
    private let connection: BaiduPanConnection
    /// 应用目录名(空状态提示要用)
    private let folderName: String
    /// 在线刮削(TMDB)。⚠️ **全 App 共用一个实例** —— 它带查询缓存,
    /// 每次列目录都新建一个的话,同一个目录会被反复问(`AppContainer.metadataScraper`)。
    private let scraper: BaiduPanMetadataScraper

    init(
        connection: BaiduPanConnection,
        sourceID: UUID,
        folderName: String,
        scraper: BaiduPanMetadataScraper
    ) {
        self.connection = connection
        self.sourceID = sourceID
        self.folderName = folderName
        self.scraper = scraper
    }

    // MARK: - SourceProvider

    /// 百度来源的「库」入口 = 它配的**片库根**(一个来源一个);
    /// 没配时退回应用目录本身(标题用应用目录名)。
    func libraries() async throws -> [SourceLibrary] {
        guard let root = try await connection.libraryRoot(for: sourceID) else {
            let directory = try await connection.applicationDirectory()
            return [
                SourceLibrary(
                    ref: SourceLibraryRef(sourceID: sourceID, libraryID: directory),
                    title: folderName.isEmpty ? "百度网盘" : folderName,
                    kind: .folder
                )
            ]
        }
        return [
            SourceLibrary(
                ref: SourceLibraryRef(sourceID: sourceID, libraryID: root.path),
                title: root.displayName,
                kind: .folder
            )
        ]
    }

    func items(in library: SourceLibraryRef) async throws -> [SourceItem] {
        try await content(directory: library.libraryID).items
    }

    /// 一次目录读取的**完整结果**。
    ///
    /// 为什么把原始文件一起交回去:合成后的 `SourceItem` 只保留展示所需字段,
    /// 而播放与「进目录」要的 `path` / 真实文件名不在里面。
    /// ⛔ 让调用方**再列一次目录**去拿它们是不可接受的 ——
    /// 配额见 §7(`docs/BAIDU_PAN_API.md`)。
    struct DirectoryContent: Sendable {
        let items: [SourceItem]
        /// `fs_id` → 原始文件
        let filesByID: [UInt64: BaiduPanFile]
        /// `fs_id` → 时长(秒)。只含这一次批量取到的(**列表接口本身不给时长**)。
        /// 落盘缓存要连它一起存 —— 否则冷启动的卡片上又只剩标题没有时长。
        let durations: [UInt64: Double]
    }

    /// 列一个目录 → 合成条目 → **批量**换封面地址与时长(全程只发两次请求:
    /// 一次 `list`、一次 `filemetas`)。
    ///
    /// ## 时长为什么在这一趟里拿
    ///
    /// `filemetas` 带 `needmedia=1`,视频条目的 `duration` 与封面的 `dlink`
    /// 是**同一个响应**里的两份字段(`docs/BAIDU_PAN_API.md` §4)。
    /// 封面那批 id 本来就要发一次,把视频 id 并进去几乎不增加请求数,
    /// 却换来卡片上的时长 / 剩余 / 进度条 —— 这是「百度不给时长」这件事
    /// 在客户端能补的部分。
    func content(directory: String) async throws -> DirectoryContent {
        let files = try await connection.files(inDirectory: directory)
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: files, sourceID: sourceID)

        // 封面与视频**同一批**:收集所有配到的图片 `fs_id` 与可播条目的 `fs_id`,
        // 一次批量换地址 + 时长 —— 逐个取会烧光配额,见 `metaInfo`。
        let coverIDs = Set(synthesized.compactMap { $0.cover?.fsID })
        let playableIDs = Set(synthesized.compactMap { entry -> UInt64? in
            guard entry.item.kind.isPlayable else { return nil }
            return UInt64(entry.item.ref.itemID)
        })
        let meta = await connection.metaInfo(for: Array(coverIDs.union(playableIDs)))

        let items = synthesized.map { entry in
            var item = entry.item
            // 时长:先补,再补封面 —— 两者互不影响,顺序只是让下面的 guard 简单
            if let fsID = UInt64(item.ref.itemID), let duration = meta.durations[fsID] {
                item = item.withDuration(duration)
            }
            guard let cover = entry.cover, let url = meta.downloadURLs[cover.fsID] else {
                // 没配到图 / 换了地址也拿不到 → 保持 nil,UI 降级成图标卡
                return item
            }
            return item.withPoster(
                .remote(
                    ownerID: sourceID,
                    url: url,
                    // ⚠️ UA 必须与 `dlink` 的 sign 绑定的一致:不给会撞 `31326` 防盗链
                    // (`docs/BAIDU_PAN_API.md` §1)。⛔ 不能换成别的 UA。
                    headers: ["User-Agent": BaiduPanUserAgent.download],
                    cacheKey: ImageDescriptor.baiduCoverKey(
                        sourceID: sourceID,
                        fsID: cover.fsID,
                        // 封面文件的 `server_mtime` 就是缓存 key 的版本段:
                        // 换了封面 → key 变 → 不会再端出旧图
                        modifiedAt: cover.modifiedAt,
                        maxWidth: Self.coverMaxWidth
                    )
                )
            )
        }
        return DirectoryContent(
            items: items,
            filesByID: Dictionary(uniqueKeysWithValues: files.map { ($0.fsID, $0) }),
            durations: meta.durations
        )
    }

    // MARK: - 在线刮削(TMDB)

    /// 第二趟:把目录条目交给 TMDB 补封面 / 简介 / 年份(`docs/TMDB_API.md`)。
    ///
    /// ⚠️ 为什么与 `content(directory:)` **分开**,而不是收在同一趟里:
    /// 这一趟要发 N 次 TMDB 请求(N = 能认出来的片子数)。把它塞进列目录那一趟,
    /// 就等于让「看目录」等一串外部请求 —— TMDB 连不上时整个片库都会卡住。
    /// 所以调度权交给调用方(浏览页):列表先出来,这一趟在后台跑完再就地换图。
    ///
    /// ⛔ 不抛错:刮削是附加信息,失败时原样返回(`lastScrapeFailureDescription` 里有原因)。
    func scrape(items: [SourceItem]) async -> [SourceItem] {
        await scraper.enrich(items)
    }

    /// 上一次刮削失败的原因(nil = 没失败)。界面拿它给一句提示。
    func lastScrapeFailureDescription() async -> String? {
        await scraper.lastFailureDescription
    }
}
