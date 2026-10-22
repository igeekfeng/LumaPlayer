import XCTest
@testable import LumaPlayer

final class ImageDescriptorTests: XCTestCase {

    func testEmbyDescriptorReusesSpecKeyAndOwner() {
        let serverID = UUID()
        let spec = ImageSpec(
            serverID: serverID, itemID: "IT", type: .primary, tag: "TAG-1", maxWidth: 300)

        let descriptor = ImageDescriptor.emby(spec)

        XCTAssertEqual(descriptor.cacheKey, spec.cacheKey, "Emby 通路不该换一套 key 规则")
        XCTAssertEqual(descriptor.ownerID, serverID)
        XCTAssertTrue(descriptor.isDiskCacheable)
    }

    /// key 不含版本就可能把旧图当新图端出来(`API_CONTRACT.md` 3.3)。
    func testEmbyDescriptorWithoutTagIsNotDiskCacheable() {
        let spec = ImageSpec(
            serverID: UUID(), itemID: "IT", type: .primary, tag: nil, maxWidth: 300)

        XCTAssertFalse(ImageDescriptor.emby(spec).isDiskCacheable)
    }

    /// 版本由 `baiduCoverKey` 编进 key。
    func testRemoteDescriptorIsDiskCacheable() throws {
        let descriptor = ImageDescriptor.remote(
            ownerID: UUID(),
            url: try XCTUnwrap(URL(string: "https://d.pcs.baidu.com/file/x")),
            headers: [:],
            cacheKey: "k"
        )

        XCTAssertTrue(descriptor.isDiskCacheable)
    }

    // MARK: - 百度封面 key

    func testBaiduCoverKeyChangesWithModifiedTime() {
        let sourceID = UUID()
        let before = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42,
            modifiedAt: Date(timeIntervalSince1970: 1000), maxWidth: 400)
        let after = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42,
            modifiedAt: Date(timeIntervalSince1970: 2000), maxWidth: 400)

        XCTAssertNotEqual(before, after)
    }

    /// 否则每次都是新 key,缓存等于没有。
    func testBaiduCoverKeyIsStableWithoutModifiedTime() {
        let sourceID = UUID()
        let first = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42, modifiedAt: nil, maxWidth: 400)
        let second = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42, modifiedAt: nil, maxWidth: 400)

        XCTAssertEqual(first, second)
    }

    /// ⛔ key 里不能有临时地址:`dlink` 8 小时过期,编进 key 就会被当成新图重下(`docs/BAIDU_PAN_API.md` §2.2)。
    func testBaiduCoverKeyDoesNotContainAnythingTemporary() {
        let sourceID = UUID()
        let key = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42, modifiedAt: nil, maxWidth: 400)

        XCTAssertFalse(key.contains("d.pcs.baidu.com"), "临时域名不能进 key")
        XCTAssertFalse(key.contains("sign"), "签名不能进 key")
        XCTAssertTrue(key.contains("42"), "内容 id 要在 key 里")
        XCTAssertTrue(key.contains(sourceID.uuidString), "来源 id 要在 key 里,否则两个来源会串图")
    }

    /// 与 `ImageSpec.cacheKey` 同一条规则
    func testBaiduCoverKeyVariesWithMaxWidth() {
        let sourceID = UUID()
        let small = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42, modifiedAt: nil, maxWidth: 200)
        let large = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42, modifiedAt: nil, maxWidth: 600)

        XCTAssertNotEqual(small, large)
    }
}
