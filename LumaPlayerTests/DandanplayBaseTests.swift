import XCTest
@testable import LumaPlayer

/// `DandanplayBase` 地址解析 + 弹幕来源配置。
///
/// 地址是从设置页进来的字符串,解析错一位(尾 `/`、默认端口、带查询串)就会让请求打到
/// 另一个地方 —— 这些分支全部要覆盖。
final class DandanplayBaseTests: XCTestCase {

    func testOfficialBase() {
        XCTAssertEqual(DandanplayBase.official.host, "api.dandanplay.net")
        XCTAssertEqual(DandanplayBase.official.scheme, "https")
        XCTAssertNil(DandanplayBase.official.port)
        XCTAssertEqual(DandanplayBase.official.pathPrefix, "")
    }

    // MARK: - 自建服务解析

    func testParsesHostPortAndTokenPrefix() {
        let base = try! XCTUnwrap(DandanplayBase(urlString: "http://127.0.0.1:9321/87654321"))
        XCTAssertEqual(base.scheme, "http")
        XCTAssertEqual(base.host, "127.0.0.1")
        XCTAssertEqual(base.port, 9321)
        XCTAssertEqual(base.pathPrefix, "/87654321")
    }

    /// 尾 `/` 不能让路径前缀变成 `/87654321/`,否则拼出来是双斜杠。
    func testTrailingSlashIsStripped() {
        XCTAssertEqual(try! XCTUnwrap(DandanplayBase(urlString: "http://h:1/")).pathPrefix, "")
        XCTAssertEqual(try! XCTUnwrap(DandanplayBase(urlString: "http://h:1/tok/")).pathPrefix, "/tok")
    }

    /// 默认端口不写进 URL,免得同一服务出现两个地址。
    func testDefaultPortsAreDropped() {
        XCTAssertNil(try! XCTUnwrap(DandanplayBase(urlString: "http://h")).port)
        XCTAssertNil(try! XCTUnwrap(DandanplayBase(urlString: "http://h:80")).port)
        XCTAssertNil(try! XCTUnwrap(DandanplayBase(urlString: "https://h")).port)
        XCTAssertNil(try! XCTUnwrap(DandanplayBase(urlString: "https://h:443")).port)
        XCTAssertEqual(try! XCTUnwrap(DandanplayBase(urlString: "https://h:8443")).port, 8443)
    }

    /// 域名大小写不影响(URL 会归一),但 scheme 大小写要认。
    func testSchemeIsLowercased() {
        XCTAssertEqual(try! XCTUnwrap(DandanplayBase(urlString: "HTTP://h:1/t")).scheme, "http")
    }

    // MARK: - 解析不出来 = nil,不静默回退

    func testUnparseableStringsAreRejected() {
        for bad in [
            "ftp://h/t", "http://", "https:///path", "not a url",
            "http://h/t?x=1", "http://h/t#frag", "127.0.0.1:9321/tok", "", "   ",
        ] {
            XCTAssertNil(DandanplayBase(urlString: bad), "应当拒绝:\(bad)")
        }
    }

    // MARK: - 拼 URL

    func testURLJoinsPrefixPathAndQuery() {
        let base = try! XCTUnwrap(DandanplayBase(urlString: "http://127.0.0.1:9321/87654321"))
        let url = try! XCTUnwrap(base.url(path: "/api/v2/comment/1", percentEncodedQuery: "withRelated=true"))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.port, 9321)
        XCTAssertEqual(url.path, "/87654321/api/v2/comment/1")
        XCTAssertEqual(url.query, "withRelated=true")
    }

    /// 空查询串不能产出 `?`。
    func testEmptyQueryProducesNoQuestionMark() {
        let url = try! XCTUnwrap(DandanplayBase.official.url(path: "/api/v2/bangumi/1", percentEncodedQuery: ""))
        XCTAssertEqual(url.path, "/api/v2/bangumi/1")
        XCTAssertNil(url.query)
    }

    /// 官方地址不带前缀。
    func testOfficialBaseHasNoPrefix() {
        let url = try! XCTUnwrap(DandanplayBase.official.url(path: "/api/v2/match", percentEncodedQuery: ""))
        XCTAssertEqual(url.host, "api.dandanplay.net")
        XCTAssertEqual(url.path, "/api/v2/match")
    }

    // MARK: - 来源配置

    func testSourceSettingsDefaultToOfficial() {
        let empty = DanmakuSourceSettings()
        XCTAssertEqual(empty.sources, [.official])
        XCTAssertEqual(empty.defaultSource, .official)
    }

    func testSourceSettingsListOfficialFirstAndHonorDefault() {
        let custom = DanmakuCustomSource(id: "c1", name: "自建", baseURL: "http://h/t")
        let settings = DanmakuSourceSettings(customSources: [custom], defaultSourceID: "c1")
        XCTAssertEqual(settings.sources.map(\.id), [DanmakuSource.officialID, "c1"])
        XCTAssertEqual(settings.defaultSource, custom.source)
        XCTAssertEqual(custom.source.kind, .custom(baseURL: "http://h/t"))
    }

    /// 默认来源被删后回到官方,⛔ 不能变成「没有来源」。
    func testDanglingDefaultFallsBackToOfficial() {
        XCTAssertEqual(DanmakuSourceSettings(customSources: [], defaultSourceID: "gone").defaultSource, .official)
    }

    func testSourceSettingsRoundTrip() throws {
        let settings = DanmakuSourceSettings(
            customSources: [DanmakuCustomSource(id: "c1", name: "自建", baseURL: "http://h/t")],
            defaultSourceID: "c1")
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(DanmakuSourceSettings.self, from: data), settings)
    }

    func testCredentialsEmptyAndComplete() {
        XCTAssertTrue(DandanplayCredentials(appID: " ", appSecret: "").isEmpty)
        XCTAssertFalse(DandanplayCredentials(appID: "a", appSecret: "").isEmpty)
        XCTAssertFalse(DandanplayCredentials(appID: "a", appSecret: " ").isComplete)
        XCTAssertTrue(DandanplayCredentials(appID: "a", appSecret: "b").isComplete)
    }
}
