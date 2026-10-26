import XCTest
@testable import LumaPlayer

/// 网络诊断出口(docs/PITFALLS.md Q31)。
///
/// 这里只测纯函数部分(`describe` / `describeRequestBody` / `line(for:)`)——
/// 日志本身写进系统日志,不在这里断言。边界要覆盖:截断、非 UTF-8、敏感字段,
/// 以及三类失败各自的行格式。
final class NetworkDiagnosticsTests: XCTestCase {
    func testShortBodyIsReturnedAsIs() {
        let body = Data(#"{"Error":"Item not found"}"#.utf8)
        XCTAssertEqual(NetworkDiagnostics.describe(body), #"{"Error":"Item not found"}"#)
    }

    func testEmptyBodyIsCalledOut() {
        XCTAssertEqual(NetworkDiagnostics.describe(Data()), "<empty>")
    }

    /// 超过上限时截断,并在尾部说明总长度 —— 只看前半段容易误判「响应就这么多」。
    func testLongBodyIsTruncatedWithTotalLength() {
        let body = Data(repeating: UInt8(ascii: "a"), count: NetworkDiagnostics.bodyLimit + 500)
        let described = NetworkDiagnostics.describe(body)

        XCTAssertTrue(described.hasSuffix("…(共 \(body.count) 字节)"))
        XCTAssertTrue(described.hasPrefix(String(repeating: "a", count: NetworkDiagnostics.bodyLimit)))
        XCTAssertEqual(described.count, NetworkDiagnostics.bodyLimit + "…(共 \(body.count) 字节)".count)
    }

    /// 服务端 400/500 时可能回 HTML 错误页或二进制,不能假定是 UTF-8。
    /// 此时退化成字节数说明,**不能抛错** —— 诊断代码自己失败会让排查断线。
    func testNonUTF8BodyFallsBackToByteCount() {
        let body = Data([0xFF, 0xFE, 0x00])
        XCTAssertEqual(NetworkDiagnostics.describe(body), "<3 bytes, non-UTF8>")
    }

    /// 错误响应有时会回显请求内容,凭据脱敏必须在诊断出口再做一次;
    /// 换行同时要压平,否则一条日志会被拆成多行、难以 grep。
    func testBodyIsRedactedAndFlattened() {
        let body = Data("{\"AccessToken\":\"SECRET_LEAK\"}\nsecond line".utf8)
        let described = NetworkDiagnostics.describe(body)

        XCTAssertFalse(described.contains("SECRET_LEAK"))
        XCTAssertTrue(described.contains(SecretRedactor.placeholder))
        XCTAssertFalse(described.contains("\n"))
    }

    // MARK: - JSON 按结构脱敏

    /// 正则取值遇到空格 / 逗号 / 转义引号就停,这类密码必须整值替换,一个字符都不能漏。
    func testLoginRequestBodyPasswordIsRedactedWhole() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "Username": "alice",
            "Pw": #"my pass,word "quoted""#,
        ])
        let described = NetworkDiagnostics.describeRequestBody(body)

        XCTAssertEqual(described, #"{"Pw":"<redacted>","Username":"alice"}"#)
    }

    /// 本 App 的请求体全是 JSON;出现别的形态不记内容,只记字节数。
    func testNonJSONRequestBodyIsNotPrinted() {
        let body = Data("Pw=my pass,word".utf8)
        XCTAssertEqual(NetworkDiagnostics.describeRequestBody(body), "<15 bytes, non-JSON>")
    }

    /// 嵌套键、数组里的键、字符串值里嵌的 `api_key=` 都要脱敏;非敏感字段原样保留。
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

    /// 解码失败的行要带上 `DecodingError` 描述(含 codingPath)与响应体 —— 版本差异靠它定位。
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

    /// 测试进程必须**不落盘**。单元测试成批构造 4xx/5xx,而测试跑在宿主 App
    /// 进程里、共享同一个沙盒容器 —— 不挡的话跑几轮测试就能把 `fileSizeLimit`
    /// 顶满,冲掉真实排障记录(实测一次全集写入 37 行 mock 记录)。
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

    /// 播放失败行:URL 的 api_key 不能原样出现,错误消息要保留,且换行压平。
    func testPlaybackFailureLineRedactsSecretsAndKeepsClues() throws {
        let url = try XCTUnwrap(URL(string: "https://emby.example.com/Videos/1/stream?static=true&api_key=SECRET123"))
        let line = NetworkDiagnostics.playbackFailureLine(
            message: "unrecognized file format\n(retry)",
            url: url,
            method: "DirectStream",
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertFalse(line.contains("SECRET123"))
        XCTAssertTrue(line.contains("PLAYBACK method=DirectStream host=emby.example.com"))
        XCTAssertTrue(line.contains(#"message="unrecognized file format (retry)""#))
        XCTAssertTrue(line.contains("dsu=absent"))
        XCTAssertFalse(line.contains("\n"))
    }

    /// 没传 userAgent 时不出现空的 ua 段。
    func testPlaybackFailureLineOmitsUserAgentWhenAbsent() throws {
        let url = try XCTUnwrap(URL(string: "https://emby.example.com/a"))
        let line = NetworkDiagnostics.playbackFailureLine(
            message: "m", url: url, method: "Transcode")
        XCTAssertFalse(line.contains("ua="))
    }

    // MARK: - 内核日志(ENGINE)

    /// 每条一行:时间、级别、来源、重复次数(>1 才写)、正文
    func testEngineLogLinesFormat() {
        let lines = NetworkDiagnostics.engineLogLines([
            PlayerLogEntry(date: Date(timeIntervalSince1970: 0), level: "error", source: "ffmpeg",
                           text: "[mov,mp4 @ 0x1] moov atom not found", count: 1),
            PlayerLogEntry(date: Date(timeIntervalSince1970: 1), level: "warn", source: "erika",
                           text: #"{"stage":"open_avcodec_to_software"}"#, count: 3),
        ])
        XCTAssertEqual(lines, [
            "1970-01-01T00:00:00Z ENGINE error ffmpeg [mov,mp4 @ 0x1] moov atom not found",
            #"1970-01-01T00:00:01Z ENGINE warn erika ×3 {"stage":"open_avcodec_to_software"}"#,
        ])
    }

    /// 内核已脱敏,这里仍要再脱一次(双保险),并压平换行
    func testEngineLogLinesRedactAndFlatten() {
        let lines = NetworkDiagnostics.engineLogLines([
            PlayerLogEntry(date: .now, level: "error", source: "ffmpeg",
                           text: "HTTP error\nGET /Videos/1/stream?api_key=SECRET123", count: 1),
        ])
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].contains("SECRET123"))
        XCTAssertFalse(lines[0].contains("\n"))
    }

    /// 没有条目也写一行,表明查过了 —— 不然分不清「内核没报」和「没去读」
    func testEngineLogLinesWhenEmpty() {
        XCTAssertEqual(
            NetworkDiagnostics.engineLogLines([], date: Date(timeIntervalSince1970: 0)),
            ["1970-01-01T00:00:00Z ENGINE <no warn/error entries since open>"])
    }
}
