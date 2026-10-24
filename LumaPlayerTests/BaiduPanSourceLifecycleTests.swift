import XCTest
@testable import LumaPlayer

/// 百度来源在组合根上的生命周期:添加 / 落库 / 切换 / 删除 / 起播位置。
/// 只覆盖不发网络的路径:`addBaiduSource` 只写凭据文件、不探活(Emby 的 `addServer` 要探测 + 登录)。
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
        XCTAssertEqual(container.state.currentSource?.id, source.id)
        XCTAssertNil(container.state.currentServer, "百度来源不该写 currentServer")
        XCTAssertEqual(container.state.route, .browse)
    }

    /// 授权是应用级的(一份 token),多个来源共用,各自记显示名与片库根。
    func testAddingBaiduSourceTwiceCreatesTwoSources() async throws {
        let container = try makeContainer()
        let first = try await container.addBaiduSource(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        let second = try await container.addBaiduSource(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        XCTAssertNotEqual(first.id, second.id)
        let sources = await container.sources()
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(container.state.currentSource?.id, second.id)
    }

    func testLibraryRootIsScopedPerBaiduSource() async throws {
        let container = try makeContainer()
        let first = try await container.addBaiduSource(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")
        let second = try await container.addBaiduSource(
            appKey: "KEY", secretKey: "SECRET", folderName: "LumaPlayer")

        try await container.setLibraryRoot("/apps/LumaPlayer/电影", for: first)

        let forFirst = try await container.libraryRoot(for: first)
        let forSecond = try await container.libraryRoot(for: second)
        XCTAssertEqual(forFirst?.path, "/apps/LumaPlayer/电影")
        XCTAssertNil(forSecond, "另一个来源不该看到这份片库根")
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

    /// 删来源要连授权与密钥一起清,否则成孤儿凭据。
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
        XCTAssertEqual(container.state.route, .onboarding)
    }

    // MARK: - 起播位置

    /// 百度来源的起播位置读本地续播库(Emby 读服务端响应)。
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

    // MARK: - 续播卡片(「继续观看」区)

    /// 起播时记展示快照(标题 / 定位 / 封面),且 ⛔ 不能抹掉上报器已写入的进度。
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

        let card = try XCTUnwrap(records.compactMap(FileSourceResumeCard.init(record:)).first)
        XCTAssertEqual(card.title, "示例电影")
        XCTAssertEqual(card.reconstructedFile?.fsID, 42)
        XCTAssertEqual(card.reconstructedFile?.path, "/apps/LumaPlayer/a.mp4")
    }

    /// 键不是合法 `fs_id` 的记录点了也播不了,不端成卡片。
    func testResumeCardRejectsNonNumericFileID() {
        let record = WatchProgressStore.ResumeRecord(
            fileID: "not-a-number",
            positionSeconds: 10,
            durationSeconds: nil,
            updatedAt: Date(),
            display: WatchProgressStore.Display(
                sourceID: UUID(), title: "x", locator: "/x", fileName: "x.mp4", cover: nil)
        )
        XCTAssertNil(FileSourceResumeCard(record: record))
    }

    /// 看第 1 集一半又看第 2 集一半,退出后只该有一张卡。
    func testOneCardPerSeriesKeepsMostRecentEpisode() throws {
        let records = [
            makeRecord(fileID: "1", title: "琅琊榜", episode: 2, at: Date(timeIntervalSinceNow: 0)),
            makeRecord(fileID: "2", title: "琅琊榜", episode: 1, at: Date(timeIntervalSinceNow: -60)),
            makeRecord(fileID: "3", title: "别的电影", episode: nil, at: Date(timeIntervalSinceNow: -30))
        ]

        let collapsed = FileSourceViewModel.oneCardPerSeries(records)
        XCTAssertEqual(collapsed.map(\.fileID), ["1", "3"], "同剧同目录只留一张,取最近看的那一集")
        let card = try XCTUnwrap(FileSourceResumeCard(record: collapsed[0]))
        XCTAssertEqual(card.subtitle, "第 2 集 · 已看到 10:00")
    }

    /// 同名但不同目录是两部内容(重拍 / 同名电影),不能并。
    func testOneCardPerSeriesKeepsSameTitlesInDifferentDirectoriesApart() throws {
        let records = [
            makeRecord(fileID: "1", title: "同名", locator: "/apps/LumaPlayer/A/01.mp4"),
            makeRecord(fileID: "2", title: "同名", locator: "/apps/LumaPlayer/B/01.mp4")
        ]

        XCTAssertEqual(FileSourceViewModel.oneCardPerSeries(records).count, 2)
    }

    /// 季文件夹里各季文件名解析出的剧名常不一致(`Show.S01E01` / `Show.Name.S02E01`),按剧目录并成一张。
    func testOneCardPerSeriesMergesSeasonFolders() {
        let records = [
            makeRecord(fileID: "2", title: "Show Name",
                       locator: "/apps/LumaPlayer/Show/Season 2/Show.Name.S02E01.mkv",
                       episode: 1, at: Date(timeIntervalSinceNow: 0)),
            makeRecord(fileID: "1", title: "Show", locator: "/apps/LumaPlayer/Show/Season 1/Show.S01E05.mkv",
                       episode: 5, at: Date(timeIntervalSinceNow: -60))
        ]

        XCTAssertEqual(FileSourceViewModel.oneCardPerSeries(records).map(\.fileID), ["2"])
    }

    /// 倒回去重看第 1 集时,卡片指向第 1 集,而不是更晚写入的「下一集」占位。
    func testOneCardPerSeriesPrefersProgressOverUpNextPlaceholder() throws {
        let records = [
            makeRecord(fileID: "2", title: "琅琊榜", locator: "/apps/LumaPlayer/琅琊榜/02.mp4",
                       episode: 2, upNext: true, at: Date(timeIntervalSinceNow: 0)),
            makeRecord(fileID: "1", title: "琅琊榜", locator: "/apps/LumaPlayer/琅琊榜/01.mp4",
                       episode: 1, position: 600, at: Date(timeIntervalSinceNow: -30))
        ]

        let collapsed = FileSourceViewModel.oneCardPerSeries(records)

        XCTAssertEqual(collapsed.map(\.fileID), ["1"], "看到一半的那一集才是该续播的")
        let card = try XCTUnwrap(FileSourceResumeCard(record: collapsed[0]))
        XCTAssertEqual(card.subtitle, "第 1 集 · 已看到 10:00")
    }

    func testUpNextCardSubtitle() throws {
        let record = makeRecord(fileID: "2", title: "琅琊榜", episode: 2, upNext: true)
        let card = try XCTUnwrap(FileSourceResumeCard(record: record))
        XCTAssertEqual(card.subtitle, "第 2 集 · 下一集")
        XCTAssertTrue(card.isUpNext)
    }

    private func makeRecord(
        fileID: String,
        title: String,
        locator: String = "/apps/LumaPlayer/琅琊榜/01.mp4",
        episode: Int? = nil,
        position: Double = 600,
        upNext: Bool = false,
        at updatedAt: Date = Date()
    ) -> WatchProgressStore.ResumeRecord {
        WatchProgressStore.ResumeRecord(
            fileID: fileID,
            positionSeconds: upNext ? 0 : position,
            durationSeconds: 2400,
            updatedAt: updatedAt,
            display: WatchProgressStore.Display(
                sourceID: UUID(),
                title: title,
                locator: locator,
                fileName: (locator as NSString).lastPathComponent,
                cover: nil,
                episodeNumber: episode
            ),
            isUpNext: upNext
        )
    }

    // MARK: - 播放页换集(剧集队列)

    /// 队列复用当前目录已列的条目,⛔ 不为换集再列网盘(未审核应用配额 10 次/小时)。
    func testEpisodeQueueReusesListedSiblings() throws {
        let sourceID = UUID()
        let items = (1...3).map { makeEpisodeItem(sourceID: sourceID, index: $0) }
        let files = makeFiles(for: items)

        let queue = try XCTUnwrap(FileSourceViewModel.episodeQueue(
            selecting: items[1], in: items, filesByID: files, source: .baiduPan(BaiduPanSource(folderName: "LumaPlayer"))))

        XCTAssertEqual(queue.episodes.map(\.id), ["10", "20", "30"])
        XCTAssertEqual(queue.current?.id, "20")
        XCTAssertEqual(queue.previous?.id, "10")
        XCTAssertEqual(queue.next?.id, "30")
        XCTAssertEqual(queue.current?.label, "第 2 集")
        XCTAssertEqual(queue.current?.title, "示例剧", "没有集名时退回剧名(与浏览页卡片同一口径)")
        XCTAssertNotNil(
            queue.current?.resumeItem,
            "百度条目要带上展示快照的来源 —— 换集时靠它补记「继续观看」,⛔ 不回头列网盘")
    }

    /// 单条视频 / 电影不给队列:合成器只在「这一层像剧集序列」时才给 `.episode`。
    func testEpisodeQueueIsNilForNonEpisode() {
        let sourceID = UUID()
        let movie = SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: 7),
            title: "示例电影", kind: .video, overview: nil, year: nil, tmdbID: nil,
            episodeNumber: nil, seasonNumber: nil, episodeTitle: nil,
            durationSeconds: nil, poster: nil, metadataOrigin: .filename)
        let files = makeFiles(for: [movie])

        XCTAssertNil(FileSourceViewModel.episodeQueue(
            selecting: movie, in: [movie], filesByID: files, source: .baiduPan(BaiduPanSource(folderName: "LumaPlayer"))))
    }

    func testEpisodeQueueIsNilForSingleEpisode() {
        let sourceID = UUID()
        let only = makeEpisodeItem(sourceID: sourceID, index: 1)

        XCTAssertNil(FileSourceViewModel.episodeQueue(
            selecting: only, in: [only], filesByID: makeFiles(for: [only]), source: .baiduPan(BaiduPanSource(folderName: "LumaPlayer"))))
    }

    func testEpisodeQueueExcludesNonEpisodeFiles() throws {
        let sourceID = UUID()
        let episodes = (1...2).map { makeEpisodeItem(sourceID: sourceID, index: $0) }
        let extra = SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: 99),
            title: "幕后花絮", kind: .video, overview: nil, year: nil, tmdbID: nil,
            episodeNumber: nil, seasonNumber: nil, episodeTitle: nil,
            durationSeconds: nil, poster: nil, metadataOrigin: .filename)
        let items = episodes + [extra]

        let queue = try XCTUnwrap(FileSourceViewModel.episodeQueue(
            selecting: episodes[0], in: items, filesByID: makeFiles(for: items), source: .baiduPan(BaiduPanSource(folderName: "LumaPlayer"))))

        XCTAssertEqual(queue.episodes.map(\.id), ["10", "20"], "花絮不占一集的位置")
    }

    /// 选集面板靠描述符显示剧照;没有封面保持 nil,⛔ 不假装有封面。
    func testEpisodeQueueCarriesEntryPoster() throws {
        let sourceID = UUID()
        let cover = ImageDescriptor.remote(
            ownerID: sourceID,
            url: URL(string: "https://d.pcs.baidu.com/file/a?access_token=T")!,
            headers: ["User-Agent": "netdisk"],
            cacheKey: "baidu|\(sourceID.uuidString)|10|1700000000|cover|400"
        )
        let withCover = SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: 10),
            title: "示例剧", kind: .episode, overview: nil, year: nil, tmdbID: nil,
            episodeNumber: 1, seasonNumber: 1, episodeTitle: "第一集",
            durationSeconds: nil, poster: cover, metadataOrigin: .filename)
        let noCover = makeEpisodeItem(sourceID: sourceID, index: 2)
        let items = [withCover, noCover]

        let queue = try XCTUnwrap(FileSourceViewModel.episodeQueue(
            selecting: withCover, in: items, filesByID: makeFiles(for: items), source: .baiduPan(BaiduPanSource(folderName: "LumaPlayer"))))

        XCTAssertEqual(queue.current?.poster, cover, "有封面就带上")
        XCTAssertEqual(queue.current?.title, "第一集", "有集名就用集名")
        XCTAssertNil(queue.episodes[1].poster, "没有封面就是 nil(面板降级成占位图)")
    }

    /// 继续观看卡片起播时没有兄弟上下文,靠它决定去列哪一层。
    func testDirectoryOfFilePath() {
        XCTAssertEqual(
            BaiduPanPath.directory(ofFilePath: "/apps/LumaPlayer/剧/第 1 集.mp4"),
            "/apps/LumaPlayer/剧")
        XCTAssertEqual(BaiduPanPath.directory(ofFilePath: "/a.mp4"), "/")
    }

    // MARK: - 续播卡片点进详情页

    /// 卡片进剧目录而非季文件夹(否则显示成剧名为「第1季」的单季剧)。判据与合成器的剧集文件夹判定同源。
    func testSeriesDirectorySkipsSeasonFolder() {
        // 平铺存法:剧目录下直接摆集文件,父目录就是剧目录
        XCTAssertEqual(
            BaiduPanPath.seriesDirectory(ofFilePath: "/apps/LumaPlayer/琅琊榜/01.mp4"),
            "/apps/LumaPlayer/琅琊榜")
        // 季文件夹存法:再上一层
        XCTAssertEqual(
            BaiduPanPath.seriesDirectory(
                ofFilePath: "/apps/LumaPlayer/琅琊榜/第1季/01.mp4"),
            "/apps/LumaPlayer/琅琊榜")
        XCTAssertEqual(
            BaiduPanPath.seriesDirectory(
                ofFilePath: "/apps/LumaPlayer/琅琊榜/Season 2/01.mp4"),
            "/apps/LumaPlayer/琅琊榜")
        // 标准命名库:剧目录带 `{tmdbid-N}`,季文件夹在它下面
        XCTAssertEqual(
            BaiduPanPath.seriesDirectory(
                ofFilePath: "/apps/LumaPlayer/一拳超人 (2015) {tmdbid-63926}/Season 1/01.mp4"),
            "/apps/LumaPlayer/一拳超人 (2015) {tmdbid-63926}")
        // 认不出季标记就不猜:父目录名是剧名(或分类目录名)时就是它自己
        XCTAssertEqual(
            BaiduPanPath.seriesDirectory(ofFilePath: "/apps/LumaPlayer/电影/300.mp4"),
            "/apps/LumaPlayer/电影")
        // 已经到根:没有再上一层可言,退回父目录,⛔ 不返回空串
        XCTAssertEqual(
            BaiduPanPath.seriesDirectory(ofFilePath: "/第1季/01.mp4"),
            "/第1季")
    }

    /// 落点不越出这一页的最外层(同 `canGoUp`):片库根设在某一季时退回文件所在目录。
    func testDetailDirectoryStaysWithinTopmost() {
        let path = "/apps/LumaPlayer/Videos/琅琊榜/第1季/01.mp4"

        XCTAssertEqual(
            FileSourceViewModel.detailDirectory(
                ofFilePath: path, topmost: "/apps/LumaPlayer/Videos"),
            "/apps/LumaPlayer/Videos/琅琊榜", "剧目录在片库根之内 → 用它")
        XCTAssertEqual(
            FileSourceViewModel.detailDirectory(
                ofFilePath: path, topmost: "/apps/LumaPlayer/Videos/琅琊榜/第1季"),
            "/apps/LumaPlayer/Videos/琅琊榜/第1季",
            "剧目录在片库根之上 → 退回文件所在目录,⛔ 不越界")
        XCTAssertEqual(
            FileSourceViewModel.detailDirectory(ofFilePath: path, topmost: nil),
            "/apps/LumaPlayer/Videos/琅琊榜", "还没读到最外层时不做限制")
    }

    /// 默认选卡片那一集所属的季,否则「继续播放」会变成「播放第 1 集」。
    func testSeasonNumberFromFilePath() {
        XCTAssertEqual(
            FileSourceViewModel.seasonNumber(
                ofFilePath: "/apps/LumaPlayer/琅琊榜/第1季/01.mp4"), 1)
        XCTAssertEqual(
            FileSourceViewModel.seasonNumber(
                ofFilePath: "/apps/LumaPlayer/琅琊榜/S0/01.mp4"), 0,
            "第 0 季(特别篇)是合法季号,⛔ 不当「没解析出来」")
        XCTAssertEqual(
            FileSourceViewModel.seasonNumber(
                ofFilePath: "/apps/LumaPlayer/琅琊榜/Show.S02E07.mkv"), 2,
            "季号也能来自文件名")
        XCTAssertNil(
            FileSourceViewModel.seasonNumber(
                ofFilePath: "/apps/LumaPlayer/琅琊榜/01.mp4"),
            "平铺存法认不出季号 → 详情页退回第一季(与判定层同一口径)")
        XCTAssertNil(
            FileSourceViewModel.seasonNumber(
                ofFilePath: "/apps/LumaPlayer/电影/300.mp4"))
    }

    // MARK: - 「继续观看」按隐藏路径过滤

    /// 隐藏目录时其中各集的卡片也要消失:记录记的是集文件 `fs_id`,只按 `ref` 过滤挡不住。
    func testResumeRecordsUnderHiddenDirectoryAreFiltered() throws {
        let hidden = [HiddenItemsStore.HiddenPath(
            path: "/apps/LumaPlayer/琅琊榜", isDirectory: true)]
        let episode = makeRecord(
            fileID: "1", title: "琅琊榜", locator: "/apps/LumaPlayer/琅琊榜/01.mp4")
        let sibling = makeRecord(
            fileID: "2", title: "别的剧", locator: "/apps/LumaPlayer/别的剧/01.mp4")

        XCTAssertTrue(FileSourceViewModel.isHidden(episode, by: hidden))
        XCTAssertFalse(FileSourceViewModel.isHidden(sibling, by: hidden))
    }

    func testResumeRecordHiddenByFilePathOnly() throws {
        let hidden = [HiddenItemsStore.HiddenPath(
            path: "/apps/LumaPlayer/琅琊榜/01.mp4", isDirectory: false)]
        let deleted = makeRecord(
            fileID: "1", title: "琅琊榜", locator: "/apps/LumaPlayer/琅琊榜/01.mp4")
        let next = makeRecord(
            fileID: "2", title: "琅琊榜", locator: "/apps/LumaPlayer/琅琊榜/02.mp4")

        XCTAssertTrue(FileSourceViewModel.isHidden(deleted, by: hidden))
        XCTAssertFalse(FileSourceViewModel.isHidden(next, by: hidden))
    }

    /// 前缀相似的兄弟目录不能误伤(`琅琊榜` 与 `琅琊榜2`)。
    func testHiddenDirectoryDoesNotCatchPrefixSibling() throws {
        let hidden = [HiddenItemsStore.HiddenPath(
            path: "/apps/LumaPlayer/琅琊榜", isDirectory: true)]
        let sibling = makeRecord(
            fileID: "2", title: "琅琊榜2", locator: "/apps/LumaPlayer/琅琊榜2/01.mp4")

        XCTAssertFalse(FileSourceViewModel.isHidden(sibling, by: hidden))
    }

    func testNoHiddenPathsKeepsEveryRecord() throws {
        let record = makeRecord(
            fileID: "1", title: "琅琊榜", locator: "/apps/LumaPlayer/琅琊榜/01.mp4")

        XCTAssertFalse(FileSourceViewModel.isHidden(record, by: []))
    }

    // MARK: - 夹具

    private func makeEpisodeItem(sourceID: UUID, index: Int) -> SourceItem {
        SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: UInt64(index * 10)),
            title: "示例剧", kind: .episode, overview: nil, year: nil, tmdbID: nil,
            episodeNumber: index, seasonNumber: 1, episodeTitle: nil,
            durationSeconds: nil, poster: nil, metadataOrigin: .filename)
    }

    private func makeFiles(for items: [SourceItem]) -> [UInt64: BaiduPanFile] {
        Dictionary(uniqueKeysWithValues: items.compactMap { item in
            guard let fsID = UInt64(item.ref.itemID) else { return nil }
            return (fsID, BaiduPanFile(
                fsID: fsID,
                path: "/apps/LumaPlayer/\(item.ref.itemID).mp4",
                name: "\(item.ref.itemID).mp4",
                sizeBytes: nil,
                isDirectory: false,
                category: nil,
                modifiedAt: nil,
                thumbnailURL: nil
            ))
        })
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
