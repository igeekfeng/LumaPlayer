import Foundation

/// 115 网盘来源的浏览能力:列目录 → 合成条目 →(可选)在线刮削。
/// 播放不走它,走 `Pan115SessionPreparer`。
///
/// 与 `BaiduPanSourceProvider` 的差别:
/// - **没有应用目录**:Cookie 能读整个网盘,`libraryID` 与 `content(directory:)` 传的是
///   从网盘根算起的路径(`"/"` 是根),与浏览页那套路径模型一致;换成 `cid` 由
///   `Pan115Connection` 负责(§3)。
/// - **没有封面请求**:115 列表里的 `u` 是缩略图地址,要额外签名且只对图片条目有意义;
///   本项目用 TMDB 刮削补封面,省一次请求 = 少一次风控面(§6)。
/// - 列目录时顺手把 `fsID → pick_code` 塞进 `Pan115PickCodeCache`,播放时不用再列一次。
/// - **有总数**:115 的 `count` 是目录总条目数(§3),所以能精确回答「还有没有下一页」。
actor Pan115SourceProvider: FileSourceBrowsing {

    nonisolated let sourceID: UUID
    private let connection: Pan115Connection
    private let pickCodes: Pan115PickCodeCache
    /// ⚠️ 全 App 共用一个实例(`AppContainer.metadataScraper`),它带查询缓存。
    private let scraper: BaiduPanMetadataScraper
    /// 来源显示名,只用于库标题
    private let displayName: String

    init(
        connection: Pan115Connection,
        sourceID: UUID,
        displayName: String,
        pickCodes: Pan115PickCodeCache,
        scraper: BaiduPanMetadataScraper
    ) {
        self.connection = connection
        self.sourceID = sourceID
        self.displayName = displayName
        self.pickCodes = pickCodes
        self.scraper = scraper
    }

    // MARK: - SourceProvider

    /// 一个来源一个库:配了片库根就用它的路径,否则用网盘根。
    func libraries() async throws -> [SourceLibrary] {
        let root = try await connection.libraryRoot(for: sourceID)
        let libraryID = root?.path ?? Pan115LibraryRoot.root.path
        let title = root.map { $0.displayName } ?? displayName
        return [
            SourceLibrary(
                ref: SourceLibraryRef(sourceID: sourceID, libraryID: libraryID),
                title: title.isEmpty ? displayName : title,
                kind: .folder
            )
        ]
    }

    func items(in library: SourceLibraryRef) async throws -> [SourceItem] {
        try await content(directory: library.libraryID).items
    }

    /// 一次 `files` 请求(必要时翻页)+ 本地合成。⛔ 不额外取元信息。
    func content(directory: String) async throws -> FileSourceDirectoryContent {
        let entries = try await connection.files(in: directory)
        // ⚠️ 顺手把 pick_code 存起来:这一趟也列出了 `pc` 字段,
        // 不存就是白丢信息 —— 播放时要多花一次列目录(115 限速 ≥500ms,§6)。
        // 季文件夹的分集清单走的就是这条路径(`loadEpisodes`)。
        await storePickCodes(entries)
        let files = entries.compactMap { $0.file(parentPath: directory) }
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
        let result = try await connection.listPage(
            in: directory, offset: offset, limit: limit)
        let files = result.entries.compactMap { $0.file(parentPath: directory) }
        // 顺手把 pick_code 存起来:播放时就不用再列一次目录(§6 限速,省一次就是省 500ms)
        await storePickCodes(result.entries)
        return FileSourcePage(
            files: files,
            // ⚠️ 服务端不认我们请求的 offset(它悄悄从头开始算了)→ 当到底,
            // ⛔ 不继续翻:否则同一个页面会被反复取(§3 的 offset 回绕)
            hasMore: result.hasMore && result.isOffsetHonored,
            nextOffset: result.nextOffset,
            // ⚠️ 115 的 `count` 是**当前查询条件下**的总数,而本项目的请求带
            // `show_dir=1` ⇒ 它**含子目录**(`docs/PAN115_API.md` §3.1)。
            // ⛔ 别把它当成「可播条目数」显示给用户 —— 那会把剧文件夹也算进去。
            totalCount: result.totalCount
        )
    }

    /// 纯本地合成,不发请求。⛔ 要传**累计**的整套文件(见 `FileSourceBrowsing.compose`)。
    nonisolated func compose(files: [BaiduPanFile]) -> FileSourceComposedContent {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(files: files, sourceID: sourceID)
        return FileSourceComposedContent(
            items: synthesized.map(\.item),
            filesByID: Dictionary(
                files.map { ($0.fsID, $0) },
                uniquingKeysWith: { first, _ in first }),
            // 115 不取封面(§6):封面靠 TMDB 刮削补
            coverFileIDs: [:]
        )
    }

    /// 115 不取封面也不取时长(`files` 列表里都没有,§3)——所以这一步零请求。
    func enrich(
        _ composed: FileSourceComposedContent,
        newFiles: [BaiduPanFile],
        known: FileSourceDirectoryContent?
    ) async -> FileSourceEnrichedContent {
        FileSourceEnrichedContent(
            items: composed.items,
            durations: known?.durations ?? [:]
        )
    }

    /// 把 pick_code 存起来:播放时就不用再列一次目录(§6 限速,省一次就是省 500ms)。
    private func storePickCodes(_ entries: [Pan115FileEntry]) async {
        var pickCodesByID: [UInt64: String] = [:]
        for entry in entries {
            guard !entry.isDirectory, let pickCode = entry.pickCode, !pickCode.isEmpty,
                  let id = entry.numericID else { continue }
            pickCodesByID[id] = pickCode
        }
        guard !pickCodesByID.isEmpty else { return }
        await pickCodes.store(pickCodesByID)
    }

    // MARK: - 在线刮削(TMDB)

    /// 第二趟:交给 TMDB 补封面 / 简介 / 年份(`docs/TMDB_API.md`)。
    /// 与 `content(directory:)` 分开,免得列目录等一串外部请求。
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
