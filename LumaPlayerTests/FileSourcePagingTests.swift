import XCTest
@testable import LumaPlayer

/// 网盘源文件列表的分页。
///
/// 覆盖三件最容易出错的事:
/// 1. **终止判据两家不同** —— 百度 `method=list` 的响应里没有总数字段(只有「不满页即到底」),
///    115 的 `count` 是目录总条目数(能精确判断)。
/// 2. **合成必须拿累计的整套文件** —— 只给一页会把 `01.mp4` 判成电影、封面也配不上。
/// 3. **翻页失败不清空已显示的内容** —— 与 Emby 侧 `PagedItemList` 的语义一致。
final class FileSourcePagingTests: XCTestCase {
    private var session: URLSession!
    private var storage: CredentialFileStore!

    override func setUp() async throws {
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        session = nil
    }

    // MARK: - 百度的终止判据

    /// 百度这一侧拿不到总数:`hasMore` 只能靠「这一页不满」推断。
    func testBaiduPageReportsHasMoreOnlyWhenPageIsFull() async throws {
        let client = BaiduPanAPIClient(session: session)
        MockEmbyURLProtocol.stub(
            .json(Self.baiduListJSON(count: 3)),
            host: "pan.baidu.com", path: "/rest/2.0/xpan/file")

        let page = try await client.listPage(
            directory: "/apps/LumaPlayer", accessToken: "AT", start: 0, limit: 3)

        XCTAssertEqual(page.files.count, 3)
        XCTAssertTrue(page.hasMore, "满页 → 可能还有下一页")
    }

    /// 不满页 = 到底了。
    func testBaiduPageReportsNoMoreWhenPageIsShort() async throws {
        let client = BaiduPanAPIClient(session: session)
        MockEmbyURLProtocol.stub(
            .json(Self.baiduListJSON(count: 2)),
            host: "pan.baidu.com", path: "/rest/2.0/xpan/file")

        let page = try await client.listPage(
            directory: "/apps/LumaPlayer", accessToken: "AT", start: 0, limit: 3)

        XCTAssertFalse(page.hasMore, "不满页 → 到底了")
    }

    /// `start` 是偏移量,翻页要靠它(官方推荐的 `list` 翻页方式)。
    func testBaiduPageSendsTheGivenOffset() async throws {
        let client = BaiduPanAPIClient(session: session)
        MockEmbyURLProtocol.stub(
            .json(Self.baiduListJSON(count: 2)),
            host: "pan.baidu.com", path: "/rest/2.0/xpan/file")

        _ = try await client.listPage(
            directory: "/apps/LumaPlayer", accessToken: "AT", start: 1000, limit: 1000)

        let request = MockEmbyURLProtocol.recordedRequests()
            .first { $0.url.path == "/rest/2.0/xpan/file" }
        XCTAssertEqual(Self.queryValue(request?.url, "start"), "1000")
        XCTAssertEqual(Self.queryValue(request?.url, "limit"), "1000")
    }

    /// 下一页的起点是 `start + limit`(**服务端口径**),⛔ 不是 `start + 本页条数`。
    ///
    /// `list` 的条目里可能有缺 `path` / `fs_id` 的(解码时丢掉),
    /// 那种情况下本页条数少于服务端实际推进的条数 → 用它推进会**漏项**。
    func testBaiduNextOffsetUsesTheServerSideStride() async throws {
        let client = BaiduPanAPIClient(session: session)
        // 服务端给了 3 条,但其中 1 条缺 `fs_id`(会被 compactMap 丢掉)
        let body = """
        {"errno":0,"list":[
          {"fs_id":1,"path":"/apps/LumaPlayer/a.mp4","server_filename":"a.mp4","isdir":0},
          {"path":"/apps/LumaPlayer/b.mp4","server_filename":"b.mp4","isdir":0},
          {"fs_id":3,"path":"/apps/LumaPlayer/c.mp4","server_filename":"c.mp4","isdir":0}
        ]}
        """
        MockEmbyURLProtocol.stub(
            .json(body), host: "pan.baidu.com", path: "/rest/2.0/xpan/file")

        let page = try await client.listPage(
            directory: "/apps/LumaPlayer", accessToken: "AT", start: 0, limit: 3)

        XCTAssertEqual(page.files.count, 2, "缺 fs_id 的那条被丢掉")
        XCTAssertTrue(page.hasMore, "服务端给了满页 → 可能还有")
        XCTAssertEqual(page.nextOffset, 3, "下一页起点按服务端口径算,⛔ 不能用本页条数 2")
    }

    // MARK: - 跨页合成

    /// ⛔ 只合成一页会把 `01.mp4` 判成电影:「成串的集号」要拿**整套**文件才算得出。
    ///
    /// 这是分页最容易踩的坑:第一页只有 `01.mp4` 一个集号型文件,合成器的
    /// `looksLikeEpisodeSequence` 判据(同目录 ≥2 个)不成立 → 剧名认不出来。
    func testComposingAcrossPagesKeepsTheEpisodeSequence() async throws {
        let sourceID = UUID()
        // 第一页只有 01.mp4,第二页才是 02.mp4 —— 分在两页里
        let firstPage = [Self.file(name: "01.mp4", id: 1)]
        let secondPage = [Self.file(name: "02.mp4", id: 2)]
        let provider = BaiduPanSourceProvider(
            connection: BaiduPanConnection(
                credentials: CredentialStore(storage: storage),
                client: BaiduPanAPIClient(session: session)),
            sourceID: sourceID,
            folderName: "LumaPlayer",
            scraper: BaiduPanMetadataScraper(credentials: CredentialStore(storage: storage)))

        // 只给第一页:认不出剧名(当成普通视频)
        let alone = provider.compose(files: firstPage)
        XCTAssertEqual(alone.items.count, 1)
        XCTAssertEqual(alone.items.first?.kind, .video, "单个集号型文件成串判据不成立")

        // 累计两页:成串了,认得出剧集
        let accumulated = provider.compose(files: firstPage + secondPage)
        XCTAssertEqual(accumulated.items.count, 2)
        XCTAssertEqual(accumulated.items.first?.kind, .episode, "成串后要认成剧集")
        XCTAssertEqual(accumulated.items.first?.episodeNumber, 1)
        XCTAssertEqual(accumulated.items.last?.episodeNumber, 2)
    }

    /// 同目录封面要拿**整套**文件才配得上:封面文件可能在第二页。
    func testComposingAcrossPagesFindsACoverOnTheLaterPage() async throws {
        let sourceID = UUID()
        let firstPage = [Self.file(name: "01.mkv", id: 1)]
        let secondPage = [Self.file(name: "poster.jpg", id: 2)]
        let provider = BaiduPanSourceProvider(
            connection: BaiduPanConnection(
                credentials: CredentialStore(storage: storage),
                client: BaiduPanAPIClient(session: session)),
            sourceID: sourceID,
            folderName: "LumaPlayer",
            scraper: BaiduPanMetadataScraper(credentials: CredentialStore(storage: storage)))

        let accumulated = provider.compose(files: firstPage + secondPage)
        XCTAssertEqual(
            accumulated.coverFileIDs[accumulated.items.first?.ref.itemID ?? ""], 2,
            "封面在第二页也要配得上")
    }

    // MARK: - 115 的总数

    /// 115 的 `count` 是目录总条目数 → 能精确回答「还有没有下一页」。
    func testPan115PageReportsTheDirectoryTotal() async throws {
        let client = Pan115APIClient(session: session)
        // 目录 2500 条,一页 1000 条 → 还有两页
        MockEmbyURLProtocol.stub(
            .json(Self.pan115ListJSON(count: 1000, start: 0, total: 2500)),
            host: "webapi.115.com", path: "/files")

        let page = try await client.listPage(
            cid: "0", credential: Self.credential, offset: 0, limit: 1000)

        XCTAssertEqual(page.totalCount, 2500, "count 是目录总条目数")
        XCTAssertTrue(page.hasMore, "总数还有剩 → 还有下一页")
        // ⚠️ 下一起点是**服务端口径**(`offset + limit`),⛔ 不是 `offset + 本页条数`:
        // 解码时丢掉缺 `cid` 的条目会让本页条数少于服务端实际推进的条数 → 漏项
        XCTAssertEqual(page.nextOffset, 1000)
    }

    /// 目录比一页还小 → 到底了(总数说了算,⛔ 不是「本页满不满」)。
    func testPan115PageReportsNoMoreWhenTheDirectoryFitsInOnePage() async throws {
        let client = Pan115APIClient(session: session)
        MockEmbyURLProtocol.stub(
            .json(Self.pan115ListJSON(count: 10, start: 0, total: 10)),
            host: "webapi.115.com", path: "/files")

        let page = try await client.listPage(
            cid: "0", credential: Self.credential, offset: 0, limit: 1000)

        XCTAssertFalse(page.hasMore, "总数就 10 条,一页装得下 → 到底")
    }

    /// 取完了 → 到底了。
    func testPan115PageReportsNoMoreWhenTotalIsReached() async throws {
        let client = Pan115APIClient(session: session)
        MockEmbyURLProtocol.stub(
            .json(Self.pan115ListJSON(count: 2, start: 8, total: 10)),
            host: "webapi.115.com", path: "/files")

        let page = try await client.listPage(
            cid: "0", credential: Self.credential, offset: 8, limit: 1000)

        XCTAssertFalse(page.hasMore, "总数取完了 → 到底")
    }

    // MARK: - 落盘缓存的完整性标记

    /// 翻页没列完就存的那份要标出来,冷启动时才提示「还有更多」。
    func testDirectoryCacheRemembersIncompleteListings() async throws {
        let cache = BaiduPanDirectoryCache(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "dir-cache-\(UUID().uuidString).json", directoryHint: .notDirectory))
        let sourceID = UUID()

        await cache.store(
            sourceID: sourceID, directory: "/apps/LumaPlayer",
            files: [Self.file(name: "01.mkv", id: 1)], durations: [:], isComplete: false)

        let entry = await cache.content(sourceID: sourceID, directory: "/apps/LumaPlayer")
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry?.isComplete ?? true, "不完整的那份要标出来")

        // 复原成浏览状态时,不能当成已经列完
        let state = FileSourceDirectoryState.restoring(
            FileSourceDirectoryContent(items: [], filesByID: [:], durations: [:]),
            isComplete: entry?.isComplete ?? true)
        XCTAssertTrue(state.hasMore, "不完整的那份要能继续翻")
    }

    /// 老缓存没有这一格 → 当**不完整**:宁可多提示一句,也不能把截断当完整。
    func testLegacyDirectoryCacheEntriesAreTreatedAsIncomplete() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "legacy-cache-\(UUID().uuidString).json", directoryHint: .notDirectory)
        let sourceID = UUID()
        // 手写一份没有 `isComplete` 的旧格式(时间戳要新,否则会被过期判断挡掉)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let legacy = """
        {"sources":{"\(sourceID.uuidString)":{"/apps/LumaPlayer":{
          "files":[],"durations":{},"fetchedAt":"\(stamp)"}}}}
        """
        try Data(legacy.utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let cache = BaiduPanDirectoryCache(fileURL: fileURL)

        let entry = await cache.content(sourceID: sourceID, directory: "/apps/LumaPlayer")
        XCTAssertNotNil(entry, "旧格式要能读出来")
        XCTAssertFalse(entry?.isComplete ?? true, "老缓存没有这一格 → 当不完整")
    }

    // MARK: - 回归:复核发现的问题

    /// 翻页后**已加载条目的时长不能丢**。
    ///
    /// ⚠️ `compose` 重新造出来的条目 `durationSeconds` 恒 nil,
    /// `enrich` 若只填本次请求到的时长,第一页的条目就会集体丢时长
    /// (UI 读的是 `items[].durationSeconds`,⛔ 不是 `durations` 字典)。
    @MainActor
    func testLoadingMoreKeepsTheDurationsOfAlreadyLoadedItems() async throws {
        let provider = StubBrowsingProvider(
            pages: [
                StubBrowsingProvider.Page(
                    files: [Self.file(name: "01.mkv", id: 1)],
                    hasMore: true, nextOffset: 1, totalCount: 2),
                StubBrowsingProvider.Page(
                    files: [Self.file(name: "02.mkv", id: 2)],
                    hasMore: false, nextOffset: 2, totalCount: 2)
            ],
            durations: [1: 120, 2: 240])
        let viewModel = FileSourceViewModel(
            container: try makeContainer(),
            source: .localFolder(Self.localFolderSource()),
            loadsDirectory: true)
        viewModel.setBrowsingProviderOverride(provider)

        await viewModel.reload()
        XCTAssertEqual(viewModel.sortedItems.first?.durationSeconds, 120)

        await viewModel.loadMoreItems()

        let first = viewModel.sortedItems.first { $0.ref.itemID == "1" }
        XCTAssertEqual(first?.durationSeconds, 120, "翻页后老条目的时长不能丢")
    }

    /// 游标不可信时(老落盘缓存复原的偏移量是 0)这一页可能与已有内容重叠,
    /// ⛔ 不能出现重复条目。
    @MainActor
    func testLoadingMoreDoesNotDuplicateEntries() async throws {
        let provider = StubBrowsingProvider(
            pages: [
                StubBrowsingProvider.Page(
                    files: [Self.file(name: "01.mkv", id: 1)],
                    hasMore: true, nextOffset: 0, totalCount: 2),
                StubBrowsingProvider.Page(
                    files: [Self.file(name: "01.mkv", id: 1), Self.file(name: "02.mkv", id: 2)],
                    hasMore: false, nextOffset: 2, totalCount: 2)
            ])
        let viewModel = FileSourceViewModel(
            container: try makeContainer(),
            source: .localFolder(Self.localFolderSource()),
            loadsDirectory: true)
        viewModel.setBrowsingProviderOverride(provider)

        await viewModel.reload()
        await viewModel.loadMoreItems()

        XCTAssertEqual(viewModel.sortedItems.count, 2, "重叠的那条要去重")
        XCTAssertEqual(
            Set(viewModel.sortedItems.map(\.ref.itemID)), ["1", "2"])
    }

    /// 115:服务端**没回显** `offset` 时,⛔ 不能当成「它不认」——
    /// 那是「无法证伪」而不是「证伪」。当成不认会让浏览页永远停在第一页
    /// (目录明明有 3000 条,界面只显示 1000 条,⛔ 还不报错)。
    ///
    /// 回绕的防护靠「内容重复」那道闸(累计时按 `fs_id` 去重),⛔ 不靠这一格。
    func testPan115AcceptsAPageWithoutAnEchoedOffset() async throws {
        let client = Pan115APIClient(session: session)
        // 服务端只给 count,不给 offset
        let body = """
        {"state":1,"cid":"0","count":3000,"data":[
          {"fid":"1","cid":"0","n":"a.mp4","s":"1","pc":"PC1","te":1,"iv":"1"},
          {"fid":"2","cid":"0","n":"b.mp4","s":"1","pc":"PC2","te":1,"iv":"1"}
        ]}
        """
        MockEmbyURLProtocol.stub(.json(body), host: "webapi.115.com", path: "/files")

        let page = try await client.listPage(
            cid: "0", credential: Self.credential, offset: 1000, limit: 1000)

        XCTAssertTrue(page.isOffsetHonored, "没回显 ≠ 不认")
        XCTAssertTrue(page.hasMore, "总数还有剩 → 还有下一页")
        XCTAssertEqual(page.nextOffset, 2000)
    }

    /// 115:回显的 offset 与请求的不一致(服务端悄悄从头开始)⇒ 当成不认。
    func testPan115StopsWhenTheServerResetsTheOffset() async throws {
        let client = Pan115APIClient(session: session)
        let body = """
        {"state":1,"cid":"0","count":1000000,"offset":0,"data":[
          {"fid":"1","cid":"0","n":"a.mp4","s":"1","pc":"PC1","te":1,"iv":"1"}
        ]}
        """
        MockEmbyURLProtocol.stub(.json(body), host: "webapi.115.com", path: "/files")

        let page = try await client.listPage(
            cid: "0", credential: Self.credential, offset: 500, limit: 1000)

        XCTAssertFalse(page.isOffsetHonored, "offset 回绕 ⇒ 当成不认")
    }

    /// 115 的 `hasMore` 用**服务端口径**推进量,⛔ 不用解码后的条数 ——
    /// 缺 `cid` 的条目被丢掉会让它少于服务端实际推进的条数 ⇒ 多发一次空请求。
    func testPan115HasMoreUsesTheServerStride() {
        // 服务端推进了 1000 条(其中 3 条缺 cid 被丢掉),总数 1000 → 到底
        XCTAssertFalse(Pan115APIClient.hasMore(
            fetched: 997, offset: 0, limit: 1000, totalCount: 1000))
        // 总数还有剩 → 还有下一页
        XCTAssertTrue(Pan115APIClient.hasMore(
            fetched: 997, offset: 0, limit: 1000, totalCount: 2000))
    }

    /// 落盘缓存复原的偏移量 = 已有条数:百度 `start` 就是「跳过前 N 条」,
    /// 而服务端先全目录排序再切片 ⇒ 列到第 N 条,下一页的起点就是 N。
    func testRestoringAnIncompleteListingContinuesFromWhereItStopped() {
        let content = FileSourceDirectoryContent(
            items: [],
            filesByID: [1: Self.file(name: "01.mkv", id: 1)],
            durations: [:])
        let state = FileSourceDirectoryState.restoring(content, isComplete: false)

        XCTAssertTrue(state.hasMore)
        XCTAssertEqual(state.nextOffset, 1, "已有条数 = 服务端的下一个起点")
    }

    /// 合并两批文件要按 `fs_id` 去重(游标不可信时可能重叠)。
    func testMergingFilesDeduplicatesByID() {
        let first = [Self.file(name: "01.mkv", id: 1)]
        let second = [Self.file(name: "01.mkv", id: 1), Self.file(name: "02.mkv", id: 2)]

        let merged = mergingFileSources(first, second)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.fsID), [1, 2])
    }

    // MARK: - 浏览页的翻页状态机

    /// 浏览页一页 100 条,⛔ 不是接口侧的 `limit=1000`(那是「一次拿整层」的口径)。
    ///
    /// 一页 1000 条会连带打 10 次 `filemetas`(按 100 个 `fs_id` 一批),
    /// 而用户只看得到头几屏。首屏与翻页要用同一个值。
    @MainActor
    func testBrowsingUsesAReadablePageSize() async throws {
        let provider = StubBrowsingProvider(pages: [
            StubBrowsingProvider.Page(
                files: [Self.file(name: "01.mkv", id: 1)],
                hasMore: true, nextOffset: 1, totalCount: 2),
            StubBrowsingProvider.Page(
                files: [Self.file(name: "02.mkv", id: 2)],
                hasMore: false, nextOffset: 2, totalCount: 2)
        ])
        let viewModel = FileSourceViewModel(
            container: try makeContainer(),
            source: .localFolder(Self.localFolderSource()),
            loadsDirectory: true)
        viewModel.setBrowsingProviderOverride(provider)

        await viewModel.reload()
        await viewModel.loadMoreItems()

        let limits = await provider.requestedLimits
        XCTAssertEqual(limits, [100, 100], "首屏与翻页都用 100,⛔ 不是接口上限 1000")
    }

    /// 首屏列完第一页后要能翻页。
    ///
    /// ⛔ 这条守的是「现取那一支有没有把翻页游标写进状态」:
    /// 只写会话缓存不写状态的话,首屏就永远停在第一页,页脚也不出现。
    @MainActor
    func testFirstPageEnablesLoadingMore() async throws {
        let provider = StubBrowsingProvider(pages: [
            StubBrowsingProvider.Page(
                files: [Self.file(name: "01.mkv", id: 1)],
                hasMore: true, nextOffset: 1, totalCount: 2)
        ])
        let viewModel = FileSourceViewModel(
            container: try makeContainer(),
            source: .localFolder(Self.localFolderSource()),
            loadsDirectory: true)
        viewModel.setBrowsingProviderOverride(provider)

        await viewModel.reload()

        XCTAssertTrue(viewModel.hasMoreItems, "第一页说还有下一页 → 能翻")
        XCTAssertEqual(viewModel.sortedItems.count, 1)
    }

    /// 翻页把内容**追加**上去,⛔ 不替换掉第一页的条目。
    @MainActor
    func testLoadingMoreAppendsToTheExistingItems() async throws {
        let provider = StubBrowsingProvider(pages: [
            StubBrowsingProvider.Page(
                files: [Self.file(name: "01.mkv", id: 1)],
                hasMore: true, nextOffset: 1, totalCount: 2),
            StubBrowsingProvider.Page(
                files: [Self.file(name: "02.mkv", id: 2)],
                hasMore: false, nextOffset: 2, totalCount: 2)
        ])
        let viewModel = FileSourceViewModel(
            container: try makeContainer(),
            source: .localFolder(Self.localFolderSource()),
            loadsDirectory: true)
        viewModel.setBrowsingProviderOverride(provider)

        await viewModel.reload()
        XCTAssertTrue(viewModel.hasMoreItems)

        await viewModel.loadMoreItems()

        XCTAssertEqual(viewModel.sortedItems.count, 2, "翻页是追加,⛔ 不是替换")
        XCTAssertFalse(viewModel.hasMoreItems, "第二页说到底了")
        XCTAssertNil(viewModel.loadMoreFailure)
    }

    /// 翻页失败**不清空**已显示的内容(同 Emby 侧 `PagedItemList` 的语义)。
    @MainActor
    func testLoadingMoreFailureKeepsTheLoadedItems() async throws {
        let provider = StubBrowsingProvider(
            pages: [
                StubBrowsingProvider.Page(
                    files: [Self.file(name: "01.mkv", id: 1)],
                    hasMore: true, nextOffset: 1, totalCount: 2)
            ],
            failOnSecondPage: true)
        let viewModel = FileSourceViewModel(
            container: try makeContainer(),
            source: .localFolder(Self.localFolderSource()),
            loadsDirectory: true)
        viewModel.setBrowsingProviderOverride(provider)

        await viewModel.reload()
        await viewModel.loadMoreItems()

        XCTAssertEqual(viewModel.sortedItems.count, 1, "翻页失败不得清空已加载的内容")
        XCTAssertNotNil(viewModel.loadMoreFailure, "失败要在页脚报出来")
        XCTAssertTrue(viewModel.hasMoreItems, "失败了还能重试")
    }

    /// 翻页在飞时切了目录 ⇒ 翻页结果被丢弃(防串目录),
/// 且 `isLoadingMoreItems` **必须复位** —— 卡住的话这一格再也不会被清,
/// 整个来源从此翻不了页(重载也不救)。
@MainActor
func testPagingInFlightThenSwitchingDirectoryResetsTheLoadingFlag() async throws {
    let provider = StubBrowsingProvider(
        pages: [
            StubBrowsingProvider.Page(
                files: [Self.file(name: "01.mkv", id: 1)],
                hasMore: true, nextOffset: 1, totalCount: 2),
            StubBrowsingProvider.Page(
                files: [Self.file(name: "02.mkv", id: 2)],
                hasMore: false, nextOffset: 2, totalCount: 2)
        ],
        stallOnSecondPage: true)
    let viewModel = FileSourceViewModel(
        container: try makeContainer(),
        source: .localFolder(Self.localFolderSource()),
        loadsDirectory: true)
    viewModel.setBrowsingProviderOverride(provider)

    await viewModel.reload()
    XCTAssertTrue(viewModel.hasMoreItems)

    // 翻页发起(第二页会挂住)
    let paging = Task { await viewModel.loadMoreItems() }
    for _ in 0..<80 {
        if await provider.pageCallCount >= 2 { break }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTAssertTrue(viewModel.isLoadingMoreItems, "翻页在飞")

    // 切目录:generation +1,翻页结果回来会被丢弃
    await viewModel.loadFiles()
    await provider.gate?.release()
    await paging.value

    XCTAssertFalse(
        viewModel.isLoadingMoreItems,
        "切目录后翻页标志必须复位,⛔ 否则这一格卡住就再也翻不了页")
}

/// 删掉当前目录里的一条 ⇒ 还能继续翻页。
///
/// ⚠️ 过度清理(把整个翻页状态丢掉)会让 `hasMoreItems` 变 false → 页脚消失 →
/// 用户以为目录就这些,而这一层其余几百条还在屏幕上、却再也翻不出后面的页。
func testRemovingAnItemKeepsThePagingAvailable() {
    let files = [Self.file(name: "01.mkv", id: 1), Self.file(name: "02.mkv", id: 2)]
    let items = files.enumerated().map { index, file in
        SourceItem(
            ref: SourceItemRef(sourceID: UUID(), fsID: file.fsID),
            title: file.name, kind: .video, overview: nil, year: nil, tmdbID: nil,
            episodeNumber: nil, seasonNumber: nil, episodeTitle: nil,
            durationSeconds: nil, poster: nil, metadataOrigin: .none)
    }
    let state = FileSourceDirectoryState(
        content: FileSourceDirectoryContent(
            items: items,
            filesByID: Dictionary(uniqueKeysWithValues: files.map { ($0.fsID, $0) }),
            durations: [:]),
        files: files,
        hasMore: true,
        nextOffset: 2,
        totalCount: 3)

    let after = removingFileSource(1, from: state)

    XCTAssertTrue(after.hasMore, "删一条不该让页脚消失")
    XCTAssertEqual(after.nextOffset, 2, "游标不动:删一条不改变服务端的位置")
    XCTAssertEqual(after.files.count, 1, "被删的那条要真的从状态里剔掉")
    XCTAssertEqual(after.content.items.count, 1)
}

// MARK: - 辅助

    private static let credential = Pan115Credential(
        uid: "u", cid: "c", seid: "s", kid: nil)

    /// 一个够用的本地文件夹来源(只用到 id 与显示名)。
    private static func localFolderSource() -> LocalFolderSource {
        LocalFolderSource(
            id: UUID(), displayName: "测试", bookmark: Data(), lastKnownPath: "/tmp", rootName: "片库")
    }

    @MainActor
    private func makeContainer() throws -> AppContainer {
        let credentials = CredentialStore(storage: CredentialFileStore(fileURL: .temporaryCredentialsFile()))
        let file = { (name: String) in
            FileManager.default.temporaryDirectory
                .appending(path: "paging-\(UUID().uuidString)-\(name).json")
        }
        return AppContainer(
            registry: try ServerRegistry(
                defaults: UserDefaults(suiteName: "test.LumaPlayer.paging.\(UUID().uuidString)")!,
                credentials: credentials),
            credentials: credentials,
            preferences: UserDefaults(suiteName: "test.LumaPlayer.paging.prefs.\(UUID().uuidString)")!,
            watchProgress: WatchProgressStore(fileURL: file("progress")),
            hiddenItems: HiddenItemsStore(fileURL: file("hidden")),
            subtitleBindings: SubtitleBindingStore(fileURL: file("bindings")),
            baiduDirectoryCache: BaiduPanDirectoryCache(fileURL: file("dir-cache")),
            baiduScrapeCache: BaiduPanScrapeCache(fileURL: file("scrape-cache")),
            baiduEpisodeCounts: BaiduPanEpisodeCountStore(fileURL: file("episode-counts")),
            localFolderAccess: LocalFolderAccess(bookmarks: FakeBookmarks()))
    }
    private static func file(name: String, id: UInt64) -> BaiduPanFile {
        BaiduPanFile(
            fsID: id,
            path: "/apps/LumaPlayer/琅琊榜/\(name)",
            name: name,
            sizeBytes: 1024,
            isDirectory: false,
            category: name.hasSuffix(".jpg") ? 3 : 1,
            modifiedAt: nil,
            thumbnailURL: nil
        )
    }

    /// 百度 `method=list` 的响应:顶层 `errno` + `list[]`。
    private static func baiduListJSON(count: Int) -> String {
        let entries = (0..<count).map { index in
            """
            {"fs_id":\(index + 1),"path":"/apps/LumaPlayer/f\(index + 1).mp4",
             "server_filename":"f\(index + 1).mp4","size":"1024","isdir":0,"category":1}
            """
        }
        return #"{"errno":0,"list":[\#(entries.joined(separator: ","))]}"#
    }

    /// 115 `webapi.115.com/files` 的响应。
    private static func pan115ListJSON(count: Int, start: Int, total: Int) -> String {
        let entries = (0..<count).map { index in
            """
            {"fid":"\(start + index)","cid":"0","n":"f\(start + index).mp4","s":"1024",
             "pc":"PC\(start + index)","sha":"SHA","te":1767319445,"iv":"1"}
            """
        }
        return #"{"state":1,"cid":"0","count":\#(total),"offset":\#(start),"data":[\#(entries.joined(separator: ","))]}"#
    }

    private static func queryValue(_ url: URL?, _ name: String) -> String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}
