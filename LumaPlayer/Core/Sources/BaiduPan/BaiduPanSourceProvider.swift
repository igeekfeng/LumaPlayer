import Foundation

/// 百度网盘来源的浏览能力:列目录 → 合成条目 → 批量换封面地址与时长 →(可选)在线刮削。
/// 播放不走它,走 `BaiduPanSessionPreparer`。
actor BaiduPanSourceProvider: FileSourceBrowsing {

    /// `dlink` 给的是原图、没有缩放参数,这个值只用于缓存 key 分段。
    static let coverMaxWidth = 400

    nonisolated let sourceID: UUID
    private let connection: BaiduPanConnection
    /// 应用目录名
    private let folderName: String
    /// ⚠️ 全 App 共用一个实例(`AppContainer.metadataScraper`),它带查询缓存。
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

    /// 一个来源一个库:配了片库根就用它,否则用应用目录。
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

    /// 全程只发两次请求:一次 `list`、一次 `filemetas`。视频 id 并进封面那批一起取,
    /// 顺带拿到 `duration`(`docs/BAIDU_PAN_API.md` §4)。
    func content(directory: String) async throws -> FileSourceDirectoryContent {
        let files = try await connection.files(inDirectory: directory)
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: files, sourceID: sourceID)

        // 封面与视频同一批,逐个取会烧光配额
        let coverIDs = Set(synthesized.compactMap { $0.cover?.fsID })
        let playableIDs = Set(synthesized.compactMap { entry -> UInt64? in
            guard entry.item.kind.isPlayable else { return nil }
            return UInt64(entry.item.ref.itemID)
        })
        let meta = await connection.metaInfo(for: Array(coverIDs.union(playableIDs)))

        let items = synthesized.map { entry in
            var item = entry.item
            if let fsID = UInt64(item.ref.itemID), let duration = meta.durations[fsID] {
                item = item.withDuration(duration)
            }
            guard let cover = entry.cover, let url = meta.downloadURLs[cover.fsID] else {
                // 保持 nil,UI 降级成图标卡
                return item
            }
            return item.withPoster(
                .remote(
                    ownerID: sourceID,
                    url: url,
                    // ⛔ UA 与 `dlink` 的 sign 绑定,不能换(否则 `31326`,`docs/BAIDU_PAN_API.md` §1)
                    headers: ["User-Agent": BaiduPanUserAgent.download],
                    cacheKey: ImageDescriptor.baiduCoverKey(
                        sourceID: sourceID,
                        fsID: cover.fsID,
                        modifiedAt: cover.modifiedAt,
                        maxWidth: Self.coverMaxWidth
                    )
                )
            )
        }
        return FileSourceDirectoryContent(
            items: items,
            filesByID: Dictionary(uniqueKeysWithValues: files.map { ($0.fsID, $0) }),
            durations: meta.durations
        )
    }

    // MARK: - 在线刮削(TMDB)

    /// 第二趟:交给 TMDB 补封面 / 简介 / 年份(`docs/TMDB_API.md`)。
    /// 与 `content(directory:)` 分开,免得列目录等一串外部请求;由调用方在后台调度。
    ///
    /// ⛔ 不抛错:失败时原样返回,原因见 `lastScrapeFailureDescription`。
    func scrape(items: [SourceItem]) async -> [SourceItem] {
        await scraper.enrich(items)
    }

    /// nil = 没失败
    func lastScrapeFailureDescription() async -> String? {
        await scraper.lastFailureDescription
    }
}
