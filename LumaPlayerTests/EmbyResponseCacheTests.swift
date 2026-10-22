import os
import XCTest
@testable import LumaPlayer

/// 规则见 `EmbyResponseCache` 的类型注释。临时目录 + 注入时钟,不污染真实 `~/Library/Caches`。
/// 时钟装在 `OSAllocatedUnfairLock` 里:`now` 是 `@Sendable`,直接捕获可变属性会把非 Sendable 的 XCTestCase 抓进去。
final class EmbyResponseCacheTests: XCTestCase {
    private var directory: URL!
    private var cache: EmbyResponseCache!
    private var clock: OSAllocatedUnfairLock<Date>!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaPlayerCacheTests-\(UUID().uuidString)", isDirectory: true)
        clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
        cache = EmbyResponseCache(directory: directory) { [clock] in clock.withLock { $0 } }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        cache = nil
        clock = nil
        try await super.tearDown()
    }

    // MARK: - 基础读写

    func testFreshHitReturnsStoredData() async {
        let serverID = UUID()
        let payload = Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8)
        let epoch = await cache.currentEpoch(serverID: serverID)
        await cache.store(payload, serverID: serverID, endpoint: .userViews(userID: "USER-1"), epoch: epoch)

        let hit = await cache.freshData(serverID: serverID, endpoint: .userViews(userID: "USER-1"))

        XCTAssertEqual(hit, payload, "TTL 内必须原样命中")
    }

    func testDifferentQueriesDoNotShareEntry() async {
        let serverID = UUID()
        let epoch = await cache.currentEpoch(serverID: serverID)
        await cache.store(Data("a".utf8), serverID: serverID,
                          endpoint: .items(userID: "USER-1", query: makeQuery(limit: 1)), epoch: epoch)

        let other = await cache.freshData(
            serverID: serverID,
            endpoint: .items(userID: "USER-1", query: makeQuery(limit: 2))
        )

        XCTAssertNil(other, "查询参数变了就是另一个 key")
    }

    func testServersAreIsolated() async {
        let serverA = UUID()
        let serverB = UUID()
        let epochA = await cache.currentEpoch(serverID: serverA)
        await cache.store(Data("a".utf8), serverID: serverA,
                          endpoint: .userViews(userID: "USER-1"), epoch: epochA)

        let onB = await cache.freshData(serverID: serverB, endpoint: .userViews(userID: "USER-1"))

        XCTAssertNil(onB, "两台镜像库的服务器不得共享缓存(key 含 serverID)")
    }

    // MARK: - TTL

    func testExpiredEntryIsDropped() async {
        let serverID = UUID()
        let endpoint = EmbyEndpoint.userViews(userID: "USER-1")
        let epoch = await cache.currentEpoch(serverID: serverID)
        await cache.store(Data("x".utf8), serverID: serverID, endpoint: endpoint, epoch: epoch)

        clock.withLock { $0.addTimeInterval(EmbyResponseCache.freshWindow + 1) }
        let hit = await cache.freshData(serverID: serverID, endpoint: endpoint)

        XCTAssertNil(hit, "超过 fresh 窗口必须按 miss 处理")
    }

    // MARK: - epoch 竞态防护

    func testStoreWithStaleEpochIsDropped() async {
        let serverID = UUID()
        let endpoint = EmbyEndpoint.userViews(userID: "USER-1")
        let staleEpoch = await cache.currentEpoch(serverID: serverID)

        // 失效发生在网络请求在途期间:epoch 被顶掉
        await cache.invalidate(serverID: serverID)
        // 旧请求带着失效前的 epoch 写缓存
        await cache.store(Data("stale".utf8), serverID: serverID, endpoint: endpoint, epoch: staleEpoch)

        let hit = await cache.freshData(serverID: serverID, endpoint: endpoint)
        XCTAssertNil(hit, "失效后回来的旧数据不得写进缓存白拿新 TTL")
    }

    // MARK: - 失效

    func testInvalidateClearsMemoryAndDisk() async {
        let serverID = UUID()
        let endpoint = EmbyEndpoint.userViews(userID: "USER-1")
        let epoch = await cache.currentEpoch(serverID: serverID)
        await cache.store(Data("x".utf8), serverID: serverID, endpoint: endpoint, epoch: epoch)

        await cache.invalidate(serverID: serverID)

        let hit = await cache.freshData(serverID: serverID, endpoint: endpoint)
        XCTAssertNil(hit, "invalidate 后内存与磁盘都必须作废")
    }

    func testInvalidateDoesNotTouchOtherServer() async {
        let serverA = UUID()
        let serverB = UUID()
        let endpointA = EmbyEndpoint.userViews(userID: "USER-1")
        let endpointB = EmbyEndpoint.userViews(userID: "USER-1")
        let epochA = await cache.currentEpoch(serverID: serverA)
        let epochB = await cache.currentEpoch(serverID: serverB)
        await cache.store(Data("a".utf8), serverID: serverA, endpoint: endpointA, epoch: epochA)
        await cache.store(Data("b".utf8), serverID: serverB, endpoint: endpointB, epoch: epochB)

        await cache.invalidate(serverID: serverA)

        let onA = await cache.freshData(serverID: serverA, endpoint: endpointA)
        let onB = await cache.freshData(serverID: serverB, endpoint: endpointB)
        XCTAssertNil(onA, "A 自己的条目必须作废")
        XCTAssertEqual(onB, Data("b".utf8), "A 的失效不得牵连 B")
    }

    // MARK: - 磁盘持久化

    func testDiskOutlivesActorInstance() async {
        let serverID = UUID()
        let endpoint = EmbyEndpoint.userViews(userID: "USER-1")
        let payload = Data(#"{"Items":[]}"#.utf8)
        let epoch = await cache.currentEpoch(serverID: serverID)
        await cache.store(payload, serverID: serverID, endpoint: endpoint, epoch: epoch)

        // 模拟重启:同一目录新实例,内存层为空
        let reborn = EmbyResponseCache(directory: directory) { [clock] in clock.withLock { $0 } }
        let hit = await reborn.freshData(serverID: serverID, endpoint: endpoint)

        XCTAssertEqual(hit, payload, "重启后磁盘层必须接住(时间头跨实例可解)")
    }

    func testDiscardRemovesSingleEntry() async {
        let serverID = UUID()
        let views = EmbyEndpoint.userViews(userID: "USER-1")
        let items = EmbyEndpoint.items(userID: "USER-1", query: makeQuery(limit: 1))
        let epoch = await cache.currentEpoch(serverID: serverID)
        await cache.store(Data("v".utf8), serverID: serverID, endpoint: views, epoch: epoch)
        await cache.store(Data("i".utf8), serverID: serverID, endpoint: items, epoch: epoch)

        await cache.discard(serverID: serverID, endpoint: views)

        let viewsHit = await cache.freshData(serverID: serverID, endpoint: views)
        let itemsHit = await cache.freshData(serverID: serverID, endpoint: items)
        XCTAssertNil(viewsHit, "被 discard 的条目必须消失")
        XCTAssertEqual(itemsHit, Data("i".utf8), "同服务器的其他条目不受影响")
    }

    func testMemoryLimitEvictsOldestInsertion() async {
        // 磁盘层必须完全失效才能纯测内存 FIFO:注入「父路径是个文件」的目录,磁盘读写全失败、降级为仅内存
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaPlayerCacheTests-\(UUID().uuidString).file")
        _ = FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: blocker) }
        let memoryOnly = EmbyResponseCache(directory: blocker) { [clock] in clock.withLock { $0 } }

        let serverID = UUID()
        let epoch = await memoryOnly.currentEpoch(serverID: serverID)
        for index in 0...EmbyResponseCache.memoryEntryLimit {
            let endpoint = EmbyEndpoint.item(userID: "USER-1", itemID: String(index))
            await memoryOnly.store(Data("\(index)".utf8), serverID: serverID, endpoint: endpoint, epoch: epoch)
        }

        let oldest = await memoryOnly.freshData(
            serverID: serverID,
            endpoint: .item(userID: "USER-1", itemID: "0")
        )
        let newest = await memoryOnly.freshData(
            serverID: serverID,
            endpoint: .item(userID: "USER-1", itemID: String(EmbyResponseCache.memoryEntryLimit))
        )
        XCTAssertNil(oldest, "磁盘不可用时,最旧的内存条目必须真的被 FIFO 淘汰")
        XCTAssertEqual(newest, Data("\(EmbyResponseCache.memoryEntryLimit)".utf8))
    }

    func testRestoringSameKeyDoesNotEvictItsNewEntry() async {
        // 同上:磁盘不可用,纯测内存 FIFO
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaPlayerCacheTests-\(UUID().uuidString).file")
        _ = FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: blocker) }
        let memoryOnly = EmbyResponseCache(directory: blocker) { [clock] in clock.withLock { $0 } }

        let serverID = UUID()
        let epoch = await memoryOnly.currentEpoch(serverID: serverID)
        let dup = EmbyEndpoint.item(userID: "USER-1", itemID: "dup")
        // 同 key 并发取数的形态:连续 store 两次
        await memoryOnly.store(Data("old".utf8), serverID: serverID, endpoint: dup, epoch: epoch)
        await memoryOnly.store(Data("new".utf8), serverID: serverID, endpoint: dup, epoch: epoch)
        // 再填到恰好满额(不同 key 共 memoryEntryLimit 条),不应触发任何淘汰
        for index in 1..<EmbyResponseCache.memoryEntryLimit {
            let endpoint = EmbyEndpoint.item(userID: "USER-1", itemID: String(index))
            await memoryOnly.store(Data("\(index)".utf8), serverID: serverID, endpoint: endpoint, epoch: epoch)
        }

        let hit = await memoryOnly.freshData(serverID: serverID, endpoint: dup)
        XCTAssertEqual(hit, Data("new".utf8), "重复 store 不得在顺序表留重复 key、导致新条目被 FIFO 误删")
    }

    // MARK: - 磁盘容量淘汰

    func testDiskByteLimitEvictsOldestFiles() async throws {
        let serverID = UUID()
        let epoch = await cache.currentEpoch(serverID: serverID)
        let big = Data(repeating: 0x61, count: EmbyResponseCache.diskByteLimit / 2 + 1024)
        let oldestEndpoint = EmbyEndpoint.item(userID: "USER-1", itemID: "oldest")
        await cache.store(big, serverID: serverID, endpoint: oldestEndpoint, epoch: epoch)
        // 拉开两个文件的 mtime(磁盘淘汰按真实 mtime 排序)
        try await Task.sleep(nanoseconds: 20_000_000)
        // 第二个大文件让总量超限,最旧的(时间戳更早的)应被淘汰
        clock.withLock { $0.addTimeInterval(60) }
        let newestEndpoint = EmbyEndpoint.item(userID: "USER-1", itemID: "newest")
        await cache.store(big, serverID: serverID, endpoint: newestEndpoint, epoch: epoch)

        // 新实例 = 空内存:原实例的内存层会无条件命中,测不到磁盘淘汰
        let reader = EmbyResponseCache(directory: directory) { [clock] in clock.withLock { $0 } }
        let oldest = await reader.freshData(serverID: serverID, endpoint: oldestEndpoint)
        let newest = await reader.freshData(serverID: serverID, endpoint: newestEndpoint)

        XCTAssertNil(oldest, "超限后最旧的文件必须被淘汰")
        XCTAssertNotNil(newest, "最新的文件必须保留")
    }

    // MARK: - 辅助

    private func makeQuery(limit: Int) -> EmbyItemsQuery {
        var query = EmbyItemsQuery()
        query.limit = limit
        return query
    }
}
