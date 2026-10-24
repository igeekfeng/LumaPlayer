import XCTest
@testable import LumaPlayer

/// 本地文件夹来源的生命周期:添加 / 浏览 / 进剧集 / 起播 / 只读 / 换文件夹 / 删除时清本地数据。
/// 访问权走 `FakeBookmarks`;真实打开面板、书签跨启动、外接盘拔插未验证。
@MainActor
final class LocalFolderSourceTests: XCTestCase {
    private var storage: CredentialFileStore!
    private var workspace: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "local-source-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = workspace.appending(path: "片库", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try touch("琅琊榜/01.mkv")
        try touch("琅琊榜/02.mkv")
        try touch("琅琊榜/01.srt")
        try touch("琅琊榜/poster.jpg")
        try touch("电影.2019.mp4")
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        storage = nil
        workspace = nil
        root = nil
        try await super.tearDown()
    }

    private func touch(_ relative: String) throws {
        let url = root.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func makeContainer(bookmarks: FakeBookmarks = FakeBookmarks()) throws -> AppContainer {
        let credentials = CredentialStore(storage: storage)
        let file = { (name: String) in self.workspace.appending(path: "\(name).json") }
        return AppContainer(
            registry: try ServerRegistry(
                defaults: UserDefaults(suiteName: "test.LumaPlayer.local.\(UUID().uuidString)")!,
                credentials: credentials),
            credentials: credentials,
            preferences: UserDefaults(suiteName: "test.LumaPlayer.local.prefs.\(UUID().uuidString)")!,
            watchProgress: WatchProgressStore(fileURL: file("progress")),
            hiddenItems: HiddenItemsStore(fileURL: file("hidden")),
            subtitleBindings: SubtitleBindingStore(fileURL: file("subtitle-bindings")),
            baiduDirectoryCache: BaiduPanDirectoryCache(fileURL: file("dir-cache")),
            baiduScrapeCache: BaiduPanScrapeCache(fileURL: file("scrape-cache")),
            baiduEpisodeCounts: BaiduPanEpisodeCountStore(fileURL: file("episode-counts")),
            localFolderAccess: LocalFolderAccess(bookmarks: bookmarks))
    }

    // MARK: - 添加

    func testAddingLocalFolderRegistersAndSwitches() async throws {
        let container = try makeContainer()

        let source = try await container.addLocalFolderSource(folderURL: root)

        XCTAssertEqual(source.rootName, "片库")
        XCTAssertEqual(source.displayName, "片库", "名称留空用文件夹名")
        XCTAssertEqual(source.lastKnownPath, root.path)
        let stored = await container.sources()
        XCTAssertEqual(stored.first?.localFolderSource, source)
        XCTAssertEqual(container.state.currentSource?.id, source.id)
        XCTAssertNil(container.state.currentServer)
        XCTAssertEqual(container.state.route, .browse)
    }

    // MARK: - 浏览 / 起播

    func testBrowsingEnteringASeriesAndPlayingAnEpisode() async throws {
        let container = try makeContainer()
        let source = try await container.addLocalFolderSource(folderURL: root)
        let viewModel = FileSourceViewModel(container: container, source: .localFolder(source))

        await viewModel.reload()

        XCTAssertNil(viewModel.directoryFailure)
        XCTAssertEqual(viewModel.currentDirectory, "/片库")
        XCTAssertEqual(viewModel.currentDirectoryName, "片库")
        XCTAssertFalse(viewModel.canGoUp, "文件夹本身就是最外层")
        XCTAssertEqual(Set(viewModel.sortedItems.map(\.title)), ["琅琊榜", "电影"])
        XCTAssertNil(viewModel.authorization, "本地文件夹没有授权这一步")

        let series = try XCTUnwrap(viewModel.sortedItems.first { $0.kind.isContainer })
        await viewModel.enter(series)

        XCTAssertTrue(viewModel.directoryShape.isSeries, "两集平铺 → 剧集详情页")
        XCTAssertEqual(viewModel.episodes.count, 2)
        XCTAssertTrue(viewModel.canGoUp)
        let first = try XCTUnwrap(viewModel.episodes.first)
        XCTAssertNotNil(first.poster, "同目录 poster.jpg 当封面")
        if case .localFile = first.poster?.origin {} else { XCTFail("封面应直接读盘") }

        viewModel.play(first)

        let request = try XCTUnwrap(container.state.nowPlaying)
        guard case .localFolder(let file, let playing) = request.source else {
            return XCTFail("应是本地文件夹的播放请求,实际 \(request.source)")
        }
        XCTAssertEqual(file.path, "/片库/琅琊榜/01.mkv")
        XCTAssertEqual(playing.id, source.id)
        XCTAssertEqual(request.episodeQueue?.episodes.count, 2, "兄弟集随请求带进播放页")
        XCTAssertEqual(request.subtitleFiles.map(\.name), ["01.srt"], "同目录字幕零请求配好")

        // 会话:按书签解析出的根 + 虚拟路径落到真实文件上
        let session = try await container.makeSessionPreparer(for: request).makeSession(startTimeTicks: nil)
        XCTAssertEqual(session.plan.url.standardizedFileURL.path,
                       root.appending(path: "琅琊榜/01.mkv").standardizedFileURL.path)
        XCTAssertEqual(session.seekStrategy, .clientSeek)
        XCTAssertEqual(session.externalSubtitles.count, 1)
    }

    /// 本地读盘不缓存目录:刷新就能看到新拷进来的片子。
    func testNewFilesShowUpOnRefreshWithoutCaching() async throws {
        let container = try makeContainer()
        let source = try await container.addLocalFolderSource(folderURL: root)
        let viewModel = FileSourceViewModel(container: container, source: .localFolder(source))
        await viewModel.reload()
        XCTAssertEqual(viewModel.sortedItems.count, 2)

        try touch("新片.mkv")
        await viewModel.refreshFiles()

        XCTAssertEqual(viewModel.sortedItems.count, 3)
    }

    func testResumePositionComesFromTheLocalProgressStore() async throws {
        let container = try makeContainer()
        let source = try await container.addLocalFolderSource(folderURL: root)
        let viewModel = FileSourceViewModel(container: container, source: .localFolder(source))
        await viewModel.reload()
        let movie = try XCTUnwrap(viewModel.sortedItems.first { $0.kind.isPlayable })
        let file = try XCTUnwrap(viewModel.file(for: movie))
        try await container.watchProgress.record(
            fileID: String(file.fsID), positionSeconds: 120, durationSeconds: 3600)

        let request = PlaybackRequest(source: .localFolder(file: file, source: source))
        let resume = await container.resumeSeconds(for: request, fromBeginning: false)
        let fromStart = await container.resumeSeconds(for: request, fromBeginning: true)

        XCTAssertEqual(resume, 120)
        XCTAssertEqual(fromStart, 0)
    }

    // MARK: - 只读

    func testDeletingFilesIsRefusedButHidingWorks() async throws {
        let container = try makeContainer()
        let source = try await container.addLocalFolderSource(folderURL: root)
        let viewModel = FileSourceViewModel(container: container, source: .localFolder(source))
        await viewModel.reload()
        let movie = try XCTUnwrap(viewModel.sortedItems.first { $0.kind.isPlayable })

        do {
            try await viewModel.delete(movie, alsoDeleteRemotely: true)
            XCTFail("本地文件夹只读,不该删文件")
        } catch let error as LocalFolderError {
            XCTAssertEqual(error, .readOnly)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "电影.2019.mp4").path))

        try await viewModel.delete(movie, alsoDeleteRemotely: false)
        XCTAssertFalse(viewModel.sortedItems.contains(movie), "隐藏后不再出现")
        let hidden = await container.hiddenItems.hiddenRefs(sourceID: source.id)
        XCTAssertEqual(hidden, [movie.ref])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "电影.2019.mp4").path))
    }

    // MARK: - 访问权失效 / 换文件夹

    func testLostAccessAsksForReselectionAndRelinkRecovers() async throws {
        let container = try makeContainer()
        let source = try await container.addLocalFolderSource(folderURL: root)
        let viewModel = FileSourceViewModel(container: container, source: .localFolder(source))
        await viewModel.reload()
        let movie = try XCTUnwrap(viewModel.sortedItems.first { $0.kind.isPlayable })

        // 文件夹被挪走(外接盘换了 / 用户整理了目录)
        let moved = workspace.appending(path: "挪过去", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: root, to: moved)
        await viewModel.refreshFiles()
        XCTAssertEqual(viewModel.directoryFailure?.needsFolderReselection, true)

        await viewModel.relinkFolder(to: moved)

        XCTAssertNil(viewModel.directoryFailure)
        XCTAssertNil(viewModel.notice)
        let relinked = await container.source(id: source.id)?.localFolderSource
        XCTAssertEqual(relinked?.rootName, "片库", "根名不变:路径与 id 都挂在它下面")
        XCTAssertEqual(relinked?.lastKnownPath, moved.path)
        // 同路径的文件 id 不变 —— 续播 / 已看记录跟得过去
        let again = try XCTUnwrap(viewModel.sortedItems.first { $0.kind.isPlayable })
        XCTAssertEqual(again.ref, movie.ref)
    }

    // MARK: - 继续观看

    /// 季文件夹存法:准备好「权游/第1季、第2季」各两集,进到剧详情页(默认第 1 季)。
    private func enterSeasonFolderSeries(
        _ container: AppContainer
    ) async throws -> (FileSourceViewModel, LocalFolderSource) {
        for path in ["权游/第1季/01.mkv", "权游/第1季/02.mkv", "权游/第2季/01.mkv", "权游/第2季/02.mkv"] {
            try touch(path)
        }
        let source = try await container.addLocalFolderSource(folderURL: root)
        let viewModel = FileSourceViewModel(container: container, source: .localFolder(source))
        await viewModel.reload()
        let series = try XCTUnwrap(viewModel.sortedItems.first { $0.title == "权游" })
        await viewModel.enter(series)
        XCTAssertEqual(viewModel.episodes.count, 2)
        return (viewModel, source)
    }

    /// 越过 90% 直接关窗(没有自然播完)也算看完:续播卡指向同季下一集,不能整部剧消失。
    func testClosingPastFinishedThresholdPointsResumeCardToNextEpisode() async throws {
        let container = try makeContainer()
        let (viewModel, _) = try await enterSeasonFolderSeries(container)
        let first = try XCTUnwrap(viewModel.episodes.first)
        let file = try XCTUnwrap(viewModel.file(for: first))
        viewModel.play(first)
        let request = try XCTUnwrap(container.state.nowPlaying)
        await container.rememberResumeCard(item: first, file: file)
        try await container.watchProgress.record(
            fileID: String(file.fsID), positionSeconds: 590, durationSeconds: 600)

        await container.settleFileSourceEpisode(
            request.source, queue: request.episodeQueue,
            naturalEnd: false, endedAt: 590, durationSeconds: 600)
        await viewModel.refreshResumeState()

        XCTAssertEqual(viewModel.resumeCards.map(\.path), ["/片库/权游/第1季/02.mkv"])
        XCTAssertEqual(viewModel.resumeCards.first?.isUpNext, true)
    }

    /// 季末看完:去列后面的季,续播卡指向第 2 季第 1 集。
    func testFinishingSeasonFinalePointsResumeCardToNextSeason() async throws {
        let container = try makeContainer()
        let (viewModel, _) = try await enterSeasonFolderSeries(container)
        let finale = try XCTUnwrap(viewModel.episodes.last)
        let file = try XCTUnwrap(viewModel.file(for: finale))
        viewModel.play(finale)
        let request = try XCTUnwrap(container.state.nowPlaying)
        await container.rememberResumeCard(item: finale, file: file)

        await container.settleFileSourceEpisode(
            request.source, queue: request.episodeQueue,
            naturalEnd: true, endedAt: 600, durationSeconds: nil)
        await viewModel.refreshResumeState()

        XCTAssertEqual(viewModel.resumeCards.map(\.path), ["/片库/权游/第2季/01.mkv"])
        XCTAssertEqual(viewModel.resumeCards.first?.episodeNumber, 1)
    }

    /// 整部剧最后一集看完:没有下一集,卡片该消失(不是 bug)。
    func testFinishingLastEpisodeOfLastSeasonLeavesNoResumeCard() async throws {
        let container = try makeContainer()
        let (viewModel, _) = try await enterSeasonFolderSeries(container)
        await viewModel.selectSeason(viewModel.directoryShape.seriesStructure?.seasons.last)
        let last = try XCTUnwrap(viewModel.episodes.last)
        let file = try XCTUnwrap(viewModel.file(for: last))
        viewModel.play(last)
        let request = try XCTUnwrap(container.state.nowPlaying)
        await container.rememberResumeCard(item: last, file: file)

        await container.settleFileSourceEpisode(
            request.source, queue: request.episodeQueue,
            naturalEnd: true, endedAt: 600, durationSeconds: 600)
        await viewModel.refreshResumeState()

        XCTAssertTrue(viewModel.resumeCards.isEmpty)
    }

    /// 在续播卡上「标记为已看」:没有播放队列,列所在目录与后面的季找下一集。
    func testMarkingResumeCardPlayedAdvancesToNextSeason() async throws {
        let container = try makeContainer()
        let (viewModel, _) = try await enterSeasonFolderSeries(container)
        let finale = try XCTUnwrap(viewModel.episodes.last)
        let file = try XCTUnwrap(viewModel.file(for: finale))
        await container.rememberResumeCard(item: finale, file: file)
        try await container.watchProgress.record(
            fileID: String(file.fsID), positionSeconds: 100, durationSeconds: 600)
        await viewModel.refreshResumeState()
        let card = try XCTUnwrap(viewModel.resumeCards.first)

        await viewModel.markPlayed(card)

        XCTAssertNil(viewModel.notice)
        XCTAssertEqual(viewModel.resumeCards.map(\.path), ["/片库/权游/第2季/01.mkv"])
    }

    /// 点过播放、0 秒就关窗的一集也留在「继续观看」里;各季的记录并成一张卡。
    func testPlayedEpisodesAcrossSeasonsShareOneResumeCard() async throws {
        let container = try makeContainer()
        let (viewModel, _) = try await enterSeasonFolderSeries(container)
        let first = try XCTUnwrap(viewModel.episodes.first)
        let firstFile = try XCTUnwrap(viewModel.file(for: first))
        await container.rememberResumeCard(item: first, file: firstFile)
        try await container.watchProgress.record(
            fileID: String(firstFile.fsID), positionSeconds: 0, durationSeconds: nil)
        await viewModel.refreshResumeState()
        XCTAssertEqual(viewModel.resumeCards.map(\.path), ["/片库/权游/第1季/01.mkv"])

        await viewModel.selectSeason(viewModel.directoryShape.seriesStructure?.seasons.last)
        let later = try XCTUnwrap(viewModel.episodes.first)
        let laterFile = try XCTUnwrap(viewModel.file(for: later))
        await container.rememberResumeCard(item: later, file: laterFile)
        try await container.watchProgress.record(
            fileID: String(laterFile.fsID), positionSeconds: 120, durationSeconds: 600)
        await viewModel.refreshResumeState()

        XCTAssertEqual(viewModel.resumeCards.map(\.path), ["/片库/权游/第2季/01.mkv"])
    }

    // MARK: - 删来源

    func testRemovingTheSourcePurgesItsLocalDataAndClosesAccess() async throws {
        let bookmarks = FakeBookmarks()
        let container = try makeContainer(bookmarks: bookmarks)
        let source = try await container.addLocalFolderSource(folderURL: root)
        let viewModel = FileSourceViewModel(container: container, source: .localFolder(source))
        await viewModel.reload()
        let movie = try XCTUnwrap(viewModel.sortedItems.first { $0.kind.isPlayable })
        let file = try XCTUnwrap(viewModel.file(for: movie))
        try await container.watchProgress.rememberDisplay(
            fileID: String(file.fsID),
            display: WatchProgressStore.Display(item: movie, file: file))
        try await container.watchProgress.record(
            fileID: String(file.fsID), positionSeconds: 60, durationSeconds: 600)
        viewModel.play(movie)
        XCTAssertNotNil(container.state.nowPlaying)
        let folder = try XCTUnwrap(viewModel.sortedItems.first { $0.kind.isContainer })
        try await viewModel.delete(folder, alsoDeleteRemotely: false)
        // 添加时做书签也开 / 关过一次访问权,只看删来源这一下
        let stoppedBefore = bookmarks.counts.stopped

        try await container.removeSource(id: source.id)

        XCTAssertNil(container.state.nowPlaying, "访问权要关,正在播的先停")
        let records = await container.watchProgress.storedRecords(sourceID: source.id)
        XCTAssertTrue(records.isEmpty)
        let hidden = await container.hiddenItems.hiddenRefs(sourceID: source.id)
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(bookmarks.counts.stopped, stoppedBefore + 1, "访问权随来源关掉")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "⛔ 不动用户的文件夹")
        XCTAssertEqual(container.state.route, .onboarding)
    }
}
