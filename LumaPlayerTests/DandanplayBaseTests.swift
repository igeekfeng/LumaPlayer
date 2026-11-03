import XCTest
@testable import LumaPlayer

/// `DandanplayBase` 地址解析 + `DandanplayCredentials` 的自建服务判定。
///
/// 地址是从设置页进来的字符串,解析错一位(尾 `/`、默认端口、带查询串)就会让请求打到
/// 另一个地方 —— 这些分支全部要覆盖。
final class DandanplayBaseTests: XCTestCase {

    // MARK: - 空值 = 官方

    func testEmptyStringMeansOfficial() throws {
        XCTAssertEqual(DandanplayBase(urlString: ""), .official)
        XCTAssertEqual(DandanplayBase(urlString: "   "), .official)
        let official = try XCTUnwrap(DandanplayBase(urlString: ""))
        XCTAssertEqual(official.host, "api.dandanplay.net")
        XCTAssertEqual(official.scheme, "https")
        XCTAssertNil(official.port)
        XCTAssertEqual(official.pathPrefix, "")
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
            "http://h/t?x=1", "http://h/t#frag", "127.0.0.1:9321/tok",
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

    // MARK: - 凭据

    func testCredentialsDetectCustomServer() {
        XCTAssertFalse(DandanplayCredentials(appID: "a", appSecret: "b").usesCustomServer)
        XCTAssertFalse(DandanplayCredentials(appID: "a", appSecret: "b", baseURL: " ").usesCustomServer)
        XCTAssertTrue(DandanplayCredentials(appID: "", appSecret: "", baseURL: "http://h/t").usesCustomServer)
    }

    func testCredentialsEmptyRequiresAllThreeBlank() {
        XCTAssertTrue(DandanplayCredentials(appID: "", appSecret: "").isEmpty)
        XCTAssertTrue(DandanplayCredentials(appID: "", appSecret: "", baseURL: " ").isEmpty)
        XCTAssertFalse(DandanplayCredentials(appID: "", appSecret: "", baseURL: "http://h/t").isEmpty)
        XCTAssertFalse(DandanplayCredentials(appID: "a", appSecret: "", baseURL: "").isEmpty)
        XCTAssertFalse(DandanplayCredentials(appID: "", appSecret: "b", baseURL: "").isEmpty)
    }

    /// 旧凭据文件只有 appID / appSecret,加字段后必须还能解码(⛔ 不能逼用户重填)。
    func testDecodesLegacyCredentialsWithoutBaseURL() throws {
        let data = Data(#"{"appID":"a","appSecret":"b"}"#.utf8)
        let credentials = try JSONDecoder().decode(DandanplayCredentials.self, from: data)
        XCTAssertEqual(credentials.appID, "a")
        XCTAssertEqual(credentials.appSecret, "b")
        XCTAssertEqual(credentials.baseURL, "")
        XCTAssertFalse(credentials.usesCustomServer)
    }

    func testEncodeRoundTripKeepsBaseURL() throws {
        let credentials = DandanplayCredentials(appID: "a", appSecret: "b", baseURL: "http://h/t")
        let data = try JSONEncoder().encode(credentials)
        XCTAssertEqual(try JSONDecoder().decode(DandanplayCredentials.self, from: data), credentials)
    }
}
