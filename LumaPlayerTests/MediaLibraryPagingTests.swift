import XCTest
@testable import LumaPlayer

/// 让 fetch 停在半路的闸门,构造「旧服务器响应晚到」。
/// `withCheckedContinuation` 不响应取消,旧结果仍会回来 —— 正好验证 generation 检查会丢弃它。
private actor StallGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    /// 挂起在闸门上的 fetch 数。必须等它达到预期再 `release()`:`Task` 异步起跑,抢先放行会两边永远等下去。
    var waiterCount: Int { continuations.count }

    func wait() async {
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }
}

/// fetch 调用计数(闭包是 `@Sendable`,不能捕获可变局部量)。
private actor CallCounter {
    private(set) var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

/// `PagedItemList` 状态机:加载、追加、generation 与取消语义(网络部分在 `MediaLibraryBrowsingTests`)。
/// 方法逐个标 `@MainActor`:XCTestCase 是非隔离类,Swift 6 下子类隔离不能与父类不同。
final class MediaLibraryPagingTests: XCTestCase {
    private var session: URLSession!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() async throws {
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
        session = nil
    }

    // MARK: - 首屏与分页

    @MainActor
    func testFirstPageLoadsItemsAndTotal() async throws {
        try stubItems("items_movies_page1_synthetic.json")
        let list = try await makeList()

        list.reload()
        try await waitUntilLoaded(list)

        XCTAssertEqual(list.items.count, 2)
        XCTAssertTrue(list.hasMore, "TotalRecordCount=4,已加载 2 → 还有下一页")
        guard case .loaded(let items) = list.state else { return XCTFail("期望 .loaded") }
        XCTAssertEqual(items.count, 2)
    }

    @MainActor
    func testLoadMoreAppendsAndStopsAtTotal() async throws {
        try stubItems("items_movies_page1_synthetic.json")
        let list = try await makeList()
        list.reload()
        try await waitUntilLoaded(list)

        list.loadMore()
        try await waitUntil { list.items.count >= 4 }

        // mock 按 path 打桩,两页返回同一份数据;这里验证的是**追加**与停止条件
        XCTAssertEqual(list.items.count, 4)
        XCTAssertFalse(list.hasMore)

        let requests = MockEmbyURLProtocol.recordedRequests().filter { $0.url.path.hasSuffix("/Items") }
        XCTAssertEqual(requests.count, 2)
        let startIndexes = requests.compactMap { Self.queryValue($0.url, "StartIndex") }
        XCTAssertEqual(startIndexes, ["0", "2"])
        XCTAssertEqual(Self.queryValue(requests[0].url, "Limit"), String(PagedItemList.pageSize))
    }

    // MARK: - TotalRecordCount 不可信(Q24:带 SearchTerm 时 4.9.5.0 恒返回 0)

    @MainActor
    func testFullPageWithZeroTotalStillOffersNextPage() async throws {
        let fullPage = (0..<PagedItemList.pageSize).map { Self.item(id: "\($0)", name: "第 \($0) 项") }
        let list = PagedItemList { startIndex, _ in
            startIndex == 0
                ? PagedFetchResult(items: fullPage, totalRecordCount: 0)
                : PagedFetchResult(items: [], totalRecordCount: 0)
        }
        list.reload()
        try await waitUntilLoaded(list)
        XCTAssertTrue(list.hasMore, "总数 0 却返回了满页 → 总数不可信,按满页推断还有下一页")

        list.loadMore()
        try await waitUntil { !list.isLoadingMore }
        XCTAssertEqual(list.items.count, PagedItemList.pageSize)
        XCTAssertFalse(list.hasMore, "下一页为空 → 停止")
    }

    @MainActor
    func testShortPageWithZeroTotalHasNoNextPage() async throws {
        let list = PagedItemList { _, _ in
            PagedFetchResult(items: [Self.item(id: "1", name: "唯一结果")], totalRecordCount: 0)
        }
        list.reload()
        try await waitUntilLoaded(list)

        XCTAssertEqual(list.items.count, 1, "总数为 0 不得把已返回的结果藏掉")
        XCTAssertFalse(list.hasMore)
    }

    // MARK: - generation:切换服务器后旧结果不得落地

    @MainActor
    func testStaleResponseIsDiscardedAfterSwitchingServer() async throws {
        let gate = StallGate()
        let counter = CallCounter()
        let serverAItem = Self.item(id: "A", name: "服务器 A 的电影")
        let serverBItem = Self.item(id: "B", name: "服务器 B 的电影")

        let list = PagedItemList { _, _ in
            let call = await counter.next()
            await gate.wait()
            return call == 1
                ? PagedFetchResult(items: [serverAItem], totalRecordCount: 1)
                : PagedFetchResult(items: [serverBItem], totalRecordCount: 1)
        }

        list.reload()   // 切服务器前的请求,卡在闸门里
        list.reload()   // 切换服务器:generation +1,重新发起

        // 等两个 fetch 都挂上闸门再放行
        for _ in 0..<80 where await gate.waiterCount < 2 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        await gate.release()
        try await waitUntil { !list.items.isEmpty }

        XCTAssertEqual(list.items.map(\.id), ["B"], "旧服务器的晚到响应必须被丢弃")
        let calls = await counter.count
        XCTAssertEqual(calls, 2)
    }

    // MARK: - 手动刷新:保留已显示内容(不闪白屏)

    @MainActor
    func testRefreshKeepsItemsUntilNewPageArrives() async throws {
        let gate = StallGate()
        let counter = CallCounter()
        let list = PagedItemList { _, _ in
            let call = await counter.next()
            if call == 1 {
                return PagedFetchResult(items: [Self.item(id: "old", name: "旧内容")], totalRecordCount: 1)
            }
            await gate.wait()
            return PagedFetchResult(items: [Self.item(id: "new", name: "新内容")], totalRecordCount: 1)
        }
        list.reload()
        try await waitUntil { list.items.map(\.id) == ["old"] }

        list.refresh()
        // 等新请求挂上闸门(此时它还没回来)
        for _ in 0..<80 where await gate.waiterCount < 1 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(list.items.map(\.id), ["old"], "刷新期间不得清空已显示内容")
        XCTAssertTrue(list.isRefreshing)
        XCTAssertTrue(list.isLoading, "刷新中也算「在加载」,工具栏图标要转")
        guard case .loaded = list.state else {
            return XCTFail("刷新期间 state 应保持 .loaded,不能切回 .loading")
        }

        await gate.release()
        try await waitUntil { list.items.map(\.id) == ["new"] }
        XCTAssertFalse(list.isRefreshing)
        XCTAssertFalse(list.isLoading)
    }

    @MainActor
    func testRefreshFailureKeepsExistingItems() async throws {
        let counter = CallCounter()
        let list = PagedItemList { _, _ in
            if await counter.next() == 1 {
                return PagedFetchResult(items: [Self.item(id: "keep", name: "保留")], totalRecordCount: 1)
            }
            throw EmbyAPIError.server(status: 500)
        }
        list.reload()
        try await waitUntil { list.items.map(\.id) == ["keep"] }

        list.refresh()
        try await waitUntil { !list.isRefreshing }

        XCTAssertEqual(list.items.map(\.id), ["keep"], "刷新失败不得清空已显示内容")
        if case .failed = list.state {
            XCTFail("刷新失败不该把整页换成错误态")
        }
    }

    // MARK: - 取消与失败

    @MainActor
    func testCancelledIsNotAnError() async throws {
        let list = PagedItemList { _, _ in throw EmbyAPIError.cancelled }
        list.reload()
        try await Task.sleep(nanoseconds: 50_000_000)

        // 取消是正常流程(API_CONTRACT.md 第 7 节):不得进入失败态
        if case .failed = list.state {
            XCTFail("取消不得显示为错误")
        }
        XCTAssertTrue(list.items.isEmpty)
    }

    @MainActor
    func testServerErrorProducesRetryableFailure() async throws {
        let list = PagedItemList { _, _ in throw EmbyAPIError.server(status: 500) }
        list.reload()
        try await Task.sleep(nanoseconds: 50_000_000)

        guard case .failed(let failure) = list.state else {
            return XCTFail("期望 .failed,实际 \(list.state)")
        }
        XCTAssertFalse(failure.needsLogin)
        XCTAssertEqual(failure.message, EmbyAPIError.server(status: 500).userMessage)
    }

    @MainActor
    func testUnauthorizedFailureAsksForLogin() async throws {
        // 401 的处置是「重新登录」而不是「重试」(API_CONTRACT.md 2.5)
        let list = PagedItemList { _, _ in throw EmbyAPIError.unauthorized }
        list.reload()
        try await Task.sleep(nanoseconds: 50_000_000)

        guard case .failed(let failure) = list.state else {
            return XCTFail("期望 .failed")
        }
        XCTAssertTrue(failure.needsLogin)
    }

    @MainActor
    func testLoadMoreFailureKeepsAlreadyLoadedItems() async throws {
        let list = PagedItemList { startIndex, _ in
            if startIndex == 0 {
                return PagedFetchResult(items: [Self.item(id: "1", name: "第一页")], totalRecordCount: 2)
            }
            throw EmbyAPIError.rateLimited
        }
        list.reload()
        try await waitUntilLoaded(list)
        list.loadMore()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(list.items.count, 1, "翻页失败不得清空已加载的内容")
        XCTAssertNotNil(list.loadMoreFailure)
    }

    // MARK: - 辅助

    @MainActor
    private func makeList() async throws -> PagedItemList {
        let connection = try await makeConnection()
        return PagedItemList { startIndex, limit in
            var query = EmbyItemsQuery()
            query.startIndex = startIndex
            query.limit = limit
            let response = try await connection.items(query)
            return PagedFetchResult(items: response.items, totalRecordCount: response.totalRecordCount)
        }
    }

    @MainActor
    private func makeConnection(userID: String = "USER-1") async throws -> ServerConnection {
        let profile = ServerProfile(
            displayName: "emby.test",
            baseURL: testURL("https://emby.test"),
            apiPathPrefix: "/emby",
            userID: userID,
            username: "testuser",
            deviceID: "DEVICE-UUID-1"
        )
        try await credentials.saveToken("FAKE_TOKEN_0123456789", forServer: profile.id)
        return ServerConnection(profile: profile, credentials: credentials, session: session)
    }

    private func stubItems(_ fixture: String) throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json(fixture)),
            path: "/emby/Users/USER-1/Items"
        )
    }

    @MainActor
    private func waitUntilLoaded(_ list: PagedItemList) async throws {
        try await waitUntil {
            if case .loaded = list.state { return true }
            return false
        }
    }

    /// 轮询等待条件成立(最多 2 秒),避免固定 sleep。
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("等待条件超时")
    }

    private static func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    private static func item(id: String, name: String) -> EmbyItem {
        EmbyItem(
            id: id,
            name: name,
            type: "Movie",
            overview: nil,
            productionYear: nil,
            runTimeTicks: nil,
            indexNumber: nil,
            parentIndexNumber: nil,
            seasonID: nil,
            seriesID: nil,
            seriesName: nil,
            seasonName: nil,
            genres: nil,
            communityRating: nil,
            officialRating: nil,
            imageTags: nil,
            primaryImageTag: nil,
            backdropImageTags: nil,
            parentBackdropItemID: nil,
            parentBackdropImageTags: nil,
            parentLogoItemID: nil,
            parentLogoImageTag: nil,
            parentThumbItemID: nil,
            parentThumbImageTag: nil,
            userData: nil,
            people: nil,
            studios: nil,
            taglines: nil,
            premiereDate: nil,
            childCount: nil,
            criticRating: nil,
            mediaStreams: nil
        )
    }
}
