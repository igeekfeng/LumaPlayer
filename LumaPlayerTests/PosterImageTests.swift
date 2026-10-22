import AppKit
import XCTest
@testable import LumaPlayer

/// 计数用的图片加载器替身(actor)。
private actor CountingImageLoader: ImageDataLoading {
    private(set) var callCount = 0
    private let payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    func data(for spec: ImageSpec) async throws -> Data {
        callCount += 1
        return payload
    }
}

/// 海报内存缓存:key 必须含 `Tag` 与服务器(两台共享媒体库的服务器 item id 可能相同,API_CONTRACT.md 3.3)。
final class PosterImageTests: XCTestCase {
    private let serverA = UUID()
    private let serverB = UUID()
    private var diskDirectory: URL!

    override func setUp() {
        super.setUp()
        diskDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaPlayerPosterStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: diskDirectory)
        diskDirectory = nil
        try await super.tearDown()
    }

    @MainActor
    func testRepeatedRequestHitsCache() async throws {
        let loader = CountingImageLoader(payload: try makeImageData())
        let store = PosterImageStore(loader: loader)
        let spec = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)

        _ = try await store.image(for: spec)
        _ = try await store.image(for: spec)

        let calls = await loader.callCount
        XCTAssertEqual(calls, 1, "第二次必须命中内存缓存")
        XCTAssertTrue(store.isCached(spec))
    }

    @MainActor
    func testDifferentTagsDoNotShareCacheEntry() async throws {
        let loader = CountingImageLoader(payload: try makeImageData())
        let store = PosterImageStore(loader: loader)
        let first = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)
        let second = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-2", maxWidth: 300)

        _ = try await store.image(for: first)
        _ = try await store.image(for: second)

        let calls = await loader.callCount
        XCTAssertEqual(calls, 2, "Tag 变了就是另一张图(API_CONTRACT.md 3.3)")
    }

    @MainActor
    func testSameItemOnAnotherServerDoesNotShareCacheEntry() async throws {
        // 两台服务器镜像同一套媒体库:item id 与 tag 都一样,只有 serverID 不同
        let loader = CountingImageLoader(payload: try makeImageData())
        let store = PosterImageStore(loader: loader)
        let onA = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)
        let onB = ImageSpec(serverID: serverB, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)

        _ = try await store.image(for: onA)
        _ = try await store.image(for: onB)

        let calls = await loader.callCount
        XCTAssertEqual(calls, 2, "换服务器不得复用另一台的图片缓存")
    }

    @MainActor
    func testUndecodablePayloadThrows() async throws {
        let loader = CountingImageLoader(payload: Data([0x00, 0x01, 0x02]))
        let store = PosterImageStore(loader: loader)
        let spec = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)

        do {
            _ = try await store.image(for: spec)
            XCTFail("解不出 NSImage 必须抛错,不能静默返回空图")
        } catch let error as PosterImageError {
            XCTAssertEqual(error, .undecodableImage)
        }
        XCTAssertFalse(store.isCached(spec), "失败结果不得进缓存")
    }

    @MainActor
    func testClearCacheDropsEverything() async throws {
        let loader = CountingImageLoader(payload: try makeImageData())
        let store = PosterImageStore(loader: loader)
        let spec = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)

        _ = try await store.image(for: spec)
        store.clearCache()
        _ = try await store.image(for: spec)

        let calls = await loader.callCount
        XCTAssertEqual(calls, 2)
    }

    // MARK: - 磁盘层与 LRU

    @MainActor
    func testDiskHitAvoidsNetwork() async throws {
        let disk = PosterDiskCache(directory: diskDirectory)
        let loader = CountingImageLoader(payload: try makeImageData())
        let spec = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)

        let first = PosterImageStore(loader: loader, disk: disk)
        _ = try await first.image(for: spec)
        let afterFirst = await loader.callCount

        // 新 store 内存为空,应由磁盘接住、不发网络
        let second = PosterImageStore(loader: loader, disk: disk)
        _ = try await second.image(for: spec)
        let afterSecond = await loader.callCount

        XCTAssertEqual(afterFirst, 1)
        XCTAssertEqual(afterSecond, 1, "磁盘命中不得再走网络")
    }

    @MainActor
    func testConcurrentRequestsWithDiskShareOneNetworkRequest() async throws {
        let disk = PosterDiskCache(directory: diskDirectory)
        let loader = CountingImageLoader(payload: try makeImageData())
        let spec = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)
        let store = PosterImageStore(loader: loader, disk: disk)

        // 磁盘未命中时,读磁盘的挂起点不得让第二个调用绕过 inFlight 合并
        async let first = store.image(for: spec)
        async let second = store.image(for: spec)
        _ = try await (first, second)

        let calls = await loader.callCount
        XCTAssertEqual(calls, 1, "同 key 并发请求必须合并为一次网络请求")
    }

    @MainActor
    func testNetworkSuccessWritesToDisk() async throws {
        let disk = PosterDiskCache(directory: diskDirectory)
        let loader = CountingImageLoader(payload: try makeImageData())
        let spec = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)
        let store = PosterImageStore(loader: loader, disk: disk)

        _ = try await store.image(for: spec)
        guard let onDisk = await disk.data(for: spec) else {
            return XCTFail("网络成功后必须落盘")
        }
        XCTAssertNotNil(NSImage(data: onDisk), "落盘的字节必须还能解回图片")
    }

    @MainActor
    func testMemoryLRUEvictsLeastRecentlyUsed() async throws {
        let loader = CountingImageLoader(payload: try makeImageData())
        // 不注入磁盘层:纯测内存 LRU
        let store = PosterImageStore(loader: loader)
        for index in 0..<PosterImageStore.cacheLimit {
            let spec = ImageSpec(serverID: serverA, itemID: "ITEM-\(index)", type: .primary, tag: "TAG-\(index)", maxWidth: 300)
            _ = try await store.image(for: spec)
        }
        // 访问最旧的:它变成「最近使用」,淘汰对象变成第二个
        let oldest = ImageSpec(serverID: serverA, itemID: "ITEM-0", type: .primary, tag: "TAG-0", maxWidth: 300)
        _ = try await store.image(for: oldest)
        // 插入第 301 条:LRU 淘汰的必须是 ITEM-1(最久未用的)
        let extra = ImageSpec(serverID: serverA, itemID: "ITEM-EXTRA", type: .primary, tag: "TAG-EXTRA", maxWidth: 300)
        _ = try await store.image(for: extra)

        let second = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)
        XCTAssertTrue(store.isCached(oldest), "刚访问过的条目不得被 LRU 淘汰")
        XCTAssertFalse(store.isCached(second), "最久未用的条目必须被 LRU 淘汰")
    }

    @MainActor
    func testPurgeDiskDropsServerImages() async throws {
        let disk = PosterDiskCache(directory: diskDirectory)
        let loader = CountingImageLoader(payload: try makeImageData())
        let spec = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)
        let store = PosterImageStore(loader: loader, disk: disk)
        _ = try await store.image(for: spec)
        // 清掉内存,只留磁盘层
        store.clearCache()

        await store.purgeDisk(ownerID: serverA)

        _ = try await store.image(for: spec)
        let calls = await loader.callCount
        XCTAssertEqual(calls, 2, "磁盘被 purge 后必须重新走网络")
    }

    // MARK: - 设置 → 缓存

    @MainActor
    func testDiskUsageReflectsStoredImages() async throws {
        let disk = PosterDiskCache(directory: diskDirectory)
        let payload = try makeImageData()
        let store = PosterImageStore(loader: CountingImageLoader(payload: payload), disk: disk)
        let spec = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)

        _ = try await store.image(for: spec)

        let usage = await store.diskUsage()
        XCTAssertEqual(usage?.fileCount, 1)
        XCTAssertEqual(usage?.bytes, payload.count)
    }

    /// nil = 没有磁盘层(设置页不显示数字),不是 0
    @MainActor
    func testDiskUsageIsNilWithoutDiskLayer() async throws {
        let store = PosterImageStore(loader: CountingImageLoader(payload: try makeImageData()))
        let usage = await store.diskUsage()
        XCTAssertNil(usage)
    }

    @MainActor
    func testClearAllDropsMemoryAndDisk() async throws {
        let disk = PosterDiskCache(directory: diskDirectory)
        let loader = CountingImageLoader(payload: try makeImageData())
        let store = PosterImageStore(loader: loader, disk: disk)
        let spec = ImageSpec(serverID: serverA, itemID: "ITEM-1", type: .primary, tag: "TAG-1", maxWidth: 300)
        _ = try await store.image(for: spec)

        await store.clearAll()

        XCTAssertFalse(store.isCached(spec), "内存层必须清空")
        let onDisk = await disk.data(for: spec)
        XCTAssertNil(onDisk, "磁盘层必须清空")
        let usage = await store.diskUsage()
        XCTAssertEqual(usage?.fileCount, 0)

        _ = try await store.image(for: spec)
        let calls = await loader.callCount
        XCTAssertEqual(calls, 2, "清空后再取同一张图必须重新走网络")
    }

    @MainActor
    func testSetDiskByteLimitThroughStore() async throws {
        let disk = PosterDiskCache(directory: diskDirectory)
        let store = PosterImageStore(loader: CountingImageLoader(payload: try makeImageData()), disk: disk)

        await store.setDiskByteLimit(512 * 1024 * 1024)

        let limit = await disk.byteLimit
        XCTAssertEqual(limit, 512 * 1024 * 1024)
    }

    // MARK: - 辅助

    /// 造一张能解回 `NSImage` 的图(TIFF,AppKit 原生支持)。
    @MainActor
    private func makeImageData() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return try XCTUnwrap(image.tiffRepresentation)
    }
}
