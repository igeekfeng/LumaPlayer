import Foundation

/// `FileSourceBrowsing` 的本地文件夹实现:读盘列一层 → 合成条目(与百度同一个合成器)→
/// 封面指向同目录图片 → 读文件头补时长。刮削器与百度共用。
/// 读盘不花配额,所以没有落盘目录缓存。
actor LocalFolderSourceProvider: FileSourceBrowsing {

    /// 只用于缓存 key 分段,同 `BaiduPanSourceProvider.coverMaxWidth`。
    static let coverMaxWidth = 400

    nonisolated let sourceID: UUID
    private let source: LocalFolderSource
    /// 由组合根给(`AppContainer.localFolderRoot`):书签陈旧时写回注册表不归这里管。
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

    /// 一个来源一个库:用户选的文件夹本身。
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
        // 哈希万一撞了留第一条,⛔ 不用 `uniqueKeysWithValues`(会崩)
        let filesByID = Dictionary(files.map { ($0.fsID, $0) }, uniquingKeysWith: { first, _ in first })

        // 时长只读可播条目
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
