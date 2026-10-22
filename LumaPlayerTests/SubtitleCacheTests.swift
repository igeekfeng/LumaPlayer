import XCTest
@testable import LumaPlayer

/// 字幕缓存(`SubtitleFileStore`)、每集字幕记录(`SubtitleBindingStore`)、`SubtitleService` 先查缓存。
/// 起播时的自动挂载(`PlayerViewModel.restoreRememberedSubtitle`)要真起 mpv,单测验不到,需真实 App 手验。
final class SubtitleCacheTests: XCTestCase {

    private var directory: URL!
    private static let srtText = "1\n00:00:01,000 --> 00:00:02,000\n你好\n"
    private static let day: TimeInterval = 24 * 60 * 60

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "LumaPlayer-subtitle-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        MockEmbyURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        MockEmbyURLProtocol.reset()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private var storeDirectory: URL { directory.appending(path: "store", directoryHint: .isDirectory) }

    // MARK: - 布局与查缓存

    func testLocalImportDedupesByContentAndKeepsOriginalName() async throws {
        let first = directory.appending(path: "一拳超人.zh-Hans.srt")
        let second = directory.appending(path: "copy/一拳超人.zh-Hans.srt")
        try FileManager.default.createDirectory(
            at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.srtText.utf8).write(to: first)
        try Data(Self.srtText.utf8).write(to: second)

        let store = SubtitleFileStore(directory: storeDirectory)
        let a = try await store.importLocalFile(at: first)
        let b = try await store.importLocalFile(at: second)

        XCTAssertEqual(a.relativePath, b.relativePath, "同一份内容导入两次只存一份")
        XCTAssertTrue(a.relativePath.hasPrefix("local-"))
        XCTAssertTrue(a.relativePath.hasSuffix("/一拳超人.zh-Hans.srt"), "保留原文件名")
        XCTAssertEqual(a.title, "一拳超人.zh-Hans")
    }

    func testCachedFilePrefersFormatAndExistingFileRejectsEscapes() async throws {
        let store = SubtitleFileStore(directory: storeDirectory)
        _ = try await store.storeDownloaded(data: Data("[Script Info]\n".utf8), fileName: "a.ass", group: "assrt-1")
        _ = try await store.storeDownloaded(data: Data(Self.srtText.utf8), fileName: "a.srt", group: "assrt-1")

        let cached = try await store.cachedFile(group: "assrt-1")
        XCTAssertEqual(cached?.relativePath, "assrt-1/a.srt", "同组有多个时 srt 优先")
        XCTAssertEqual(cached?.title, "a")
        let missing = try await store.cachedFile(group: "assrt-2")
        XCTAssertNil(missing)

        let escaped = await store.existingFile(relativePath: "../store/assrt-1/a.srt")
        XCTAssertNil(escaped, "记录里的路径不能跳出缓存目录")
        let flat = await store.existingFile(relativePath: "a.srt")
        XCTAssertNil(flat, "只认 <组>/<文件名> 两段")
    }

    func testSafeFileNameStripsPathAndTruncates() {
        XCTAssertEqual(SubtitleFileStore.safeFileName("../../evil/x.srt"), "x.srt")
        XCTAssertEqual(SubtitleFileStore.safeFileName("a:b.ass"), "a_b.ass")
        let long = String(repeating: "长", count: 200) + ".srt"
        let safe = SubtitleFileStore.safeFileName(long)
        XCTAssertLessThanOrEqual(safe.utf8.count, 240)
        XCTAssertTrue(safe.hasSuffix(".srt"), "截断基名、保留扩展名")
    }

    // MARK: - 清理

    func testCleanUpRemovesStaleUnreferencedGroupsOnly() async throws {
        let store = SubtitleFileStore(directory: storeDirectory)
        let now = Date()
        let stale = try await store.storeDownloaded(data: Data(Self.srtText.utf8), fileName: "old.srt", group: "assrt-1")
        let kept = try await store.storeDownloaded(data: Data(Self.srtText.utf8), fileName: "bound.srt", group: "assrt-2")
        let fresh = try await store.storeDownloaded(data: Data(Self.srtText.utf8), fileName: "new.srt", group: "assrt-3")
        try setModified(stale.url, now.addingTimeInterval(-100 * Self.day))
        try setModified(kept.url, now.addingTimeInterval(-100 * Self.day))
        // 组目录之外平铺的文件(旧布局)也要能被清掉
        let legacy = storeDirectory.appending(path: "assrt-9-0.srt")
        try Data(Self.srtText.utf8).write(to: legacy)
        try setModified(legacy, now.addingTimeInterval(-100 * Self.day))

        let report = try await store.cleanUp(now: now, keeping: ["assrt-2"])

        XCTAssertEqual(report.removedGroups, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.url.path), "被记住的不管多旧都留着")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.url.path))
    }

    func testCleanUpEvictsLeastRecentlyUsedOverByteLimit() async throws {
        let store = SubtitleFileStore(directory: storeDirectory)
        let now = Date()
        let payload = Data(String(repeating: "a", count: 1000).utf8)
        let oldest = try await store.storeDownloaded(data: payload, fileName: "1.srt", group: "assrt-1")
        let middle = try await store.storeDownloaded(data: payload, fileName: "2.srt", group: "assrt-2")
        let newest = try await store.storeDownloaded(data: payload, fileName: "3.srt", group: "assrt-3")
        try setModified(oldest.url, now.addingTimeInterval(-3 * Self.day))
        try setModified(middle.url, now.addingTimeInterval(-2 * Self.day))
        try setModified(newest.url, now.addingTimeInterval(-1 * Self.day))

        let report = try await store.cleanUp(now: now, byteLimit: 2500, keeping: [])

        XCTAssertEqual(report.removedGroups, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.url.path), "超量时先删最久没用的")
        XCTAssertTrue(FileManager.default.fileExists(atPath: middle.url.path))
        XCTAssertLessThanOrEqual(report.remainingBytes, 2500)
    }

    func testMarkUsedProtectsFromAgeCleanup() async throws {
        let store = SubtitleFileStore(directory: storeDirectory)
        let stored = try await store.storeDownloaded(data: Data(Self.srtText.utf8), fileName: "a.srt", group: "assrt-1")
        try setModified(stored.url, Date().addingTimeInterval(-100 * Self.day))
        try await store.markUsed(relativePath: stored.relativePath)

        let report = try await store.cleanUp(keeping: [])
        XCTAssertEqual(report.removedGroups, 0, "刚用过的不算过期")
    }

    // MARK: - 每集记录

    func testBindingPersistsAcrossInstancesAndPurgesByPrefix() async throws {
        let file = directory.appending(path: "bindings.json")
        let store = SubtitleBindingStore(fileURL: file)
        let binding = SubtitleBindingStore.Binding(
            relativePath: "assrt-1/a.srt", title: "a", assrtID: 1, lastUsed: Date())
        try await store.bind(binding, for: "emby|SERVER-A|item1")
        try await store.bind(binding, for: "baidu|fsid:42")

        let reopened = SubtitleBindingStore(fileURL: file)
        let restored = await reopened.binding(for: "emby|SERVER-A|item1")
        XCTAssertEqual(restored?.relativePath, "assrt-1/a.srt")
        XCTAssertEqual(restored?.assrtID, 1)
        let groups = await reopened.referencedGroups()
        XCTAssertEqual(groups, ["assrt-1"])

        let removed = try await reopened.purge(keyPrefix: "emby|SERVER-A|")
        XCTAssertEqual(removed, 1)
        let gone = await reopened.binding(for: "emby|SERVER-A|item1")
        XCTAssertNil(gone)
        let other = await reopened.binding(for: "baidu|fsid:42")
        XCTAssertNotNil(other, "别的来源的记录不受影响")
    }

    func testBindingPruneDropsStaleEntries() async throws {
        let store = SubtitleBindingStore(fileURL: directory.appending(path: "bindings.json"))
        let now = Date()
        try await store.bind(.init(relativePath: "assrt-1/a.srt", title: "a", assrtID: 1,
                                   lastUsed: now.addingTimeInterval(-100 * Self.day)), for: "old")
        try await store.bind(.init(relativePath: "assrt-2/b.srt", title: "b", assrtID: 2,
                                   lastUsed: now), for: "new")

        let removed = try await store.prune(now: now)
        XCTAssertEqual(removed, 1)
        let groups = await store.referencedGroups()
        XCTAssertEqual(groups, ["assrt-2"], "过期记录删掉后,它的文件就不再受保护")
    }

    func testCorruptBindingFileIsNotOverwritten() async throws {
        let file = directory.appending(path: "bindings.json")
        try Data("not json".utf8).write(to: file)
        let store = SubtitleBindingStore(fileURL: file)
        let missing = await store.binding(for: "x")
        XCTAssertNil(missing)
        do {
            try await store.bind(.init(relativePath: "assrt-1/a.srt", title: "a", assrtID: 1, lastUsed: Date()), for: "x")
            XCTFail("损坏的记录文件必须拒绝覆盖")
        } catch let error as SubtitleBindingStoreError {
            guard case .unreadable = error else { return XCTFail("错误类型不对:\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("not json".utf8), "原文件原样保留")
    }

    // MARK: - 先查缓存

    func testServiceHitsCacheWithoutAnyRequest() async throws {
        let store = SubtitleFileStore(directory: storeDirectory)
        _ = try await store.storeDownloaded(
            data: Data(Self.srtText.utf8), fileName: "一拳超人.zh-Hans.srt", group: SubtitleService.cacheGroup(assrtID: 7))
        // 故意不存 token:命中缓存时连凭据都不该读
        let credentials = CredentialStore(storage: CredentialFileStore(fileURL: .temporaryCredentialsFile()))
        let service = SubtitleService(
            credentials: credentials, store: store,
            client: AssrtClient(session: MockEmbyURLProtocol.makeSession()))

        let stored = try await service.download(assrtID: 7)

        XCTAssertEqual(stored.title, "一拳超人.zh-Hans", "缓存命中也显示原文件名")
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty, "命中缓存不请求 assrt")
    }

    // MARK: - 辅助

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        // 组的「最近使用」也看目录自己的修改时间:一起拨回去
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.deletingLastPathComponent().path)
    }
}
