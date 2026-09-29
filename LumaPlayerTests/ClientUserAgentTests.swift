import XCTest
@testable import LumaPlayer

final class ClientUserAgentTests: XCTestCase {
    func testFormatWithVersion() {
        XCTAssertEqual(ClientUserAgent.format(version: "1.2.3"), "LumaPlayer/1.2.3")
    }

    func testFormatWithoutUsableVersionOmitsVersionSegment() {
        XCTAssertEqual(ClientUserAgent.format(version: nil), "LumaPlayer")
        XCTAssertEqual(ClientUserAgent.format(version: ""), "LumaPlayer")
        XCTAssertEqual(ClientUserAgent.format(version: "版本 1"), "LumaPlayer")
    }

    func testSanitizedStripsControlCharactersAndTrims() {
        XCTAssertEqual(ClientUserAgent.sanitized("  SenPlayer/5.0\n"), "SenPlayer/5.0")
        XCTAssertEqual(ClientUserAgent.sanitized("A\tB\r\nC"), "ABC")
    }

    func testSanitizedEmptyOrBlankIsNil() {
        XCTAssertNil(ClientUserAgent.sanitized(""))
        XCTAssertNil(ClientUserAgent.sanitized(" \n\t "))
    }

    /// 自定义 UA 逐请求读取:填了就带,清空后不带(沿用系统默认)
    func testRequestBuilderCarriesCustomUserAgentPerRequest() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: ClientUserAgent.customKey)
        defer {
            if let saved { defaults.set(saved, forKey: ClientUserAgent.customKey) }
            else { defaults.removeObject(forKey: ClientUserAgent.customKey) }
        }
        let builder = EmbyRequestBuilder(
            baseURL: try XCTUnwrap(URL(string: "https://emby.test")), apiPathPrefix: "/emby",
            deviceID: "DEV", deviceName: "Mac", appVersion: "1.0")
        let endpoint = EmbyEndpoint.publicSystemInfo

        defaults.set("FakePlayer/1.0\n", forKey: ClientUserAgent.customKey)
        XCTAssertEqual(
            try builder.makeRequest(for: endpoint, accessToken: nil, userID: nil)
                .value(forHTTPHeaderField: "User-Agent"),
            "FakePlayer/1.0")
        XCTAssertEqual(ClientUserAgent.value, "FakePlayer/1.0")

        defaults.removeObject(forKey: ClientUserAgent.customKey)
        XCTAssertNil(
            try builder.makeRequest(for: endpoint, accessToken: nil, userID: nil)
                .value(forHTTPHeaderField: "User-Agent"))
    }
}
