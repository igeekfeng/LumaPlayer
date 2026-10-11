import XCTest
@testable import LumaPlayer

/// 请求构造:URL 拼接、认证头格式、token 头、body 字段名
/// (API_CONTRACT.md 1.2、2.1、2.2)。
final class EmbyRequestBuilderTests: XCTestCase {
    private func makeBuilder(
        baseURL: String = "https://emby.test",
        prefix: String = "/emby"
    ) -> EmbyRequestBuilder {
        EmbyRequestBuilder(
            baseURL: testURL(baseURL),
            apiPathPrefix: prefix,
            deviceID: "DEVICE-UUID-1",
            deviceName: "Mac",
            appVersion: "1.2.3"
        )
    }

    // MARK: - Authorization 头(写错这里是最高频的失败原因)

    func testAnonymousHeaderOmitsUserIDSegment() {
        // API_CONTRACT.md 2.1:未登录时省略整段 UserId,不要写成空字符串
        let value = makeBuilder().authorizationHeaderValue(userID: nil)
        XCTAssertEqual(
            value,
            "Emby Client=\"LumaPlayer\", Device=\"Mac\", DeviceId=\"DEVICE-UUID-1\", Version=\"1.2.3\""
        )
    }

    func testAuthenticatedHeaderPutsUserIDFirst() {
        let value = makeBuilder().authorizationHeaderValue(userID: "USER-1")
        XCTAssertTrue(value.hasPrefix("Emby UserId=\"USER-1\", Client=\"LumaPlayer\","), value)
        XCTAssertFalse(value.contains("UserId=\"\""), value)
    }

    func testEmptyUserIDIsTreatedAsAnonymous() {
        let value = makeBuilder().authorizationHeaderValue(userID: "")
        XCTAssertFalse(value.contains("UserId"), value)
    }

    func testNonASCIIDeviceNameFallsBackToMac() {
        // 中文机器名:清洗后为空 → 回退 Mac(API_CONTRACT.md 2.1)
        let builder = EmbyRequestBuilder(
            baseURL: testURL("https://emby.test"),
            deviceID: "DEVICE-UUID-1",
            deviceName: "小柚的 MacBook",
            appVersion: "1.2.3"
        )
        let value = builder.authorizationHeaderValue(userID: nil)
        XCTAssertTrue(value.contains("Device=\"Mac\""), value)
    }

    func testQuotesAndBackslashesAreStripped() {
        let builder = EmbyRequestBuilder(
            baseURL: testURL("https://emby.test"),
            deviceID: "DEVICE-UUID-1",
            deviceName: "Mac\"Book\\Pro",
            appVersion: "1.2.3"
        )
        let value = builder.authorizationHeaderValue(userID: nil)
        XCTAssertTrue(value.contains("Device=\"MacBookPro\""), value)
    }

    // MARK: - URL 拼接

    func testPathPrefixAndEndpointAreJoined() throws {
        let request = try makeBuilder().makeRequest(
            for: .publicSystemInfo, accessToken: nil, userID: nil
        )
        XCTAssertEqual(request.url?.absoluteString, "https://emby.test/emby/System/Info/Public")
    }

    func testEmptyPrefixKeepsReverseProxySubpath() throws {
        let request = try makeBuilder(
            baseURL: "https://emby.test/media",
            prefix: ""
        ).makeRequest(for: .publicSystemInfo, accessToken: nil, userID: nil)
        XCTAssertEqual(request.url?.absoluteString, "https://emby.test/media/System/Info/Public")
    }

    func testSubpathPlusEmbyPrefix() throws {
        let request = try makeBuilder(
            baseURL: "https://emby.test/media",
            prefix: "/emby"
        ).makeRequest(for: .publicSystemInfo, accessToken: nil, userID: nil)
        XCTAssertEqual(request.url?.absoluteString, "https://emby.test/media/emby/System/Info/Public")
    }

    func testUserViewsPathEmbedsUserID() throws {
        let request = try makeBuilder().makeRequest(
            for: .userViews(userID: "USER-1"), accessToken: "T", userID: "USER-1"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://emby.test/emby/Users/USER-1/Views")
    }

    // MARK: - token 头

    func testTokenGoesToItsOwnHeader() throws {
        let request = try makeBuilder().makeRequest(
            for: .systemInfo, accessToken: "TOKEN-X", userID: "USER-1"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "TOKEN-X")
        // ⛔ token 不得出现在 Authorization 里(API_CONTRACT.md 2.2)
        let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(auth.contains("TOKEN-X"), auth)
    }

    func testNoTokenHeaderWhenAnonymous() throws {
        let request = try makeBuilder().makeRequest(
            for: .publicSystemInfo, accessToken: nil, userID: nil
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Emby-Token"))
    }

    // MARK: - 登录 body

    func testAuthenticateBodyFieldNames() throws {
        let request = try makeBuilder().makeRequest(
            for: .authenticateByName(username: "alice", password: "secret"),
            accessToken: nil,
            userID: nil
        )
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        // 字段名即 API_CONTRACT.md 3.1 的拼写(`Pw` 是 🔶,见 docs/PITFALLS.md Q10)
        XCTAssertEqual(object["Username"], "alice")
        XCTAssertEqual(object["Pw"], "secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testGETRequestsHaveNoBody() throws {
        let request = try makeBuilder().makeRequest(
            for: .publicSystemInfo, accessToken: nil, userID: nil
        )
        XCTAssertNil(request.httpBody)
    }
}

/// 测试用 URL 构造(不用 `!`:URL(string:) 的可选性不该在测试里被抹掉)。
func testURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
        XCTFail("测试 URL 无法构造:\(string)")
        return URL(fileURLWithPath: "/")
    }
    return url
}
