import XCTest
@testable import LumaPlayer

/// 百度网盘端点的构造(纯函数,不需要网络)。
///
/// 断言的是 `docs/BAIDU_PAN_API.md` 里那些**不能错的地方**:路径、参数名、
/// 参数值整体编码,以及两套 `User-Agent` 各归各的端点。
final class BaiduPanEndpointTests: XCTestCase {

    /// `dir` 是绝对路径,百度要求**整体**编码:
    /// `URLComponents.queryItems` 会原样留下 `/`(它在查询串里是合法字符),
    /// 与官方 cURL 示例(`--data-urlencode`)的口径不一致。
    func testDirectoryIsFullyPercentEncoded() throws {
        let endpoint = BaiduPanEndpoint.fileList(
            accessToken: "TOK", directory: "/apps/LumaPlayer/剧集", start: 0, limit: 200)
        let url = try XCTUnwrap(endpoint.url)

        XCTAssertEqual(url.host, "pan.baidu.com")
        XCTAssertEqual(url.path, "/rest/2.0/xpan/file")
        let query = try XCTUnwrap(url.query)
        for expected in ["method=list", "access_token=TOK", "start=0", "limit=200", "order=name"] {
            XCTAssertTrue(query.contains(expected), "查询串应含 \(expected),实际:\(query)")
        }
        // 关键:`/` 必须编成 %2F
        XCTAssertTrue(query.contains("dir=%2Fapps%2FLumaPlayer%2F"), "实际:\(query)")
        XCTAssertFalse(query.contains("dir=/apps"), "不得留下未编码的斜杠:\(query)")
    }

    func testStreamingQueryCarriesPathAndType() throws {
        let endpoint = BaiduPanEndpoint.streaming(
            accessToken: "TOK",
            path: "/apps/LumaPlayer/a.mkv",
            type: .auto1080,
            probeOnly: true,
            adToken: nil
        )
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertTrue(query.contains("method=streaming"))
        XCTAssertTrue(query.contains("type=M3U8_AUTO_1080"))
        XCTAssertTrue(query.contains("nom3u8=1"))
        XCTAssertTrue(query.contains("path=%2Fapps%2FLumaPlayer%2Fa.mkv"), "实际:\(query)")
    }

    func testStreamingProbeWithAdToken() throws {
        let endpoint = BaiduPanEndpoint.streaming(
            accessToken: "TOK", path: "/a.mp4", type: .auto720, probeOnly: true, adToken: "a+b")
        // `adToken` 由服务端给、要「URL 编码后带回」;`+` 不能原样留在查询串里
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertTrue(query.contains("adToken=a%2Bb"), "实际:\(query)")
    }

    /// ⚠️ dlink 走 `multimedia?method=filemetas`(用 `fs_id` 查),
    /// **不是** `file?method=meta` —— 后者实测不给 dlink(见端点注释)。
    func testMetaUsesFilemetasEndpointForDlink() throws {
        let endpoint = BaiduPanEndpoint.fileMeta(accessToken: "TOK", fsIDs: [42])
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertTrue(query.contains("method=filemetas"), "实际:\(query)")
        // `fsids` 是 JSON 数组字面量,整段编码后送
        XCTAssertTrue(query.contains("fsids=%5B42%5D"), "实际:\(query)")
        XCTAssertTrue(query.contains("dlink=1"))
        // 时长(条目级 `duration`)要 `needmedia=1` 才给(实测)
        XCTAssertTrue(query.contains("needmedia=1"))
        XCTAssertEqual(endpoint.host, "pan.baidu.com")
        XCTAssertEqual(endpoint.path, "/rest/2.0/xpan/multimedia")
    }

    /// `fsids` 本来就是数组 —— 批量取封面是**配额要求**(未审核应用 10 次/小时),
    /// 一个目录只发一次请求,而不是每个文件一次。
    func testMetaBatchesMultipleFsIDsInOneRequest() throws {
        let endpoint = BaiduPanEndpoint.fileMeta(accessToken: "TOK", fsIDs: [11, 22, 33])
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertTrue(query.contains("fsids=%5B11%2C22%2C33%5D"), "实际:\(query)")
    }

    // MARK: - 两个主机

    func testOAuthEndpointsLiveOnOpenapiHost() {
        XCTAssertEqual(
            BaiduPanEndpoint.deviceCode(clientID: "K", scope: "basic,netdisk").host,
            "openapi.baidu.com")
        XCTAssertEqual(
            BaiduPanEndpoint.deviceToken(deviceCode: "D", clientID: "K", clientSecret: "S").host,
            "openapi.baidu.com")
        XCTAssertEqual(
            BaiduPanEndpoint.refreshToken(refreshToken: "R", clientID: "K", clientSecret: "S").host,
            "openapi.baidu.com")
        XCTAssertEqual(
            BaiduPanEndpoint.deviceToken(deviceCode: "D", clientID: "K", clientSecret: "S").path,
            "/oauth/2.0/token")
    }

    func testBusinessEndpointsLiveOnPanHost() {
        XCTAssertEqual(BaiduPanEndpoint.userInfo(accessToken: "TOK").host, "pan.baidu.com")
        XCTAssertEqual(BaiduPanEndpoint.userInfo(accessToken: "TOK").path, "/rest/2.0/xpan/nas")
    }

    // MARK: - 两套 User-Agent

    /// 列表/元信息/下载要 `pan.baidu.com`(不给会撞 `31326` 防盗链,§1);
    /// 播放流要 `xpanvideo;…`(§1)。⛔ 两者不能互换。
    func testUserAgentIsPerEndpoint() throws {
        let list = BaiduPanEndpoint.fileList(
            accessToken: "T", directory: "/", start: 0, limit: 1).headers["User-Agent"]
        XCTAssertEqual(list, "pan.baidu.com")
        let meta = BaiduPanEndpoint.fileMeta(
            accessToken: "T", fsIDs: [1]).headers["User-Agent"]
        XCTAssertEqual(meta, "pan.baidu.com")
        // OAuth 三个请求也要带它(2026-10-10 在官方「设备码模式授权」页核实)
        let oauth = BaiduPanEndpoint.deviceCode(
            clientID: "K", scope: "basic,netdisk").headers["User-Agent"]
        XCTAssertEqual(oauth, "pan.baidu.com")

        let streaming = BaiduPanEndpoint.streaming(
            accessToken: "T", path: "/a.mp4", type: .auto1080, probeOnly: false, adToken: nil)
        let ua = try XCTUnwrap(streaming.headers["User-Agent"])
        XCTAssertTrue(ua.hasPrefix("xpanvideo;"), "播放流的 UA 必须以 xpanvideo 开头:\(ua)")
    }

    /// 所有端点都是 GET,且诊断名里不含凭据(CLAUDE.md「安全与隐私」)。
    func testEndpointNamesExcludeSecrets() {
        let endpoint = BaiduPanEndpoint.fileList(
            accessToken: "SUPERSECRET", directory: "/", start: 0, limit: 1)
        XCTAssertEqual(endpoint.method, "GET")
        XCTAssertFalse(endpoint.name.contains("SUPERSECRET"))
    }
}
