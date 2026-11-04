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
        let composed = compose(files: files)
        let enriched = await enrich(composed, newFiles: files, known: nil)
        return FileSourceDirectoryContent(
            items: enriched.items,
            filesByID: composed.filesByID,
            durations: enriched.durations
        )
    }

    // MARK: - 分页

    /// 列一页。⛔ 一次请求就返回,⛔ 不自动翻页。
    func page(directory: String, offset: Int, limit: Int) async throws -> FileSourcePage {
        let result = try await connection.page(
            inDirectory: directory, offset: offset, limit: limit)
        return FileSourcePage(
            files: result.files,
            hasMore: result.hasMore,
            // 百度的翻页是 `start += limit`(官方推荐的 `list` 翻页方式)。
            // ⛔ 不能用 `files.count`:解码时丢掉缺 `path` / `fs_id` 的条目会让它少于
            // 服务端实际推进的条数 → 漏项。
            nextOffset: result.nextOffset,
            // ⛔ 百度这一侧拿不到总数:`list` 的响应里既无 `total` 也无 `has_more`
            totalCount: nil
        )
    }

    /// 纯本地合成,不发请求。⛔ 要传**累计**的整套文件(见 `FileSourceBrowsing.compose`)。
    nonisolated func compose(files: [BaiduPanFile]) -> FileSourceComposedContent {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: files, sourceID: sourceID)
        var coverFileIDs: [String: UInt64] = [:]
        for entry in synthesized {
            guard let cover = entry.cover else { continue }
            coverFileIDs[entry.item.ref.itemID] = cover.fsID
        }
        return FileSourceComposedContent(
            items: synthesized.map(\.item),
            filesByID: Dictionary(
                files.map { ($0.fsID, $0) },
                uniquingKeysWith: { first, _ in first }),
            coverFileIDs: coverFileIDs
        )
    }

    /// 只为**还缺东西**的条目发请求 —— 重复取已取过的会白烧配额(§7)。
    ///
    /// - Parameter newFiles: 这一页**新增**的原始文件。它们的时长与封面地址要从这里取。
    /// - Parameter known: 已经取到过的条目(封面地址 / 时长)。⛔ 不再为它们发请求。
    ///
    /// ⚠️ **封面文件可能在后面的页**:合成器配封面靠的是「同目录的 `poster.jpg`」,
    /// 而那个文件未必和视频在同一页。第一页时配不上,第二页到达后合成器才认得出来 ——
    /// 所以判据是「这个条目的封面 / 时长拿到了没有」,⛔ 不是「这个条目是不是新来的」。
    func enrich(
        _ composed: FileSourceComposedContent,
        newFiles: [BaiduPanFile],
        known: FileSourceDirectoryContent? = nil
    ) async -> FileSourceEnrichedContent {
        let knownItems = Dictionary(
            (known?.items ?? []).map { ($0.ref.itemID, $0) },
            uniquingKeysWith: { first, _ in first })
        let knownDurations = known?.durations ?? [:]
        let newIDs = Set(newFiles.map(\.fsID))

        // 要向服务端要的:新文件本身(时长)+ 所有还没拿到地址的封面文件
        var wanted: Set<UInt64> = []
        var coverRequests: [(itemID: String, coverFSID: UInt64)] = []
        for item in composed.items {
            guard let fsID = UInt64(item.ref.itemID) else { continue }
            let previous = knownItems[item.ref.itemID]
            // 时长:只问**可播**条目。目录卡片永远没有时长,
            // ⛔ 不问它(否则每次翻页都把这些 id 再要一遍,白烧配额)
            if item.kind.isPlayable {
                let hasDuration = knownDurations[fsID] != nil
                    || previous?.durationSeconds != nil
                if newIDs.contains(fsID) || !hasDuration {
                    wanted.insert(fsID)
                }
            }
            // 封面:合成器现在认得出封面、而我们还没拿到地址的
            if let coverFSID = composed.coverFileIDs[item.ref.itemID],
               previous?.poster == nil,
               composed.filesByID[coverFSID] != nil {
                coverRequests.append((item.ref.itemID, coverFSID))
                wanted.insert(coverFSID)
            }
        }
        guard !wanted.isEmpty else {
            // 都要的都在手上:直接把已知的时长带回去
            return FileSourceEnrichedContent(
                items: composed.items,
                durations: knownDurations
            )
        }
        let meta = await connection.metaInfo(for: Array(wanted))

        var items = composed.items
        var durations = knownDurations
        for (offset, item) in items.enumerated() {
            guard let fsID = UInt64(item.ref.itemID) else { continue }
            // ⚠️ 本次没取到就用上一轮的值兜底,⛔ 不能直接跳过:
            // `compose` 重新造出来的条目 `durationSeconds` 恒 nil,
            // 跳过就会让**已加载的条目集体丢时长**(UI 读的是 `items[].durationSeconds`)
            guard let duration = meta.durations[fsID] ?? knownDurations[fsID] else { continue }
            items[offset] = item.withDuration(duration)
            durations[fsID] = duration
        }
        // 封面按条目回填(封面地址属于条目,不是属于封面文件)
        // ⚠️ 先建索引再回填:逐个 `firstIndex` 是 O(n²),一千条就是百万次比较
        var indexByID: [String: Int] = [:]
        for (offset, item) in items.enumerated() {
            indexByID[item.ref.itemID] = offset
        }
        for request in coverRequests {
            guard let url = meta.downloadURLs[request.coverFSID],
                  let index = indexByID[request.itemID]
            else { continue }
            items[index] = items[index].withPoster(
                .remote(
                    ownerID: sourceID,
                    url: url,
                    // ⛔ UA 与 `dlink` 的 sign 绑定,不能换(否则 `31326`,`docs/BAIDU_PAN_API.md` §1)
                    headers: ["User-Agent": BaiduPanUserAgent.download],
                    cacheKey: ImageDescriptor.baiduCoverKey(
                        sourceID: sourceID,
                        fsID: request.coverFSID,
                        modifiedAt: composed.filesByID[request.coverFSID]?.modifiedAt,
                        maxWidth: Self.coverMaxWidth
                    )
                )
            )
        }
        return FileSourceEnrichedContent(items: items, durations: durations)
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
