import Foundation
import XCTest

@testable import LumaPlayer

/// 搜索源清单的落盘(`ResourceSourceStore`)。
final class ResourceSourceStoreTests: XCTestCase {

    private func temporaryStore() -> (ResourceSourceStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "resource-sources-\(UUID().uuidString).json")
        return (ResourceSourceStore(fileURL: url), url)
    }

    func testEmptyStoreReturnsBuiltInSources() async {
        let (store, _) = temporaryStore()
        let sources = await store.sources()
        XCTAssertEqual(sources, ResourceSourceStore.builtInSources)
    }

    func testRoundTrip() async throws {
        let (store, url) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let sources = [
            ResourceSource(
                id: "a", displayName: "自建", kind: .panSou,
                baseURL: "http://192.168.1.2:8888", note: "NAS"),
            ResourceSource(
                id: "b", displayName: "停用的", kind: .panSou,
                baseURL: "https://b.test", isEnabled: false),
        ]
        try await store.save(sources)

        // 新实例从盘上读,确认真的落了盘
        let reloaded = await ResourceSourceStore(fileURL: url).sources()
        XCTAssertEqual(reloaded, sources)
        let failure = await store.lastLoadFailureDescription()
        XCTAssertNil(failure)
    }

    func testSaveDeduplicatesByID() async throws {
        let (store, url) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let duplicate = [
            ResourceSource(id: "a", displayName: "第一个", kind: .panSou, baseURL: "https://a.test"),
            ResourceSource(id: "a", displayName: "第二个", kind: .panSou, baseURL: "https://b.test"),
        ]
        try await store.save(duplicate)
        let reloaded = await store.sources()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.displayName, "第一个")
    }

    /// 文件损坏时⛔ 不静默当空清单:要能报出原因,否则用户以为源全丢了
    func testCorruptedFileReportsFailure() async throws {
        let (store, url) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("不是 JSON".utf8).write(to: url)

        let sources = await store.sources()
        XCTAssertTrue(sources.isEmpty)
        let failure = await store.lastLoadFailureDescription()
        XCTAssertNotNil(failure)
    }

    func testValidationRejectsBadURL() {
        let source = ResourceSource(
            id: "a", displayName: "坏的", kind: .panSou, baseURL: "not a url")
        XCTAssertNotNil(source.validationFailure)

        let good = ResourceSource(
            id: "b", displayName: "好的", kind: .panSou, baseURL: "https://a.test")
        XCTAssertNil(good.validationFailure)
    }
}
