import XCTest
@testable import LumaPlayer

/// 海报磁盘缓存(API_CONTRACT.md 3.3):纯字节层,临时目录注入。
final class PosterDiskCacheTests: XCTestCase {
    private var directory: URL!
    private var cache: PosterDiskCache!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaPlayerPosterDiskTests-\(UUID().uuidString)", isDirectory: true)
        cache = PosterDiskCache(directory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        cache = nil
        try await super.tearDown()
    }

    // MARK: - Tag 硬规则(API_CONTRACT.md 3.3)

    func testUntaggedSpecIsRefusedForStoreAndLoad() async {
        let spec = ImageSpec(serverID: UUID(), itemID: "ITEM-1", type: .primary, tag: nil, maxWidth: 300)

        await cache.store(Data([0xFF]), for: spec)
        let hit = await cache.data(for: spec)

        XCTAssertNil(hit, "没有 Tag 的图片不得进磁盘缓存(3.3),读也读不到")
    }

    // MARK: - 基础读写

    func testRoundTripAcrossInstances() async {
        let spec = makeSpec(itemID: "ITEM-1", tag: "TAG-1")
        let payload = Data("poster-bytes".utf8)
        await cache.store(payload, for: spec)

        // 模拟重启:同一目录新实例,必须能从磁盘读回
        let reborn = PosterDiskCache(directory: directory)
        let hit = await reborn.data(for: spec)

        XCTAssertEqual(hit, payload)
    }

    func testRewriteSameKeyReplacesEntry() async {
        let spec = makeSpec(itemID: "ITEM-1", tag: "TAG-1")
        await cache.store(Data("old".utf8), for: spec)
        await cache.store(Data("new".utf8), for: spec)

        let hit = await cache.data(for: spec)
        XCTAssertEqual(hit, Data("new".utf8), "同 key 重写必须替换旧内容")
    }

    func testServersAreIsolated() async {
        let serverA = UUID()
        let serverB = UUID()
        let onA = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)
        let onB = ImageSpec(serverID: serverB, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)

        await cache.store(Data("a".utf8), for: onA)
        let hit = await cache.data(for: onB)

        XCTAssertNil(hit, "两台镜像库的服务器不得共享磁盘缓存")
    }

    // MARK: - purge

    func testPurgeRemovesOnlyThatServer() async {
        let serverA = UUID()
        let serverB = UUID()
        let onA = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)
        let onB = ImageSpec(serverID: serverB, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)
        await cache.store(Data("a".utf8), for: onA)
        await cache.store(Data("b".utf8), for: onB)

        await cache.purge(ownerID: serverA)

        let hitA = await cache.data(for: onA)
        let hitB = await cache.data(for: onB)
        XCTAssertNil(hitA, "被 purge 的来源必须清空")
        XCTAssertNotNil(hitB, "其他来源不得陪葬")
    }

    // MARK: - 容量淘汰

    func testByteLimitEvictsOldestFiles() async throws {
        let serverID = UUID()
        let oldest = makeSpec(serverID: serverID, itemID: "oldest", tag: "TAG-1")
        let newest = makeSpec(serverID: serverID, itemID: "newest", tag: "TAG-1")
        let big = Data(repeating: 0x61, count: PosterDiskCache.defaultByteLimit / 2 + 1024)

        await cache.store(big, for: oldest)
        // 拉开两个文件的 mtime,「按最旧淘汰」的顺序才确定
        try await Task.sleep(nanoseconds: 20_000_000)
        await cache.store(big, for: newest)

        let hitOldest = await cache.data(for: oldest)
        let hitNewest = await cache.data(for: newest)
        XCTAssertNil(hitOldest, "超限后最旧的文件必须被淘汰")
        XCTAssertNotNil(hitNewest, "最新的文件必须保留")
    }

    // MARK: - 设置 → 缓存:占用 / 上限 / 清空

    func testUsageCountsBytesAndFiles() async {
        let payload = Data(repeating: 0x62, count: 4096)
        await cache.store(payload, for: makeSpec(itemID: "ITEM-1", tag: "TAG-1"))
        await cache.store(payload, for: makeSpec(itemID: "ITEM-2", tag: "TAG-1"))

        let usage = await cache.usage()

        XCTAssertEqual(usage.fileCount, 2)
        XCTAssertEqual(usage.bytes, payload.count * 2)
    }

    /// 目录还不存在时占用是 0,⛔ 不能卡在「估算中」
    func testUsageIsZeroBeforeAnyStore() async {
        let usage = await cache.usage()

        XCTAssertEqual(usage, .zero)
    }

    func testRemoveAllClearsDiskAndStaysUsable() async {
        let spec = makeSpec(itemID: "ITEM-1", tag: "TAG-1")
        await cache.store(Data("poster-bytes".utf8), for: spec)

        await cache.removeAll()

        let hit = await cache.data(for: spec)
        let usage = await cache.usage()
        XCTAssertNil(hit, "清空后不得还能读到旧文件")
        XCTAssertEqual(usage, .zero, "清空后占用必须归零")

        await cache.store(Data("again".utf8), for: spec)
        let rewritten = await cache.data(for: spec)
        XCTAssertEqual(rewritten, Data("again".utf8), "清空后目录要能自行重建")
    }

    /// 调小上限立即淘汰,不等下一次写盘
    func testLoweringLimitEvictsImmediately() async throws {
        let small = 64 * 1024
        let limited = PosterDiskCache(directory: directory, byteLimit: 1024 * 1024)
        let old = makeSpec(itemID: "old", tag: "TAG-1")
        let new = makeSpec(itemID: "new", tag: "TAG-1")
        let payload = Data(repeating: 0x63, count: 40 * 1024)

        await limited.store(payload, for: old)
        try await Task.sleep(nanoseconds: 20_000_000)
        await limited.store(payload, for: new)
        let before = await limited.usage()
        XCTAssertEqual(before.bytes, payload.count * 2)

        await limited.setByteLimit(small)

        let hitOld = await limited.data(for: old)
        let hitNew = await limited.data(for: new)
        let after = await limited.usage()
        XCTAssertNil(hitOld, "调小上限后最旧的必须先走")
        XCTAssertNotNil(hitNew, "最新的应当留下")
        XCTAssertLessThanOrEqual(after.bytes, small, "调小上限后占用必须落到新上限之内")
    }

    func testRaisingLimitKeepsFiles() async {
        let payload = Data(repeating: 0x64, count: 4096)
        let spec = makeSpec(itemID: "ITEM-1", tag: "TAG-1")
        await cache.store(payload, for: spec)

        await cache.setByteLimit(PosterDiskCache.defaultByteLimit * 4)

        let hit = await cache.data(for: spec)
        XCTAssertEqual(hit, payload)
    }

    // MARK: - 辅助

    private func makeSpec(serverID: UUID = UUID(), itemID: String, tag: String) -> ImageSpec {
        ImageSpec(serverID: serverID, itemID: itemID, type: .primary, tag: tag, maxWidth: 300)
    }
}
