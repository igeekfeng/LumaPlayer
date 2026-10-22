import XCTest
@testable import LumaPlayer

/// 百度网盘端点构造(纯函数):路径、参数名、参数值整体编码、两套 `User-Agent` 各归各的端点(`docs/BAIDU_PAN_API.md`)。
final class BaiduPanEndpointTests: XCTestCase {

    /// `URLComponents.queryItems` 会留下 `/`,与官方 cURL(`--data-urlencode`)整体编码的口径不一致。
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
        // `adToken` 要「URL 编码后带回」,`+` 不能原样留在查询串里
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertTrue(query.contains("adToken=a%2Bb"), "实际:\(query)")
    }

    /// dlink 走 `multimedia?method=filemetas`,⛔ 不是 `file?method=meta`(后者不给 dlink)。
    func testMetaUsesFilemetasEndpointForDlink() throws {
        let endpoint = BaiduPanEndpoint.fileMeta(accessToken: "TOK", fsIDs: [42])
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertTrue(query.contains("method=filemetas"), "实际:\(query)")
        // `fsids` 是 JSON 数组字面量,整段编码后送
        XCTAssertTrue(query.contains("fsids=%5B42%5D"), "实际:\(query)")
        XCTAssertTrue(query.contains("dlink=1"))
        // 条目级 `duration` 要 `needmedia=1` 才给
        XCTAssertTrue(query.contains("needmedia=1"))
        XCTAssertEqual(endpoint.host, "pan.baidu.com")
        XCTAssertEqual(endpoint.path, "/rest/2.0/xpan/multimedia")
    }

    /// 批量是配额要求(未审核应用 10 次/小时):一个目录只发一次请求。
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

    /// 列表/元信息/下载要 `pan.baidu.com`(否则撞 `31326` 防盗链),播放流要 `xpanvideo;…`(§1)。⛔ 不能互换。
    func testUserAgentIsPerEndpoint() throws {
        let list = BaiduPanEndpoint.fileList(
            accessToken: "T", directory: "/", start: 0, limit: 1).headers["User-Agent"]
        XCTAssertEqual(list, "pan.baidu.com")
        let meta = BaiduPanEndpoint.fileMeta(
            accessToken: "T", fsIDs: [1]).headers["User-Agent"]
        XCTAssertEqual(meta, "pan.baidu.com")
        // OAuth 三个请求也要带它(官方「设备码模式授权」页)
        let oauth = BaiduPanEndpoint.deviceCode(
            clientID: "K", scope: "basic,netdisk").headers["User-Agent"]
        XCTAssertEqual(oauth, "pan.baidu.com")

        let streaming = BaiduPanEndpoint.streaming(
            accessToken: "T", path: "/a.mp4", type: .auto1080, probeOnly: false, adToken: nil)
        let ua = try XCTUnwrap(streaming.headers["User-Agent"])
        XCTAssertTrue(ua.hasPrefix("xpanvideo;"), "播放流的 UA 必须以 xpanvideo 开头:\(ua)")
    }

    /// 除删除外全是 GET;诊断名里不含凭据。
    func testEndpointNamesExcludeSecrets() {
        let endpoint = BaiduPanEndpoint.fileList(
            accessToken: "SUPERSECRET", directory: "/", start: 0, limit: 1)
        XCTAssertEqual(endpoint.method, "GET")
        XCTAssertFalse(endpoint.name.contains("SUPERSECRET"))

        let deletion = BaiduPanEndpoint.deleteFile(
            accessToken: "SUPERSECRET", path: "/apps/LumaPlayer/a.mkv")
        XCTAssertEqual(deletion.method, "POST")
        XCTAssertFalse(deletion.name.contains("SUPERSECRET"))
    }

    // MARK: - 删除(`docs/BAIDU_PAN_API.md` §2.4)

    /// 删除是唯一的 POST,`access_token` 仍在查询串上。
    func testDeleteUsesFileManagerEndpoint() throws {
        let endpoint = BaiduPanEndpoint.deleteFile(
            accessToken: "TOK", path: "/apps/LumaPlayer/a.mkv")
        let url = try XCTUnwrap(endpoint.url)

        XCTAssertEqual(url.host, "pan.baidu.com")
        XCTAssertEqual(url.path, "/rest/2.0/xpan/file")
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("method=filemanager"), "实际:\(query)")
        XCTAssertTrue(query.contains("opera=delete"), "实际:\(query)")
        XCTAssertTrue(query.contains("access_token=TOK"), "实际:\(query)")
    }

    /// `filelist` 是路径字符串的 JSON 数组(⛔ 不是对象),整段编码进 body;`async=0` 才有逐条结果。
    func testDeleteBodyCarriesJSONPathArray() throws {
        let endpoint = BaiduPanEndpoint.deleteFile(
            accessToken: "TOK", path: "/apps/LumaPlayer/剧集/S01E01.mkv")
        XCTAssertEqual(endpoint.contentType, "application/x-www-form-urlencoded")

        let body = try XCTUnwrap(endpoint.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("async=0"), "实际:\(body)")
        // `["/apps/…"]` 整体编码:`[` `"` `/` 都要是百分号形式
        XCTAssertTrue(
            body.contains("filelist=%5B%22%2Fapps%2FLumaPlayer%2F"),
            "实际:\(body)")
        // ⛔ token 不许进 body:它只在查询串上
        XCTAssertFalse(body.contains("TOK"), "body 里不得出现 token:\(body)")
    }
}
