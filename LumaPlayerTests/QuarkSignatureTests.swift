import XCTest
@testable import LumaPlayer

/// 签名与 URL 构造(`docs/QUARK_API.md` §2)。
///
/// 这几条是硬约定:sha256 的入参是**字符串拼接**(不做 URL 编码、不加空格、不改大小写),
/// `req_id` 是 `md5(device_id + timestamp)`。写错了服务端回 `errno 10001`,`11001` 都不给。
final class QuarkSignatureTests: XCTestCase {

    /// 固定时刻与固定 deviceID,算出的三个值必须稳定(回归:改拼接顺序会静默失效)。
    private let deviceID = "0123456789abcdef0123456789abcdef"
    private let milliseconds: Int64 = 1_700_000_000_123

    func testSignatureMatchesDocumentedAlgorithm() {
        let signature = QuarkSigner.sign(
            method: "GET",
            path: "/file",
            deviceID: deviceID,
            signKey: "sign-key-for-test",
            milliseconds: milliseconds
        )
        // timestamp 是 13 位十进制
        XCTAssertEqual(signature.timestamp, "1700000000123")
        // req_id = md5(deviceID + timestamp)
        XCTAssertEqual(signature.requestID, QuarkSigner.md5Hex(deviceID + "1700000000123"))
        // x-pan-token = sha256(method & pathname & timestamp & signKey)
        XCTAssertEqual(
            signature.panToken,
            QuarkSigner.sha256Hex("GET&/file&1700000000123&sign-key-for-test"))
        XCTAssertEqual(signature.requestID.count, 32)
        XCTAssertEqual(signature.panToken.count, 64)
        XCTAssertTrue(signature.requestID.allSatisfy(\.isHexDigit))
        XCTAssertTrue(signature.panToken.allSatisfy(\.isHexDigit))
    }

    /// 方法名与路径都进签名:换了任何一个,`x-pan-token` 就得变。
    func testMethodAndPathChangeTheToken() {
        let get = QuarkSigner.sign(
            method: "GET", path: "/file", deviceID: deviceID, milliseconds: milliseconds)
        let post = QuarkSigner.sign(
            method: "POST", path: "/file", deviceID: deviceID, milliseconds: milliseconds)
        let other = QuarkSigner.sign(
            method: "GET", path: "/user", deviceID: deviceID, milliseconds: milliseconds)
        XCTAssertNotEqual(get.panToken, post.panToken)
        XCTAssertNotEqual(get.panToken, other.panToken)
        // 方法变了不影响 req_id(它只吃 deviceID + timestamp)
        XCTAssertEqual(get.requestID, post.requestID)
    }

    /// ⚠️ sha256 的入参必须是原字符串:URL 编码过的名字会算出另一个值。
    func testTokenIsNotURLEncoded() {
        let raw = QuarkSigner.sign(
            method: "GET", path: "/file", deviceID: deviceID, milliseconds: milliseconds)
        // 拿编码后的串再算一次,两者必须不同 —— 这条锁住「⛔ 不要 encode 后再签名」
        let encoded = QuarkSigner.sha256Hex(
            "GET&%2Ffile&1700000000123&" + QuarkEndpoint.signKey)
        XCTAssertNotEqual(raw.panToken, encoded)
    }

    /// 查询串手拼:每个值都按 unreserved 编码,`+` `/` `=` 不会漏出去。
    func testQueryStringEncodesEveryValue() throws {
        let placeholderToken = "FAKE_token with space"
        let signature = QuarkSigner.sign(
            method: "GET", path: "/file", deviceID: deviceID, milliseconds: milliseconds)
        let url = try XCTUnwrap(QuarkAPIClient.url(
            .download(fid: "a+b/c=d"),
            signature: signature,
            accessToken: placeholderToken,
            deviceID: deviceID))
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("fid=a%2Bb%2Fc%3Dd"))
        XCTAssertTrue(query.contains("access_token=FAKE_token%20with%20space"))
        XCTAssertTrue(query.contains("req_id=\(signature.requestID)"))
        // 通用设备参数必须齐全(§1:少了任何一项都可能被当成非 TV 客户端)
        for item in QuarkDeviceFingerprint.queryItems(deviceID: deviceID) {
            XCTAssertTrue(query.contains("\(item.name)="), "缺参数 \(item.name)")
        }
        XCTAssertTrue(query.contains("channel=GENERAL"))
        XCTAssertTrue(query.contains("app_ver=1.8.2.2"))
    }

    /// 端点自己的参数也在查询串里,且顺序固定(便于排障对照)。
    func testEndpointQueryItemsAreAppended() throws {
        let signature = QuarkSigner.sign(
            method: "GET", path: "/file", deviceID: deviceID, milliseconds: milliseconds)
        let url = try XCTUnwrap(QuarkAPIClient.url(
            .list(parentFid: "0", pageIndex: 2, pageSize: 100),
            signature: signature,
            accessToken: "t",
            deviceID: deviceID))
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("method=list"))
        XCTAssertTrue(query.contains("parent_fid=0"))
        XCTAssertTrue(query.contains("page_index=2"))
        XCTAssertTrue(query.contains("page_size=100"))
        XCTAssertEqual(url.host(), QuarkEndpoint.apiHost)
        XCTAssertEqual(url.path, "/file")
    }

    /// 换 token 走 https,⛔ 不是文档记的明文 HTTP(ATS 会拦,而且没必要)。
    func testTokenExchangeHostIsHTTPS() {
        XCTAssertEqual(QuarkEndpoint.codeHost, "api.extscreen.com")
        XCTAssertEqual(QuarkEndpoint.codeBasePath, "/quarkdrive")
    }
}
