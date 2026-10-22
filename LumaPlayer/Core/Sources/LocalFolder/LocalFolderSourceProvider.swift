import Foundation

/// 本地文件夹来源的内容能力(`FileSourceBrowsing` 的本地实现)。
///
/// 一次目录读取:读盘列一层 → 合成条目(**与百度同一个合成器**,标题 / 季集 / 封面配对
/// 一套判据)→ 封面直接指向同目录的图片文件 → 读文件头补时长。TMDB 刮削与百度共用
/// 同一个刮削器(`scrape`),浏览页照样把它放在第二趟。
///
/// 与百度那边的差别都源于「读盘不花配额」:没有落盘目录缓存,封面不用另外换地址。
actor LocalFolderSourceProvider: FileSourceBrowsing {

    /// 封面缓存 key 里的宽度段(与 `BaiduPanSourceProvider.coverMaxWidth` 同一口径)。
    static let coverMaxWidth = 400

    nonisolated let sourceID: UUID
    private let source: LocalFolderSource
    /// 来源根目录的真实 URL(访问权已打开)。由组合根给:书签陈旧时要顺手写回注册表,
    /// 那件事不归这里管(`AppContainer.localFolderRoot`)。
    private let resolveRoot: @Sendable () async throws -> URL
    private let durations: LocalMediaDurationCache
    private let scraper: BaiduPanMetadataScraper

    init(
        source: LocalFolderSource,
        resolveRoot: @escaping @Sendable () async throws -> URL,
        durations: LocalMediaDurationCache,
        scraper: BaiduPanMetadataScraper
    ) {
        self.sourceID = source.id
        self.source = source
        self.resolveRoot = resolveRoot
        self.durations = durations
        self.scraper = scraper
    }

    // MARK: - SourceProvider

    /// 本地来源的「库」= 用户选的那个文件夹本身(一个来源一个)。
    func libraries() async throws -> [SourceLibrary] {
        [
            SourceLibrary(
                ref: SourceLibraryRef(sourceID: sourceID, libraryID: source.rootPath),
                title: source.displayName,
                kind: .folder
            )
        ]
    }

    func items(in library: SourceLibraryRef) async throws -> [SourceItem] {
        try await content(directory: library.libraryID).items
    }

    // MARK: - FileSourceBrowsing

    func content(directory: String) async throws -> FileSourceDirectoryContent {
        let root = try await resolveRoot()
        let files = try LocalFolderListing.files(inDirectory: directory, root: root, source: source)
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(files: files, sourceID: sourceID)
        // id 由路径哈希而来(`LocalFolderListing.fileID`),同一层里不会重复;
        // 万一撞了留第一条,⛔ 不让 `uniqueKeysWithValues` 把整层读崩
        let filesByID = Dictionary(files.map { ($0.fsID, $0) }, uniquingKeysWith: { first, _ in first })

        // 时长只读能播的那些(合成器判定过的),目录与图片不碰
        let playable = synthesized.compactMap { entry -> (file: BaiduPanFile, url: URL)? in
            guard entry.item.kind.isPlayable,
                  let fsID = UInt64(entry.item.ref.itemID),
                  let file = filesByID[fsID],
                  let url = try? LocalFolderListing.fileURL(
                      forPath: file.path, root: root, rootPath: source.rootPath)
            else { return nil }
            return (file, url)
        }
        let known = await durations.durations(for: playable)

        let items = synthesized.map { entry -> SourceItem in
            var item = entry.item
            if let fsID = UInt64(item.ref.itemID), let duration = known[fsID] {
                item = item.withDuration(duration)
            }
            // 封面就是同目录那张图:直接读盘,不像百度要先换 `dlink`
            guard let cover = entry.cover,
                  let url = try? LocalFolderListing.fileURL(
                      forPath: cover.path, root: root, rootPath: source.rootPath)
            else { return item }
            return item.withPoster(
                .localFile(
                    ownerID: sourceID,
                    url: url,
                    cacheKey: ImageDescriptor.localCoverKey(
                        sourceID: sourceID,
                        fileID: cover.fsID,
                        // 修改时间是版本段:换了封面图 → key 变 → 不会端出旧图
                        modifiedAt: cover.modifiedAt,
                        maxWidth: Self.coverMaxWidth)))
        }
        return FileSourceDirectoryContent(
            items: items,
            filesByID: filesByID,
            durations: known
        )
    }

    func scrape(items: [SourceItem]) async -> [SourceItem] {
        await scraper.enrich(items)
    }

    func lastScrapeFailureDescription() async -> String? {
        await scraper.lastFailureDescription
    }
}
