import Foundation

/// 夸克网盘来源的浏览能力:列目录 → 合成条目 →(可选)在线刮削。
/// 播放不走它,走 `QuarkSessionPreparer`。
///
/// 与另外两家的差别:
/// - **没有应用目录**:TV 端能读整个网盘,`libraryID` 与 `directory` 传的是从网盘根算起的
///   虚拟路径(`QuarkPath`);换成 `fid` 由 `QuarkConnection` 负责(§5.1)。
/// - **没有封面请求**:列表里的 `thumbnail_url` 是临时签名地址、只对图片条目有意义,
///   封面前端全部用 TMDB 刮削补 —— 省一次请求就是少一次风控面(§10)。
/// - **有时长字段但单位未实测**(§5.1),所以⛔ 不写进 `durations`。
/// - **有总数**(`total_count`),所以能精确回答「还有没有下一页」。
actor QuarkSourceProvider: FileSourceBrowsing {

    nonisolated let sourceID: UUID
    private let connection: QuarkConnection
    /// ⚠️ 全 App 共用一个实例(`AppContainer.metadataScraper`),它带查询缓存。
    private let scraper: BaiduPanMetadataScraper
    /// 来源显示名,只用于库标题
    private let displayName: String

    init(
        connection: QuarkConnection,
        sourceID: UUID,
        displayName: String,
        scraper: BaiduPanMetadataScraper
    ) {
        self.connection = connection
        self.sourceID = sourceID
        self.displayName = displayName
        self.scraper = scraper
    }

    // MARK: - SourceProvider

    /// 一个来源一个库:配了片库根就用它的路径,否则用网盘根。
    func libraries() async throws -> [SourceLibrary] {
        let root = try await connection.libraryRoot(for: sourceID)
        let libraryID = root?.path ?? QuarkLibraryRoot.root.path
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

    /// 一次列完(必要时翻页)+ 本地合成。⛔ 不额外取元信息。
    func content(directory: String) async throws -> FileSourceDirectoryContent {
        let entries = try await connection.files(in: directory)
        let files = entries.map { $0.file(parentPath: directory, sourceID: sourceID) }
        let composed = compose(files: files)
        return FileSourceDirectoryContent(
            items: composed.items,
            filesByID: composed.filesByID,
            // 时长单位未实测,⛔ 不填
            durations: [:]
        )
    }

    // MARK: - 分页

    /// 列一页。⛔ 一次请求就返回,⛔ 不自动翻页。
    func page(directory: String, offset: Int, limit: Int) async throws -> FileSourcePage {
        // 浏览页的翻页游标是「已取条数」,夸克的分页单位是 `page_index`。
        // ⚠️ 两边口径必须一致:只有从 0 开始、每页固定 `limit` 时才能整除换算,
        // 所以这里要求 offset 是 limit 的整数倍(浏览页就是这么推进的,见 `FileSourcePage.nextOffset`)。
        let pageIndex = limit > 0 ? offset / limit : 0
        let result = try await connection.listPage(
            in: directory, pageIndex: pageIndex, pageSize: limit)
        let files = result.files.map { $0.file(parentPath: directory, sourceID: sourceID) }
        return FileSourcePage(
            files: files,
            hasMore: result.hasMore,
            // 服务端口径:整页推进(⛔ 不用 `files.count`,解码丢条目会让它少算)
            nextOffset: (pageIndex + 1) * limit,
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
            // 夸克不取封面(§10):封面靠 TMDB 刮削补
            coverFileIDs: [:]
        )
    }

    /// 夸克列表里既没有封面地址也没有可信时长,所以这一步零请求。
    func enrich(
        _ composed: FileSourceComposedContent,
        newFiles: [BaiduPanFile],
        known: FileSourceDirectoryContent?
    ) async -> FileSourceEnrichedContent {
        FileSourceEnrichedContent(items: composed.items, durations: known?.durations ?? [:])
    }

    // MARK: - 在线刮削(TMDB)

    /// 第二趟:交给 TMDB 补封面 / 简介 / 年份(`docs/TMDB_API.md`)。⛔ 不抛错:失败原样返回。
    func scrape(items: [SourceItem]) async -> [SourceItem] {
        await scraper.enrich(items)
    }

    /// nil = 没失败
    func lastScrapeFailureDescription() async -> String? {
        await scraper.lastFailureDescription
    }
}
