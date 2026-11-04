import Foundation

/// `FileSourceBrowsing` 的本地文件夹实现:读盘列一层 → 合成条目(与百度同一个合成器)→
/// 封面指向同目录图片 → 读文件头补时长。刮削器与百度共用。
/// 读盘不花配额,所以没有落盘目录缓存。
///
/// ⚠️ **本地文件夹不分页**:一次读盘就把这一层列全了。`page(directory:offset:limit:)`
/// 忽略 `offset` / `limit`,直接给整层并报 `hasMore: false` —— 让浏览页的翻页状态机
/// 有统一的形状(它照样能跑,只是不翻而已)。
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
        let composed = compose(files: files)
        let enriched = await enrich(composed, newFiles: files, known: nil)
        return FileSourceDirectoryContent(
            items: enriched.items,
            filesByID: composed.filesByID,
            durations: enriched.durations
        )
    }

    /// 本地文件夹一次列全,没有下一页。
    ///
    /// ⚠️ 读盘不花配额,但**每次都读整层**:切页时再读一次是白费 IO。
    /// ⇒ 本地文件夹直接一次给全,`hasMore` 恒 false —— 翻页状态机照样能跑(不翻而已)。
    func page(directory: String, offset: Int, limit: Int) async throws -> FileSourcePage {
        let root = try await resolveRoot()
        let files = try LocalFolderListing.files(inDirectory: directory, root: root, source: source)
        return FileSourcePage(
            files: files,
            hasMore: false,
            nextOffset: files.count,
            // 本地目录能直接数出来
            totalCount: files.count
        )
    }

    /// 纯本地合成,不发请求。⛔ 要传**累计**的整套文件(见 `FileSourceBrowsing.compose`)。
    nonisolated func compose(files: [BaiduPanFile]) -> FileSourceComposedContent {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(files: files, sourceID: sourceID)
        var coverFileIDs: [String: UInt64] = [:]
        for entry in synthesized {
            guard let cover = entry.cover else { continue }
            coverFileIDs[entry.item.ref.itemID] = cover.fsID
        }
        return FileSourceComposedContent(
            items: synthesized.map(\.item),
            // 哈希万一撞了留第一条,⛔ 不用 `uniqueKeysWithValues`(会崩)
            filesByID: Dictionary(
                files.map { ($0.fsID, $0) },
                uniquingKeysWith: { first, _ in first }),
            coverFileIDs: coverFileIDs
        )
    }

    /// 时长只读可播条目;封面指向同目录的图片,⛔ 不发请求。
    func enrich(
        _ composed: FileSourceComposedContent,
        newFiles: [BaiduPanFile],
        known: FileSourceDirectoryContent?
    ) async -> FileSourceEnrichedContent {
        // 书签解不开就不贴封面 / 时长,⛔ 不编值。正常路径上这一步在 `page()` 之后,
        // 而 `page()` 拿不到 root 时已经抛错了 —— 走不到这里。
        guard let root = try? await resolveRoot() else {
            return FileSourceEnrichedContent(
                items: composed.items, durations: known?.durations ?? [:])
        }
        let knownItems = Dictionary(
            (known?.items ?? []).map { ($0.ref.itemID, $0) },
            uniquingKeysWith: { first, _ in first })
        let knownDurations = known?.durations ?? [:]
        let newIDs = Set(newFiles.map(\.fsID))

        // 时长:新条目的,或上一轮没读到的
        let playable = composed.items.compactMap { entry -> (file: BaiduPanFile, url: URL)? in
            guard entry.kind.isPlayable,
                  let fsID = UInt64(entry.ref.itemID),
                  let file = composed.filesByID[fsID],
                  let url = try? LocalFolderListing.fileURL(
                      forPath: file.path, root: root, rootPath: source.rootPath)
            else { return nil }
            return (file, url)
        }
        // ⛔ 只读还没拿到时长的那些:重复读文件头是白费 IO
        let pending = playable.filter { entry in
            let fsID = entry.file.fsID
            return newIDs.contains(fsID) || knownDurations[fsID] == nil
        }
        let read = await durations.durations(for: pending)

        var items = composed.items
        var allDurations = knownDurations
        for (offset, item) in items.enumerated() {
            guard let fsID = UInt64(item.ref.itemID) else { continue }
            var updated = item
            if let duration = read[fsID] ?? knownDurations[fsID] {
                updated = updated.withDuration(duration)
                allDurations[fsID] = duration
            }
            // 封面:同目录的图,⛔ 不发请求。上一轮没配上的(封面文件在后面的页)现在补上
            if let coverFSID = composed.coverFileIDs[item.ref.itemID],
               knownItems[item.ref.itemID]?.poster == nil,
               let cover = composed.filesByID[coverFSID],
               let url = try? LocalFolderListing.fileURL(
                   forPath: cover.path, root: root, rootPath: source.rootPath) {
                updated = updated.withPoster(
                    .localFile(
                        ownerID: sourceID,
                        url: url,
                        cacheKey: ImageDescriptor.localCoverKey(
                            sourceID: sourceID,
                            fileID: coverFSID,
                            modifiedAt: cover.modifiedAt,
                            maxWidth: Self.coverMaxWidth)))
            }
            items[offset] = updated
        }
        return FileSourceEnrichedContent(items: items, durations: allDurations)
    }

    func scrape(items: [SourceItem]) async -> [SourceItem] {
        await scraper.enrich(items)
    }

    func lastScrapeFailureDescription() async -> String? {
        await scraper.lastFailureDescription
    }
}
