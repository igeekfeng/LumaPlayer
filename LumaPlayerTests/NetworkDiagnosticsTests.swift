import XCTest
@testable import LumaPlayer

/// 网络诊断出口(docs/PITFALLS.md Q31)的纯函数部分;日志本身写进系统日志,不在这里断言。
final class NetworkDiagnosticsTests: XCTestCase {
    func testShortBodyIsReturnedAsIs() {
        let body = Data(#"{"Error":"Item not found"}"#.utf8)
        XCTAssertEqual(NetworkDiagnostics.describe(body), #"{"Error":"Item not found"}"#)
    }

    func testEmptyBodyIsCalledOut() {
        XCTAssertEqual(NetworkDiagnostics.describe(Data()), "<empty>")
    }

    /// 只看前半段容易误判「响应就这么多」。
    func testLongBodyIsTruncatedWithTotalLength() {
        let body = Data(repeating: UInt8(ascii: "a"), count: NetworkDiagnostics.bodyLimit + 500)
        let described = NetworkDiagnostics.describe(body)

        XCTAssertTrue(described.hasSuffix("…(共 \(body.count) 字节)"))
        XCTAssertTrue(described.hasPrefix(String(repeating: "a", count: NetworkDiagnostics.bodyLimit)))
        XCTAssertEqual(described.count, NetworkDiagnostics.bodyLimit + "…(共 \(body.count) 字节)".count)
    }

    /// 400/500 可能回 HTML 或二进制;退化成字节数说明,⛔ 不能抛错(诊断自己失败会让排查断线)。
    func testNonUTF8BodyFallsBackToByteCount() {
        let body = Data([0xFF, 0xFE, 0x00])
        XCTAssertEqual(NetworkDiagnostics.describe(body), "<3 bytes, non-UTF8>")
    }

    /// 错误响应会回显请求内容,脱敏在诊断出口要再做一次;换行压平,否则一条日志被拆成多行难以 grep。
    func testBodyIsRedactedAndFlattened() {
        let body = Data("{\"AccessToken\":\"SECRET_LEAK\"}\nsecond line".utf8)
        let described = NetworkDiagnostics.describe(body)

        XCTAssertFalse(described.contains("SECRET_LEAK"))
        XCTAssertTrue(described.contains(SecretRedactor.placeholder))
        XCTAssertFalse(described.contains("\n"))
    }

    // MARK: - JSON 按结构脱敏

    /// 正则取值遇到空格 / 逗号 / 转义引号就停,这类密码必须整值替换。
    func testLoginRequestBodyPasswordIsRedactedWhole() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "Username": "alice",
            "Pw": #"my pass,word "quoted""#,
        ])
        let described = NetworkDiagnostics.describeRequestBody(body)

        XCTAssertEqual(described, #"{"Pw":"<redacted>","Username":"alice"}"#)
    }

    /// 请求体全是 JSON;别的形态不记内容,只记字节数。
    func testNonJSONRequestBodyIsNotPrinted() {
        let body = Data("Pw=my pass,word".utf8)
        XCTAssertEqual(NetworkDiagnostics.describeRequestBody(body), "<15 bytes, non-JSON>")
    }

    func testJSONResponseBodyIsRedactedStructurally() {
        let body = Data(#"""
        {"AccessToken":"abc, def","User":{"Name":"alice"},
         "MediaSources":[{"TranscodingUrl":"/videos/1/master.m3u8?api_key=SECRET&Static=false"}]}
        """#.utf8)
        let described = NetworkDiagnostics.describe(body)

        XCTAssertFalse(described.contains("abc"))
        XCTAssertFalse(described.contains("def"))
        XCTAssertFalse(described.contains("SECRET"))
        XCTAssertTrue(described.contains(#""AccessToken":"<redacted>""#))
        XCTAssertTrue(described.contains(#""Name":"alice""#))
        XCTAssertTrue(described.contains("Static=false"))
        XCTAssertFalse(described.contains("\n"))
    }

    /// 按字节截断会切在多字节字符中间,让中文错误信息被误判成非 UTF-8。
    func testMultibyteBodyIsTruncatedByCharacter() {
        let body = Data(String(repeating: "错", count: NetworkDiagnostics.bodyLimit + 1).utf8)
        let described = NetworkDiagnostics.describe(body)

        XCTAssertTrue(described.hasPrefix(String(repeating: "错", count: NetworkDiagnostics.bodyLimit)))
        XCTAssertTrue(described.hasSuffix("…(共 \(body.count) 字节)"))
    }

    // MARK: - 行格式

    private let fixedDate = Date(timeIntervalSince1970: 0)

    func testHTTPFailureLineCarriesRequestAndResponseBodies() throws {
        let url = try XCTUnwrap(URL(string: "https://emby.test/emby/Items/1/PlaybackInfo?UserId=u&api_key=SECRET"))
        let line = NetworkDiagnostics.line(
            for: .http(status: 400, body: Data("Value cannot be null.".utf8)),
            endpointName: "Items/{Id}/PlaybackInfo",
            method: "POST",
            url: url,
            requestBody: Data(#"{"EnableDirectPlay":false}"#.utf8),
            date: fixedDate
        )

        XCTAssertEqual(line, "1970-01-01T00:00:00Z HTTP 400 POST Items/{Id}/PlaybackInfo host=emby.test "
            + "url=https://emby.test/emby/Items/1/PlaybackInfo?UserId=u&api_key=%3Credacted%3E "
            + #"req={"EnableDirectPlay":false} body=Value cannot be null."#)
    }

    /// 版本差异靠 `DecodingError` 描述(含 codingPath)与响应体定位。
    func testDecodingFailureLineCarriesDetailAndBody() throws {
        let url = try XCTUnwrap(URL(string: "https://emby.test/emby/Shows/NextUp"))
        let line = NetworkDiagnostics.line(
            for: .decoding(
                status: 200,
                detail: "typeMismatch(Int, codingPath: [Items, 0, IndexNumber])\nnext",
                body: Data(#"{"Items":[{"IndexNumber":"1"}]}"#.utf8)
            ),
            endpointName: "Shows/NextUp",
            method: "GET",
            url: url,
            requestBody: nil,
            date: fixedDate
        )

        XCTAssertEqual(line, "1970-01-01T00:00:00Z DECODE HTTP 200 GET Shows/NextUp host=emby.test "
            + "url=https://emby.test/emby/Shows/NextUp "
            + "error=typeMismatch(Int, codingPath: [Items, 0, IndexNumber]) next "
            + #"body={"Items":[{"IndexNumber":"1"}]}"#)
    }

    func testTransportFailureLineHasNoBody() throws {
        let url = try XCTUnwrap(URL(string: "https://emby.test/emby/Shows/NextUp"))
        let line = NetworkDiagnostics.line(
            for: .transport(.timedOut),
            endpointName: "Shows/NextUp",
            method: "GET",
            url: url,
            requestBody: nil,
            date: fixedDate
        )

        XCTAssertEqual(line, "1970-01-01T00:00:00Z TRANSPORT URLError -1001 GET Shows/NextUp "
            + "host=emby.test url=https://emby.test/emby/Shows/NextUp")
    }

    // MARK: - 落盘

    /// 测试跑在宿主 App 进程、共享同一个沙盒容器,成批构造的 4xx/5xx 落盘会顶满 `fileSizeLimit`、冲掉真实排障记录。
    func testRecordDoesNotTouchTheLogFileUnderTests() throws {
        let fileURL = try XCTUnwrap(NetworkDiagnostics.logFileURL)
        let before = (try? String(contentsOf: fileURL, encoding: .utf8))?.count ?? 0

        NetworkDiagnostics.record(
            .http(status: 400, body: Data(#"{"Error":"boom"}"#.utf8)),
            endpointName: "Shows/NextUp",
            method: "GET",
            url: try XCTUnwrap(URL(string: "https://emby.test/emby/Shows/NextUp")),
            requestBody: nil
        )

        let after = (try? String(contentsOf: fileURL, encoding: .utf8))?.count ?? 0
        XCTAssertEqual(before, after, "测试进程不应改动诊断日志文件")
    }

    func testPlaybackFailureLineRedactsSecretsAndKeepsClues() throws {
        let url = try XCTUnwrap(URL(string: "https://emby.example.com/Videos/1/stream?static=true&api_key=SECRET123"))
        let line = NetworkDiagnostics.playbackFailureLine(
            message: "unrecognized file format",
            url: url,
            method: "DirectStream",
            mpvLog: [
                "[ffmpeg] http: Opening 'https://emby.example.com/x?api_key=SECRET123'",
                "[lavf] Failed to recognize file format.\n",
            ],
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertFalse(line.contains("SECRET123"))
        XCTAssertTrue(line.contains("PLAYBACK method=DirectStream host=emby.example.com"))
        XCTAssertTrue(line.contains("mpv=\"unrecognized file format\""))
        XCTAssertTrue(line.contains("Failed to recognize file format."))
        XCTAssertFalse(line.contains("\n"))
    }

    func testPlaybackFailureLineOmitsEmptyLog() throws {
        let url = try XCTUnwrap(URL(string: "https://emby.example.com/a"))
        let line = NetworkDiagnostics.playbackFailureLine(
            message: "m", url: url, method: "Transcode", mpvLog: [])
        XCTAssertFalse(line.contains("mpvlog="))
    }
}
