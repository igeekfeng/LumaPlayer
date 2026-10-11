import XCTest
@testable import LumaPlayer

/// 图片描述符:缓存 key 的稳定性与「能不能进磁盘缓存」。
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

    /// 没有 tag 的 Emby 图不进磁盘缓存(`API_CONTRACT.md` 3.3:
    /// key 不含版本就可能把旧图当新图端出来)。
    func testEmbyDescriptorWithoutTagIsNotDiskCacheable() {
        let spec = ImageSpec(
            serverID: UUID(), itemID: "IT", type: .primary, tag: nil, maxWidth: 300)

        XCTAssertFalse(ImageDescriptor.emby(spec).isDiskCacheable)
    }

    /// 远端图(百度封面)自带版本 —— 版本由 `baiduCoverKey` 编进去,所以可以缓存。
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

    /// ★ 换了封面 → `server_mtime` 变 → key 变 → 不会再端出旧图。
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

    /// 拿不到 mtime 时 key 仍要**稳定** —— 否则每次都是新 key,缓存等于没有。
    func testBaiduCoverKeyIsStableWithoutModifiedTime() {
        let sourceID = UUID()
        let first = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42, modifiedAt: nil, maxWidth: 400)
        let second = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42, modifiedAt: nil, maxWidth: 400)

        XCTAssertEqual(first, second)
    }

    /// ⛔ 缓存 key 里**不能**出现临时地址:百度 `dlink` 8 小时就过期,
    /// 一旦编进 key,同一张图每 8 小时就会被当成新图重新下载
    /// (`docs/BAIDU_PAN_API.md` §2.2)。
    func testBaiduCoverKeyDoesNotContainAnythingTemporary() {
        let sourceID = UUID()
        let key = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42, modifiedAt: nil, maxWidth: 400)

        XCTAssertFalse(key.contains("d.pcs.baidu.com"), "临时域名不能进 key")
        XCTAssertFalse(key.contains("sign"), "签名不能进 key")
        XCTAssertTrue(key.contains("42"), "内容 id 要在 key 里")
        XCTAssertTrue(key.contains(sourceID.uuidString), "来源 id 要在 key 里,否则两个来源会串图")
    }

    /// 不同尺寸是不同条目(`ImageSpec.cacheKey` 同一条规则)
    func testBaiduCoverKeyVariesWithMaxWidth() {
        let sourceID = UUID()
        let small = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42, modifiedAt: nil, maxWidth: 200)
        let large = ImageDescriptor.baiduCoverKey(
            sourceID: sourceID, fsID: 42, modifiedAt: nil, maxWidth: 600)

        XCTAssertNotEqual(small, large)
    }
}
