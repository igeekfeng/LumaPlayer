import XCTest
@testable import LumaPlayer

/// 百度来源在组合根上的生命周期:添加 / 落库 / 切换 / 删除 / 起播位置。
///
/// 覆盖的是**不发网络请求**的那条路 —— `addBaiduSource` 的配置保存只写凭据文件,
/// 不探活(与 Emby 的 `addServer` 不同:那条要探测 + 登录)。真实授权与列表
/// 需要真网盘账号,按 `docs/SOURCE_ABSTRACTION_PLAN.md` §7 标注「未验证」。
@MainActor
final class BaiduPanSourceLifecycleTests: XCTestCase {
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var progressURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        progressURL = FileManager.default.temporaryDirectory
            .appending(path: "lifecycle-progress-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        if let progressURL { try? FileManager.default.removeItem(at: progressURL) }
        storage = nil
        credentials = nil
        progressURL = nil
        try await super.tearDown()
    }

    private func makeContainer() throws -> AppContainer {
        AppContainer(
            registry: try ServerRegistry(
                defaults: UserDefaults(suiteName: "test.LumaPlayer.source.\(UUID().uuidString)")!,
                credentials: credentials
            ),
            credentials: credentials,
            preferences: UserDefaults(suiteName: "test.LumaPlayer.source.prefs.\(UUID().uuidString)")!,
            watchProgress: WatchProgressStore(fileURL: progressURL)
        )
    }

    // MARK: - 添加

    func testAddingBaiduSourceRegistersAndSwitches() async throws {
        let container = try makeContainer()
        let initiallyEmpty = await container.sources().isEmpty
        XCTAssertTrue(initiallyEmpty)

        let source = try await container.addBaiduSource(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        let sources = await container.sources()
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.baiduPanSource?.folderName, "LumaPlayer")
        XCTAssertEqual(sources.first?.id, source.id)
        // 落库即设为当前来源并进浏览(与添加 Emby 服务器同一条纪律)
        XCTAssertEqual(container.state.currentSource?.id, source.id)
        XCTAssertNil(container.state.currentServer, "百度来源不该写 currentServer")
        XCTAssertEqual(container.state.route, .browse)
    }

    /// 一个 App 只对应开放平台上一份授权:再添加一次是**更新**,不是插第二条。
    func testAddingBaiduSourceTwiceUpdatesInsteadOfDuplicating() async throws {
        let container = try makeContainer()
        let first = try await container.addBaiduSource(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        let second = try await container.addBaiduSource(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer2")

        XCTAssertEqual(first.id, second.id)
        let sources = await container.sources()
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.baiduPanSource?.folderName, "LumaPlayer2")
    }

    // MARK: - 切换 / 删除

    func testSwitchingMarksUsed() async throws {
        let container = try makeContainer()
        let baidu = try await container.addBaiduSource(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        container.state.currentSource = nil

        try await container.switchCurrent(to: .baiduPan(baidu))

        XCTAssertEqual(container.state.currentSource?.id, baidu.id)
        let marked = await container.registry.mostRecentlyUsedSource()?.id
        XCTAssertEqual(marked, baidu.id)
        XCTAssertNotNil(container.state.currentSource?.lastUsedAt)
    }

    /// 删除百度来源要连授权与密钥一起清 —— 留着就是孤儿凭据。
    func testRemovingBaiduSourceClearsItsCredentials() async throws {
        let container = try makeContainer()
        let baidu = try await container.addBaiduSource(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        try await credentials.saveBaiduPanToken(
            BaiduPanTokenBundle(
                accessToken: "AT", refreshToken: "RT",
                expiresAt: Date(), scope: nil))

        try await container.removeSource(id: baidu.id)

        let remaining = await container.sources()
        XCTAssertTrue(remaining.isEmpty)
        let token = try await credentials.baiduPanToken()
        let configuration = try await credentials.baiduPanAppConfiguration()
        XCTAssertNil(token, "授权要一起清")
        XCTAssertNil(configuration, "密钥要一起清")
        // 一个来源都不剩 → 回引导页
        XCTAssertEqual(container.state.route, .onboarding)
    }

    // MARK: - 起播位置

    /// 百度来源的起播位置读本地续播库(Emby 读服务端响应),由组合根按来源给。
    func testResumeSecondsComesFromLocalStoreForBaidu() async throws {
        let container = try makeContainer()
        let file = makeFile()
        try await container.watchProgress.record(
            fileID: "42", positionSeconds: 300, durationSeconds: 600)

        let saved = await container.resumeSeconds(
            for: PlaybackRequest(baiduFile: file), fromBeginning: false)
        let ignored = await container.resumeSeconds(
            for: PlaybackRequest(baiduFile: file), fromBeginning: true)

        XCTAssertEqual(saved, 300)
        XCTAssertEqual(ignored, 0, "「从头播放」必须忽略续播位置")
    }

    // MARK: - 目录排序

    /// 默认**剧集顺序** —— 「看剧都是从前往后看的」。
    /// 换排序方式回到该档的自然方向(与 `LibraryViewModel` 同一条纪律)。
    func testDirectorySortDefaultsToEpisodeOrder() async throws {
        let container = try makeContainer()
        let source = try await container.addBaiduSource(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        let viewModel = BaiduPanSourceViewModel(container: container, source: source)

        XCTAssertEqual(viewModel.sort, .episode)
        XCTAssertTrue(viewModel.ascending)

        // 时间档的自然方向是「新的在前」
        viewModel.sort = .modifiedDate
        XCTAssertFalse(viewModel.ascending)

        // 手动翻过方向之后换档,仍回到该档的自然方向
        viewModel.ascending = true
        viewModel.sort = .name
        XCTAssertTrue(viewModel.ascending)
    }

    // MARK: - 续播卡片(「继续观看」区)

    /// 起播时记下展示快照,「继续观看」区才渲染得出来(标题 / 定位 / 封面),
    /// 且**不能抹掉**上报器已经写进去的进度。
    func testRememberResumeCardPersistsDisplayWithoutLosingProgress() async throws {
        let container = try makeContainer()
        let sourceID = UUID()
        try await container.watchProgress.record(
            fileID: "42", positionSeconds: 300, durationSeconds: 600)

        await container.rememberResumeCard(item: makeItem(sourceID: sourceID), file: makeFile())

        let records = await container.watchProgress.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.positionSeconds, 300, "记展示不能抹掉已有进度")
        XCTAssertEqual(records.first?.display.title, "示例电影")
        XCTAssertEqual(records.first?.display.locator, "/apps/LumaPlayer/a.mp4")
        XCTAssertNotNil(records.first?.display.cover, "封面要随卡片一起记下来")

        // 折成 UI 卡片:能从快照重建一个够播放用的文件
        let card = try XCTUnwrap(records.compactMap(BaiduResumeCard.init(record:)).first)
        XCTAssertEqual(card.title, "示例电影")
        XCTAssertEqual(card.reconstructedFile?.fsID, 42)
        XCTAssertEqual(card.reconstructedFile?.path, "/apps/LumaPlayer/a.mp4")
    }

    /// 键不是合法 `fs_id` 的记录不端成卡片 —— 点了也播不了。
    func testResumeCardRejectsNonNumericFileID() {
        let record = WatchProgressStore.ResumeRecord(
            fileID: "not-a-number",
            positionSeconds: 10,
            durationSeconds: nil,
            updatedAt: Date(),
            display: WatchProgressStore.Display(
                sourceID: UUID(), title: "x", locator: "/x", fileName: "x.mp4", cover: nil)
        )
        XCTAssertNil(BaiduResumeCard(record: record))
    }

    private func makeItem(sourceID: UUID) -> SourceItem {
        SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: 42),
            title: "示例电影",
            kind: .video,
            overview: nil,
            year: 2021,
            tmdbID: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            episodeTitle: nil,
            durationSeconds: nil,
            poster: .remote(
                ownerID: sourceID,
                url: URL(string: "https://d.pcs.baidu.com/file/abc?access_token=T")!,
                headers: ["User-Agent": "netdisk"],
                cacheKey: "baidu|\(sourceID.uuidString)|7|1700000000|cover|400"
            ),
            metadataOrigin: .filename
        )
    }

    private func makeFile() -> BaiduPanFile {
        BaiduPanFile(
            fsID: 42,
            path: "/apps/LumaPlayer/a.mp4",
            name: "a.mp4",
            sizeBytes: 1024,
            isDirectory: false,
            category: nil,
            modifiedAt: nil,
            thumbnailURL: nil
        )
    }
}
