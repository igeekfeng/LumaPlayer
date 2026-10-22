import Synchronization
import XCTest
@testable import LumaPlayer

/// 全部在临时目录里跑,⛔ 不碰真实用户文件夹。访问权用 `FakeBookmarks`:沙盒里对临时目录做安全作用域书签的行为与用户选的文件夹不同(见 `LocalFolderBookmarking`)。真实书签 + 外接盘 / 网络卷的行为未验证。
final class LocalFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appending(path: "local-folder-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "片库", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        root = nil
        try super.tearDownWithError()
    }

    private func touch(_ relative: String, bytes: Data = Data("x".utf8)) throws {
        let url = root.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    private func source(id: UUID = UUID()) -> LocalFolderSource {
        LocalFolderSource(
            id: id, displayName: "片库", bookmark: Data(root.path.utf8),
            lastKnownPath: root.path, rootName: LocalFolderSource.rootName(forFolderAt: root))
    }

    // MARK: - 列目录

    func testListingMapsChildrenToVirtualPathsAndSkipsHiddenFiles() throws {
        try touch("琅琊榜/01.mkv")
        try touch("电影.2019.mp4", bytes: Data(repeating: 0, count: 42))
        try touch(".DS_Store")
        let source = source()

        let files = try LocalFolderListing.files(inDirectory: "/片库", root: root, source: source)

        XCTAssertEqual(Set(files.map(\.name)), ["琅琊榜", "电影.2019.mp4"], "隐藏文件不列")
        let folder = try XCTUnwrap(files.first { $0.name == "琅琊榜" })
        XCTAssertTrue(folder.isDirectory)
        XCTAssertNil(folder.sizeBytes, "目录没有大小(与百度同一口径)")
        XCTAssertEqual(folder.path, "/片库/琅琊榜")
        let movie = try XCTUnwrap(files.first { $0.name == "电影.2019.mp4" })
        XCTAssertEqual(movie.sizeBytes, 42)
        XCTAssertEqual(movie.kind, .video, "没有服务端分类,按扩展名归类")
        XCTAssertNotNil(movie.modifiedAt)

        let inner = try LocalFolderListing.files(inDirectory: "/片库/琅琊榜", root: root, source: source)
        XCTAssertEqual(inner.map(\.path), ["/片库/琅琊榜/01.mkv"])
    }

    /// 续播库按 id 全局存,两个来源里同路径的文件撞 id 就会互相覆盖进度。
    func testFileIDIsStablePerSourceAndDistinctAcrossSources() throws {
        try touch("a.mkv")
        let first = source()
        let again = try LocalFolderListing.files(inDirectory: "/片库", root: root, source: first)
        let twice = try LocalFolderListing.files(inDirectory: "/片库", root: root, source: first)
        let other = try LocalFolderListing.files(inDirectory: "/片库", root: root, source: source())

        XCTAssertEqual(again.first?.fsID, twice.first?.fsID)
        XCTAssertNotEqual(again.first?.fsID, other.first?.fsID)
        XCTAssertEqual(
            LocalFolderListing.fileID(sourceID: first.id, path: "/片库/a.mkv"), again.first?.fsID)
    }

    func testListingMissingDirectoryThrowsUnreadable() {
        XCTAssertThrowsError(
            try LocalFolderListing.files(inDirectory: "/片库/不存在", root: root, source: source())
        ) { error in
            guard case .directoryUnreadable = error as? LocalFolderError else {
                return XCTFail("应是 directoryUnreadable,实际 \(error)")
            }
            XCTAssertFalse((error as? LocalFolderError)?.needsFolderReselection ?? true,
                           "某一层读不出来不该让人重选文件夹")
        }
    }

    func testFileURLRejectsPathsOutsideTheRoot() throws {
        let url = try LocalFolderListing.fileURL(forPath: "/片库/剧/01.mkv", root: root, rootPath: "/片库")
        XCTAssertEqual(url.standardizedFileURL.path, root.appending(path: "剧/01.mkv").standardizedFileURL.path)

        for bad in ["/别处/a.mkv", "/片库X/a.mkv", "/片库/../a.mkv", "/片库/剧/./01.mkv", ""] {
            XCTAssertThrowsError(
                try LocalFolderListing.fileURL(forPath: bad, root: root, rootPath: "/片库"), bad)
        }
    }

    func testRootNameFallsBackForVolumeRoot() {
        XCTAssertEqual(LocalFolderSource.rootName(forFolderAt: URL(filePath: "/")), "本地文件夹")
        XCTAssertEqual(LocalFolderSource.rootName(forFolderAt: URL(filePath: "/Volumes/片库")), "片库")
    }

    // MARK: - 合成(与百度共用合成器)

    /// 根上平铺剧集时剧名取根名(= 文件夹名),所以根名不能是常量。
    func testFlatEpisodesAtRootTakeTheFolderNameAsSeriesTitle() throws {
        try touch("01.mkv")
        try touch("02.mkv")
        let source = source()
        let files = try LocalFolderListing.files(inDirectory: source.rootPath, root: root, source: source)

        let items = BaiduPanMetadataSynthesizer.synthesize(files: files, sourceID: source.id).map(\.item)

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.kind == .episode && $0.title == "片库" })
    }

    // MARK: - Matroska 时长

    func testMatroskaDurationWithDoubleAndDefaultScale() {
        let bytes = Matroska.file(info: [
            Matroska.element([0x44, 0x89], Matroska.double(1_234_567)),
        ])
        XCTAssertEqual(LocalMediaDuration.matroskaDuration(in: bytes) ?? 0, 1234.567, accuracy: 0.001)
    }

    func testMatroskaDurationHonoursTimestampScaleAndFloat32() {
        // 刻度 1 秒(1e9 ns)、时长 float32 90 → 90 秒
        let bytes = Matroska.file(info: [
            Matroska.element([0x2A, 0xD7, 0xB1], [0x3B, 0x9A, 0xCA, 0x00]),
            Matroska.element([0x44, 0x89], Matroska.float(90)),
        ])
        XCTAssertEqual(LocalMediaDuration.matroskaDuration(in: bytes) ?? 0, 90, accuracy: 0.001)
    }

    func testMatroskaDurationGivesUpWhenClusterComesFirstOrDataIsTruncated() {
        let clusterFirst = Matroska.file(info: nil, beforeInfo: [
            Matroska.element([0x1F, 0x43, 0xB6, 0x75], [0x00]),
        ])
        XCTAssertNil(LocalMediaDuration.matroskaDuration(in: clusterFirst))

        let full = Matroska.file(info: [Matroska.element([0x44, 0x89], Matroska.double(5000))])
        XCTAssertNil(LocalMediaDuration.matroskaDuration(in: full.prefix(full.count - 3)))
        XCTAssertNil(LocalMediaDuration.matroskaDuration(in: Data("not a matroska".utf8)))
    }

    func testDurationOfUnsupportedContainerIsNil() async throws {
        try touch("a.avi")
        let seconds = await LocalMediaDuration.seconds(of: root.appending(path: "a.avi"))
        XCTAssertNil(seconds, "读不出来就是 nil,⛔ 不估算")
    }

    func testDurationCacheReadsEachFileOnce() async throws {
        let bytes = Matroska.file(info: [Matroska.element([0x44, 0x89], Matroska.double(60_000))])
        try touch("a.mkv", bytes: bytes)
        let source = source()
        let file = try XCTUnwrap(
            LocalFolderListing.files(inDirectory: "/片库", root: root, source: source).first)
        let url = root.appending(path: "a.mkv")
        let cache = LocalMediaDurationCache()

        let first = await cache.durations(for: [(file, url)])
        XCTAssertEqual(first[file.fsID] ?? 0, 60, accuracy: 0.001)

        // 删掉文件后仍命中(键带修改时间与大小,文件没换就不重读)
        try FileManager.default.removeItem(at: url)
        let second = await cache.durations(for: [(file, url)])
        XCTAssertEqual(second[file.fsID] ?? 0, 60, accuracy: 0.001)
    }

    // MARK: - 访问权

    func testAccessOpensOnceAndReusesTheRoot() async throws {
        let bookmarks = FakeBookmarks()
        let access = LocalFolderAccess(bookmarks: bookmarks)
        let source = source()

        let first = try await access.rootURL(for: source)
        let second = try await access.rootURL(for: source)

        XCTAssertEqual(first.url.path, root.path)
        XCTAssertEqual(second.url, first.url)
        XCTAssertNil(first.refreshedBookmark)
        XCTAssertEqual(bookmarks.counts.started, 1, "一个来源只开一次访问权")

        await access.close(sourceID: source.id)
        XCTAssertEqual(bookmarks.counts.stopped, 1)
    }

    func testStaleBookmarkComesBackRefreshed() async throws {
        let access = LocalFolderAccess(bookmarks: FakeBookmarks(reportsStale: true))
        let resolution = try await access.rootURL(for: source())
        XCTAssertEqual(resolution.refreshedBookmark, Data(root.path.utf8))
    }

    func testMissingFolderAndDeniedAccessAskForReselection() async throws {
        let gone = LocalFolderSource(
            displayName: "x", bookmark: Data("/不存在/的目录".utf8),
            lastKnownPath: "/不存在/的目录", rootName: "目录")
        do {
            _ = try await LocalFolderAccess(bookmarks: FakeBookmarks()).rootURL(for: gone)
            XCTFail("目录不在应抛错")
        } catch let error as LocalFolderError {
            XCTAssertTrue(error.needsFolderReselection)
        }

        do {
            _ = try await LocalFolderAccess(bookmarks: FakeBookmarks(grantsAccess: false))
                .rootURL(for: source())
            XCTFail("不给访问权应抛错")
        } catch let error as LocalFolderError {
            guard case .accessDenied = error else { return XCTFail("应是 accessDenied,实际 \(error)") }
            XCTAssertTrue(error.needsFolderReselection)
        }
    }

    // MARK: - 播放会话

    func testPlannerGivesAFileDirectStreamWithClientSeek() throws {
        let file = BaiduPanFile(
            fsID: 7, path: "/片库/a.mkv", name: "a.mkv", sizeBytes: 10, isDirectory: false,
            category: nil, modifiedAt: nil, thumbnailURL: nil)
        let url = root.appending(path: "a.mkv")

        let session = try LocalFilePlaybackPlanner.session(file: file, url: url, playSessionID: "S")

        XCTAssertEqual(session.plan.method, .directStream)
        XCTAssertEqual(session.plan.url, url)
        XCTAssertTrue(session.plan.headers.isEmpty)
        XCTAssertEqual(session.seekStrategy, .clientSeek)
        XCTAssertEqual(session.mediaSource.container, "mkv")
        XCTAssertEqual(session.mediaSource.size, 10)
    }

    func testPreparerResolvesTheFileAndItsSubtitles() async throws {
        try touch("剧/01.mkv")
        try touch("剧/01.chs.srt")
        let source = source()
        let files = try LocalFolderListing.files(inDirectory: "/片库/剧", root: root, source: source)
        let video = try XCTUnwrap(files.first { $0.name == "01.mkv" })
        let subtitle = try XCTUnwrap(files.first { $0.name == "01.chs.srt" })
        let root = self.root!
        let preparer = LocalFileSessionPreparer(
            file: video, source: source, subtitleFiles: [subtitle], resolveRoot: { root })

        let session = try await preparer.makeSession(startTimeTicks: nil)

        XCTAssertEqual(session.plan.url.standardizedFileURL.path,
                       root.appending(path: "剧/01.mkv").standardizedFileURL.path)
        XCTAssertEqual(session.externalSubtitles.count, 1)
        XCTAssertTrue(session.externalSubtitles.first?.url.isFileURL ?? false)
    }

    func testPreparerReportsAMissingFile() async throws {
        let source = source()
        let missing = BaiduPanFile(
            fsID: 1, path: "/片库/没了.mkv", name: "没了.mkv", sizeBytes: nil, isDirectory: false,
            category: nil, modifiedAt: nil, thumbnailURL: nil)
        let root = self.root!
        let preparer = LocalFileSessionPreparer(file: missing, source: source, resolveRoot: { root })
        do {
            _ = try await preparer.makeSession(startTimeTicks: nil)
            XCTFail("文件不在应抛错")
        } catch let error as LocalFolderError {
            XCTAssertEqual(error, .fileMissing(name: "没了.mkv"))
        }
    }

    // MARK: - 范围键 / 快照 / 持久化

    /// 本地键带来源 id(两个来源里同名目录不是同一部);百度的键形状不能变,已有的弹幕 / 字幕绑定都记在那个形状下。
    func testScopeKeysIsolateLocalSourcesAndKeepBaiduKeysUnchanged() {
        let file = BaiduPanFile(
            fsID: 9, path: "/片库/剧/剧.S01E02.mkv", name: "剧.S01E02.mkv", sizeBytes: nil,
            isDirectory: false, category: nil, modifiedAt: nil, thumbnailURL: nil)
        let a = source()
        let b = source()

        let localA = DanmakuMediaQuery.make(for: .localFolder(file: file, source: a))
        let localB = DanmakuMediaQuery.make(for: .localFolder(file: file, source: b))
        let baidu = DanmakuMediaQuery.make(for: .baiduPan(file: file))
        XCTAssertEqual(localA.itemKey, "local|\(a.id.uuidString)|fsid:9")
        XCTAssertEqual(localA.seriesKey, "local|\(a.id.uuidString)|dir:/片库/剧")
        XCTAssertNotEqual(localA.itemKey, localB.itemKey)
        XCTAssertEqual(baidu.itemKey, "baidu|fsid:9")
        XCTAssertEqual(baidu.seriesKey, "baidu|dir:/片库/剧")
        XCTAssertEqual(localA.episodeNumber, baidu.episodeNumber)

        XCTAssertNotEqual(
            ManualMarkersScope.key(for: .localFolder(file: file, source: a)),
            ManualMarkersScope.key(for: .localFolder(file: file, source: b)))
        XCTAssertNotEqual(
            PlaybackSpeedScope.localFolder(sourceID: a.id, file: file, isEpisodeSeries: true),
            PlaybackSpeedScope.localFolder(sourceID: b.id, file: file, isEpisodeSeries: true))
    }

    func testLocalCoverSnapshotRoundTripsAsLocalFile() throws {
        let url = root.appending(path: "poster.jpg")
        let descriptor = ImageDescriptor.localFile(
            ownerID: UUID(), url: url,
            cacheKey: ImageDescriptor.localCoverKey(
                sourceID: UUID(), fileID: 3, modifiedAt: nil, maxWidth: 400))

        let snapshot = try XCTUnwrap(descriptor.snapshot)
        let restored = ImageDescriptor(snapshot: snapshot)

        XCTAssertEqual(restored, descriptor)
        XCTAssertFalse(descriptor.hasExpiringURL, "本机路径不会过期,刮削缓存可以存")
    }

    func testLocalFolderProfileSurvivesCodableRoundTrip() throws {
        let profile = SourceProfile.localFolder(source())
        let decoded = try JSONDecoder().decode(
            SourceProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.kindDescription, "本地文件夹")
        XCTAssertEqual(decoded.fileSource?.supportsDeletingFiles, false)
    }
}

// MARK: - 替身

/// 书签就是路径的 UTF-8,解析即还原;记下开 / 关访问权的次数。
final class FakeBookmarks: LocalFolderBookmarking {
    struct Counts { var started = 0; var stopped = 0 }

    private let reportsStale: Bool
    private let grantsAccess: Bool
    private let state = Mutex(Counts())

    init(reportsStale: Bool = false, grantsAccess: Bool = true) {
        self.reportsStale = reportsStale
        self.grantsAccess = grantsAccess
    }

    var counts: Counts { state.withLock { $0 } }

    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        (URL(filePath: String(decoding: bookmark, as: UTF8.self), directoryHint: .isDirectory),
         reportsStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        state.withLock { $0.started += 1 }
        return grantsAccess
    }

    func stopAccessing(_ url: URL) {
        state.withLock { $0.stopped += 1 }
    }

    func isReachableDirectory(_ url: URL) -> Bool {
        SecurityScopedBookmarks().isReachableDirectory(url)
    }
}

/// 拼一份最小的 Matroska 头(EBML 头 → Segment(长度未知)→ [前置元素] → Info)。
private enum Matroska {
    static func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        // 长度统一用 8 字节 vint:0x01 + 7 字节大端
        let size = UInt64(payload.count)
        let sizeBytes = [UInt8(0x01)] + (0..<7).reversed().map { UInt8((size >> (8 * UInt64($0))) & 0xFF) }
        return id + sizeBytes + payload
    }

    static func double(_ value: Double) -> [UInt8] {
        let bits = value.bitPattern
        return (0..<8).reversed().map { UInt8((bits >> (8 * UInt64($0))) & 0xFF) }
    }

    static func float(_ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return (0..<4).reversed().map { UInt8((bits >> (8 * UInt32($0))) & 0xFF) }
    }

    static func file(info: [[UInt8]]?, beforeInfo: [[UInt8]] = []) -> Data {
        let header = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("matroska".utf8)))
        // SeekHead / Void 一类的前置元素:解析器得会跳过
        let seekHead = element([0x11, 0x4D, 0x9B, 0x74], [0x00, 0x01, 0x02])
        let void = element([0xEC], [0x00, 0x00])
        var body = seekHead + void + beforeInfo.flatMap { $0 }
        if let info {
            body += element([0x15, 0x49, 0xA9, 0x66], info.flatMap { $0 })
        }
        let unknownSize: [UInt8] = [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        return Data(header + [0x18, 0x53, 0x80, 0x67] + unknownSize + body)
    }
}
