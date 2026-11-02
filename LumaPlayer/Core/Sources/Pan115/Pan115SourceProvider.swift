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

        // 顺手把 pick_code 存起来:播放时就不用再列一次目录(§6 限速,省一次就是省 500ms)
        var pickCodesByID: [UInt64: String] = [:]
        for entry in entries {
            guard !entry.isDirectory, let pickCode = entry.pickCode, !pickCode.isEmpty,
                  let id = entry.numericID else { continue }
            pickCodesByID[id] = pickCode
        }
        await pickCodes.store(pickCodesByID)

        let files = entries.compactMap { $0.file(parentPath: directory) }
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(files: files, sourceID: sourceID)

        return FileSourceDirectoryContent(
            items: synthesized.map(\.item),
            filesByID: Dictionary(uniqueKeysWithValues: files.map { ($0.fsID, $0) }),
            durations: [:]
        )
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
