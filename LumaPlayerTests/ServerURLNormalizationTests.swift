import XCTest
@testable import LumaPlayer

/// URL 规范化测试:API_CONTRACT.md 1.3 必测用例表(12 条)+ 补充边界。
final class ServerURLNormalizationTests: XCTestCase {

    // MARK: - 1.3 必测用例表

    func testInfersHTTPSWhenSchemeMissing() throws {
        let result = try normalizeServerURL("example.com")
        XCTAssertEqual(result.url.absoluteString, "https://example.com")
        XCTAssertTrue(result.schemeWasInferred)
    }

    func testTrimsWhitespace() throws {
        let result = try normalizeServerURL("  http://example.com/  ")
        XCTAssertEqual(result.url.absoluteString, "http://example.com")
        XCTAssertFalse(result.schemeWasInferred)
    }

    func testDropsHTTPSDefaultPort() throws {
        let result = try normalizeServerURL("https://example.com:443")
        XCTAssertEqual(result.url.absoluteString, "https://example.com")
        XCTAssertFalse(result.schemeWasInferred)
    }

    func testDropsHTTPDefaultPortAndTrailingSlash() throws {
        let result = try normalizeServerURL("http://example.com:80/")
        XCTAssertEqual(result.url.absoluteString, "http://example.com")
        XCTAssertFalse(result.schemeWasInferred)
    }

    func testStripsEmbySuffix() throws {
        let result = try normalizeServerURL("https://example.com/emby")
        XCTAssertEqual(result.url.absoluteString, "https://example.com")
        XCTAssertFalse(result.schemeWasInferred)
    }

    func testStripsEmbySuffixCaseInsensitive() throws {
        let result = try normalizeServerURL("https://example.com/EMBY/")
        XCTAssertEqual(result.url.absoluteString, "https://example.com")
        XCTAssertFalse(result.schemeWasInferred)
    }

    func testKeepsSubpathBeforeEmby() throws {
        // 反向代理子路径保留,只剥 /emby 段(API_CONTRACT.md 1.2 表第 4 行)
        let result = try normalizeServerURL("https://example.com/media/emby/")
        XCTAssertEqual(result.url.absoluteString, "https://example.com/media")
        XCTAssertFalse(result.schemeWasInferred)
    }

    func testDropsQueryAndFragment() throws {
        let result = try normalizeServerURL("https://example.com/?x=1#y")
        XCTAssertEqual(result.url.absoluteString, "https://example.com")
        XCTAssertFalse(result.schemeWasInferred)
    }

    func testInfersHTTPSForBareIPWithPort() throws {
        // 自用 Emby 最常见形态:不带 scheme 的 IP:端口
        let result = try normalizeServerURL("192.168.1.10:8096")
        XCTAssertEqual(result.url.absoluteString, "https://192.168.1.10:8096")
        XCTAssertTrue(result.schemeWasInferred)
    }

    func testKeepsExplicitHTTPForIPWithPort() throws {
        let result = try normalizeServerURL("http://192.168.1.10:8096")
        XCTAssertEqual(result.url.absoluteString, "http://192.168.1.10:8096")
        XCTAssertFalse(result.schemeWasInferred)
    }

    func testRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try normalizeServerURL("ftp://example.com")) { error in
            XCTAssertEqual(error as? ServerURLError, .unsupportedScheme)
        }
    }

    func testRejectsEmptyHost() {
        // ⚠️ 实现陷阱(API_CONTRACT.md 1.3):URLComponents(string: "https://")
        // 的 host 是空字符串 "" 而不是 nil,guard let host 会放过它
        XCTAssertThrowsError(try normalizeServerURL("https://")) { error in
            XCTAssertEqual(error as? ServerURLError, .missingHost)
        }
    }

    // MARK: - 补充边界

    func testLowercasesHost() throws {
        let result = try normalizeServerURL("https://EXAMPLE.Media.Foo")
        XCTAssertEqual(result.url.absoluteString, "https://example.media.foo")
        XCTAssertFalse(result.schemeWasInferred)
    }

    func testRejectsMalformed() {
        XCTAssertThrowsError(try normalizeServerURL("not a url")) { error in
            XCTAssertEqual(error as? ServerURLError, .malformed)
        }
    }

    func testRejectsEmptyInputAsMissingHost() throws {
        // 空串 → 补 scheme 后为 "https://" → 与必测用例最后一条同因
        XCTAssertThrowsError(try normalizeServerURL("   ")) { error in
            XCTAssertEqual(error as? ServerURLError, .missingHost)
        }
    }

    func testStripsUserInfo() throws {
        // ARCHITECTURE.md 8.1:密码不做本地持久化 → 剥 userinfo
        let result = try normalizeServerURL("https://user:pass@example.com")
        XCTAssertEqual(result.url.absoluteString, "https://example.com")
        XCTAssertFalse(result.schemeWasInferred)
    }

    func testNonDefaultPortIsKept() throws {
        // https + 8096 不是默认端口 → 保留
        let result = try normalizeServerURL("https://example.com:8096")
        XCTAssertEqual(result.url.absoluteString, "https://example.com:8096")
    }
}
