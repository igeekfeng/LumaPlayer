import XCTest
@testable import LumaPlayer

/// 弹幕本地数据清理:磁盘缓存按 `fetchedAt` 过期删除(`DanmakuCommentCache.cleanUp`)、
/// 删服务器时按前缀删绑定(`DanmakuBindingStore.purge`、`AppContainer.removeSource`)。
@MainActor
final class DanmakuCacheTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var temporaryURLs: [URL] = []

    override func tearDown() async throws {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        temporaryURLs = []
        try await super.tearDown()
    }

    private func temporaryURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "LumaPlayerTests-\(name)-\(UUID().uuidString)", directoryHint: .notDirectory)
        temporaryURLs.append(url)
        return url
    }

    private func cache(_ directory: URL, at date: Date) -> DanmakuCommentCache {
        DanmakuCommentCache(directory: directory, now: { date })
    }

    private let sample = [DanmakuComment(id: 1, time: 1, mode: .scroll, color: 0xFFFFFF, text: "hi")]

    /// 与缓存文件同形的条目,用来写出「版本不对」的文件
    private struct RawEntry: Encodable {
        let version: Int
        let fetchedAt: Date
        let comments: [DanmakuComment]
    }

    private func fileSize(_ url: URL) throws -> Int {
        try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    // MARK: - 缓存清理

    func testCleanUpRemovesExpiredCorruptAndWrongVersionFilesOnly() async throws {
        let directory = temporaryURL("danmaku-cache")
        let cleanupTime = start.addingTimeInterval(DanmakuCommentCache.freshness + 3600)
        // 1:有效期外;2:刚好满有效期(读取已当作没有,清理也删);3:有效期内
        await cache(directory, at: start).store(sample, forEpisode: 1)
        await cache(directory, at: cleanupTime.addingTimeInterval(-DanmakuCommentCache.freshness))
            .store(sample, forEpisode: 2)
        await cache(directory, at: cleanupTime.addingTimeInterval(-60)).store(sample, forEpisode: 3)
        // 4:损坏;5:版本不对(时间是新的)
        let corrupt = directory.appending(path: "4.json")
        try Data("not json".utf8).write(to: corrupt)
        let wrongVersion = directory.appending(path: "5.json")
        try JSONEncoder().encode(RawEntry(version: 99, fetchedAt: cleanupTime, comments: sample))
            .write(to: wrongVersion)
        // 子目录不归清理管
        let subdirectory = directory.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let removedNames = ["1.json", "2.json", "4.json", "5.json"]
        let expectedBytes = try removedNames.reduce(0) { $0 + (try fileSize(directory.appending(path: $1))) }

        let store = cache(directory, at: cleanupTime)
        let report = try await store.cleanUp()

        XCTAssertEqual(report.removedFiles, 4)
        XCTAssertEqual(report.removedBytes, expectedBytes)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        XCTAssertEqual(Set(remaining), ["3.json", "nested"])
        let kept = await store.comments(forEpisode: 3)
        XCTAssertEqual(kept, sample, "留下的文件读取时应仍然有效")
    }

    func testCleanUpOnMissingDirectoryIsNoOp() async throws {
        let report = try await cache(temporaryURL("danmaku-missing"), at: start).cleanUp()
        XCTAssertEqual(report, DanmakuCommentCache.CleanupReport())
    }

    // MARK: - 绑定清理

    private func binding(_ episodeID: Int64) -> DanmakuBindingStore.EpisodeBinding {
        .init(episodeID: episodeID, animeID: episodeID * 10, animeTitle: nil, episodeTitle: nil, shift: nil)
    }

    func testBindingPurgeRemovesEpisodesAndSeriesOfThatServerOnly() async throws {
        let fileURL = temporaryURL("danmaku-bindings")
        let store = DanmakuBindingStore(fileURL: fileURL)
        try await store.bind(binding(1), itemKey: "emby|SERVER-A|1", seriesKey: "emby|SERVER-A|series:9")
        try await store.bind(binding(2), itemKey: "emby|SERVER-A|2", seriesKey: nil)
        try await store.bind(binding(3), itemKey: "emby|SERVER-AB|1", seriesKey: "emby|SERVER-AB|series:9")
        try await store.bind(binding(4), itemKey: "baidu|fsid:1", seriesKey: "baidu|dir:/x")

        let removed = try await store.purge(keyPrefix: "emby|SERVER-A|")
        XCTAssertEqual(removed, 3)

        // 换实例读盘:确认落了盘
        let reopened = DanmakuBindingStore(fileURL: fileURL)
        let a1 = await reopened.episode(for: "emby|SERVER-A|1")
        let a2 = await reopened.episode(for: "emby|SERVER-A|2")
        let aSeries = await reopened.series(for: "emby|SERVER-A|series:9")
        let ab1 = await reopened.episode(for: "emby|SERVER-AB|1")
        let abSeries = await reopened.series(for: "emby|SERVER-AB|series:9")
        let baidu = await reopened.episode(for: "baidu|fsid:1")
        let baiduSeries = await reopened.series(for: "baidu|dir:/x")
        XCTAssertNil(a1)
        XCTAssertNil(a2)
        XCTAssertNil(aSeries)
        XCTAssertEqual(ab1, binding(3), "前缀带结尾的 | ,id 相互包含的服务器不受影响")
        XCTAssertEqual(abSeries?.animeID, 30)
        XCTAssertEqual(baidu, binding(4))
        XCTAssertEqual(baiduSeries?.animeID, 40)

        let again = try await reopened.purge(keyPrefix: "emby|SERVER-A|")
        XCTAssertEqual(again, 0)
    }

    /// 按 `emby|<id>|` 前缀清,别的服务器不动。
    func testRemovingServerPurgesItsDanmakuBindings() async throws {
        let credentials = CredentialStore(storage: CredentialFileStore(fileURL: temporaryURL("cred")))
        let registry = try ServerRegistry(
            defaults: UserDefaults(suiteName: "test.LumaPlayer.danmakuCache.\(UUID().uuidString)")!,
            credentials: credentials)
        let bindings = DanmakuBindingStore(fileURL: temporaryURL("danmaku-bindings"))
        let container = AppContainer(
            registry: registry,
            credentials: credentials,
            preferences: UserDefaults(suiteName: "test.LumaPlayer.danmakuCache.prefs.\(UUID().uuidString)")!,
            danmaku: DanmakuService(
                credentials: credentials, bindings: bindings,
                cache: DanmakuCommentCache(directory: temporaryURL("danmaku-cache"))),
            subtitleBindings: SubtitleBindingStore(fileURL: temporaryURL("subtitle-bindings")))
        let removedServer = ServerProfile(
            displayName: "alpha", baseURL: testURL("https://alpha.test"), deviceID: "DEVICE-UUID-1")
        let keptServer = ServerProfile(
            displayName: "beta", baseURL: testURL("https://beta.test"), deviceID: "DEVICE-UUID-1")
        try await registry.add(removedServer)
        try await registry.add(keptServer)
        let removedKey = "emby|\(removedServer.id.uuidString)|"
        let keptKey = "emby|\(keptServer.id.uuidString)|"
        try await bindings.bind(binding(1), itemKey: removedKey + "1", seriesKey: removedKey + "series:9")
        try await bindings.bind(binding(2), itemKey: keptKey + "1", seriesKey: keptKey + "series:9")

        try await container.removeServer(id: removedServer.id)

        let gone = await bindings.episode(for: removedKey + "1")
        let goneSeries = await bindings.series(for: removedKey + "series:9")
        let kept = await bindings.episode(for: keptKey + "1")
        let keptSeries = await bindings.series(for: keptKey + "series:9")
        XCTAssertNil(gone)
        XCTAssertNil(goneSeries)
        XCTAssertEqual(kept, binding(2))
        XCTAssertEqual(keptSeries?.animeID, 20)
    }
}
