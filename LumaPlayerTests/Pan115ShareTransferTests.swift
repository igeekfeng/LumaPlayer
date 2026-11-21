import XCTest
@testable import LumaPlayer

/// 115 分享转存的端点与解码(`docs/DISCOVERY.md` §4)。
/// 端点与字段名逐字取自 `p115client` 的 `share_snap` / `share_receive`。
final class Pan115ShareTransferTests: XCTestCase {

    // MARK: - 端点形状

    func testShareSnapUsesWebAPIWithExpectedQuery() throws {
        let endpoint = Pan115Endpoint.shareSnap(
            shareCode: "swabc", receiveCode: "4321", cid: "0", limit: 32, offset: 0)
        let url = try XCTUnwrap(endpoint.url)
        XCTAssertEqual(url.host, "webapi.115.com")
        XCTAssertEqual(url.path, "/share/snap")
        XCTAssertEqual(endpoint.method, "GET")
        XCTAssertEqual(
            url.query,
            "share_code=swabc&receive_code=4321&cid=0&limit=32&offset=0")
    }

    /// 转存是 POST + 表单:字段名与 `p115client` 的 `share_receive` 一致,
    /// `file_id` 多个时用逗号分隔。
    func testShareReceivePostsFormWithCommaJoinedFileIDs() throws {
        let endpoint = Pan115Endpoint.shareReceive(
            shareCode: "swabc", receiveCode: "4321", fileIDs: ["1", "2"], cid: "99")
        let url = try XCTUnwrap(endpoint.url)
        XCTAssertEqual(url.host, "webapi.115.com")
        XCTAssertEqual(url.path, "/share/receive")
        XCTAssertEqual(endpoint.method, "POST")
        XCTAssertEqual(endpoint.contentType, "application/x-www-form-urlencoded")
        let body = String(decoding: try XCTUnwrap(endpoint.httpBody), as: UTF8.self)
        XCTAssertEqual(body, "share_code=swabc&receive_code=4321&file_id=1%2C2&cid=99")
    }

    /// 两个转存端点都必须带 115 要的 UA(取链与播放共用同一个,见 `Pan115UserAgent`)
    func testShareEndpointsCarryUserAgent() {
        let snap = Pan115Endpoint.shareSnap(
            shareCode: "a", receiveCode: "", cid: "0", limit: 32, offset: 0)
        let receive = Pan115Endpoint.shareReceive(
            shareCode: "a", receiveCode: "", fileIDs: ["1"], cid: "0")
        XCTAssertEqual(snap.headers["User-Agent"], Pan115UserAgent.value)
        XCTAssertEqual(receive.headers["User-Agent"], Pan115UserAgent.value)
    }

    // MARK: - 解码

    func testDecodesSnapshotWithStringAndNumericIDs() throws {
        // 115 的 id 有时是数字、有时是字符串(老接口的数字 id 超过 Int32)
        let json = """
        {
          "state": true,
          "data": {
            "count": 2,
            "list": [
              {"fid": "3400000000000000001", "n": "仙逆 4K", "s": 123456, "t": 1793603418, "is_dir": 1},
              {"fid": 3400000000000000002, "n": "第01集.mp4", "s": 987654321, "is_dir": 0}
            ]
          }
        }
        """
        let response = try JSONDecoder().decode(
            Pan115ShareSnapResponse.self, from: Data(json.utf8))
        let snapshot = response.snapshot

        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertEqual(snapshot.totalCount, 2)
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(snapshot.entries[0].fileID, "3400000000000000001")
        XCTAssertEqual(snapshot.entries[0].name, "仙逆 4K")
        XCTAssertTrue(snapshot.entries[0].isDirectory)
        // 数字 id 也要能解成字符串
        XCTAssertEqual(snapshot.entries[1].fileID, "3400000000000000002")
        XCTAssertFalse(snapshot.entries[1].isDirectory)
    }

    func testSnapshotWithStateFalseIsUnavailable() throws {
        let json = #"{"state": false, "code": 4100008, "message": "分享已取消"}"#
        let response = try JSONDecoder().decode(
            Pan115ShareSnapResponse.self, from: Data(json.utf8))
        XCTAssertFalse(response.snapshot.isAvailable)
        XCTAssertTrue(response.snapshot.entries.isEmpty)
    }

    /// `state` 缺省时按可用处理:老实例可能不回这个字段
    func testSnapshotWithoutStateIsAvailable() throws {
        let json = #"{"data": {"count": 0, "list": []}}"#
        let response = try JSONDecoder().decode(
            Pan115ShareSnapResponse.self, from: Data(json.utf8))
        XCTAssertTrue(response.snapshot.isAvailable)
    }

    /// 没有 id 的条目要丢掉,⛔ 不能拿空 id 去调转存
    func testEntriesWithoutIDAreDropped() throws {
        let json = """
        {"state": true, "data": {"list": [{"n": "没有 id"}]}}
        """
        let response = try JSONDecoder().decode(
            Pan115ShareSnapResponse.self, from: Data(json.utf8))
        XCTAssertTrue(response.snapshot.entries.isEmpty)
    }
}
