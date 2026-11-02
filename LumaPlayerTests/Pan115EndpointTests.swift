import XCTest
@testable import LumaPlayer

/// 115 端点构造(纯函数):主机分工、路径、参数名、整体编码、表单字段(`docs/PAN115_API.md` §1 - §4)。
final class Pan115EndpointTests: XCTestCase {

    // MARK: - 主机分工(§1)

    /// 四个域名各管一段:业务在 webapi,取链在 proapi,扫码在 qrcodeapi,换 Cookie 在 passportapi。
    /// 换错域名不是「失败」而是被当成另一个客户端 —— 会踢设备或直接风控。
    func testEachEndpointUsesItsOwnHost() throws {
        XCTAssertEqual(try XCTUnwrap(Pan115Endpoint.qrCodeToken(app: "web").url).host, "qrcodeapi.115.com")
        XCTAssertEqual(
            try XCTUnwrap(Pan115Endpoint.qrCodeStatus(uid: "u", time: 1, sign: "s", now: 2).url).host,
            "qrcodeapi.115.com")
        XCTAssertEqual(
            try XCTUnwrap(Pan115Endpoint.qrCodeLogin(app: "web", account: "u").url).host,
            "passportapi.115.com")
        XCTAssertEqual(try XCTUnwrap(Pan115Endpoint.userInfo(now: 1).url).host, "my.115.com")
        XCTAssertEqual(
            try XCTUnwrap(Pan115Endpoint.fileList(cid: "0", offset: 0, limit: 1000).url).host,
            "webapi.115.com")
        XCTAssertEqual(try XCTUnwrap(Pan115Endpoint.directoryID(path: "/").url).host, "webapi.115.com")
        XCTAssertEqual(
            try XCTUnwrap(
                Pan115Endpoint.downloadURL(timestamp: 1, encryptedPayload: "x").url).host,
            "proapi.115.com")
    }

    // MARK: - 扫码登录(§2.2)

    func testQRCodeTokenPathCarriesApp() throws {
        let url = try XCTUnwrap(Pan115Endpoint.qrCodeToken(app: "web").url)
        XCTAssertEqual(url.path, "/api/1.0/web/1.0/token")
        XCTAssertNil(url.query)
    }

    /// 轮询状态四个参数一个都不能少,`_` 是防缓存的毫秒时间戳。
    func testQRCodeStatusCarriesAllFourParameters() throws {
        let endpoint = Pan115Endpoint.qrCodeStatus(uid: "UID-1", time: 1793603418, sign: "SIG", now: 1793603500)
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertEqual(query, "uid=UID-1&time=1793603418&sign=SIG&_=1793603500")
    }

    /// ⚠️ `account` 是 token 响应里的 `uid`,不是 Cookie 的 `UID`;`app` 同时出现在 path 与 form 里。
    func testQRCodeLoginPutsAccountAndAppInForm() throws {
        let endpoint = Pan115Endpoint.qrCodeLogin(app: "web", account: "TOKEN-UID")
        XCTAssertEqual(endpoint.method, "POST")
        XCTAssertEqual(try XCTUnwrap(endpoint.url).path, "/app/1.0/web/1.0/login/qrcode")
        XCTAssertEqual(endpoint.contentType, "application/x-www-form-urlencoded")
        let body = String(decoding: try XCTUnwrap(endpoint.httpBody), as: UTF8.self)
        XCTAssertEqual(body, "account=TOKEN-UID&app=web")
    }

    // MARK: - 登录态(§2.3)

    /// 登录态只打 `my.115.com/?ct=ajax&ac=nav`;⛔ 不要加 `check/sso` 那种探活(会踢掉同设备其它 Cookie)。
    func testUserInfoUsesMyHostRootPath() throws {
        let endpoint = Pan115Endpoint.userInfo(now: 1793603500)
        let url = try XCTUnwrap(endpoint.url)
        XCTAssertEqual(url.host, "my.115.com")
        XCTAssertEqual(url.path, "/")
        XCTAssertEqual(url.query, "_=1793603500")
        XCTAssertEqual(endpoint.name, "my/ajax?ac=nav")
    }

    // MARK: - 目录(§3)

    /// 12 个参数与 `115driver pkg/driver/dir.go:120-133` 一致;`show_dir=1` 才会把子目录一起返回来。
    func testFileListSendsAllTwelveParameters() throws {
        let endpoint = Pan115Endpoint.fileList(cid: "0", offset: 1000, limit: 1000)
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertEqual(
            query,
            "aid=1&cid=0&o=&asc=&offset=1000&show_dir=1&limit=1000&snap=0&natsort=0"
                + "&record_open_time=1&format=json&fc_mix=0")
    }

    /// `path` 里的 `/` 必须整体编码:不编码时服务端会当成别的路径(§3)。
    func testDirectoryIDPercentEncodesTheWholePath() throws {
        let endpoint = Pan115Endpoint.directoryID(path: "/影视/剧集 2026")
        let query = try XCTUnwrap(endpoint.url?.query)
        XCTAssertEqual(query, "path=%2F%E5%BD%B1%E8%A7%86%2F%E5%89%A7%E9%9B%86%202026")
        XCTAssertFalse(query.contains("path=/"), "斜杠不得原样留在查询串里:\(query)")
    }

    // MARK: - 取直链(§4.1)

    /// body 是 `data=<m115 密文>`,`t` 是秒级时间戳。密文里的 `+` `/` `=` 必须整体编码,否则服务端解不开。
    func testDownloadURLSendsEncryptedPayloadInForm() throws {
        let endpoint = Pan115Endpoint.downloadURL(timestamp: 1793603500, encryptedPayload: "a+b/c=")
        let url = try XCTUnwrap(endpoint.url)
        XCTAssertEqual(url.path, "/app/chrome/downurl")
        XCTAssertEqual(url.query, "t=1793603500")
        let body = String(decoding: try XCTUnwrap(endpoint.httpBody), as: UTF8.self)
        XCTAssertEqual(body, "data=a%2Bb%2Fc%3D")
    }

    /// ⚠️ 取链的 UA 会被写进直链校验(§4.3),所以取链与播放必须用同一个值。
    func testEveryEndpointSendsTheSameUserAgent() throws {
        let endpoints: [Pan115Endpoint] = [
            .qrCodeToken(app: "web"),
            .qrCodeStatus(uid: "u", time: 1, sign: "s", now: 2),
            .qrCodeLogin(app: "web", account: "u"),
            .userInfo(now: 1),
            .fileList(cid: "0", offset: 0, limit: 1000),
            .directoryID(path: "/"),
            .downloadURL(timestamp: 1, encryptedPayload: "x"),
        ]
        for endpoint in endpoints {
            XCTAssertEqual(endpoint.headers["User-Agent"], Pan115UserAgent.value, endpoint.name)
        }
        XCTAssertEqual(Pan115UserAgent.value, "Mozilla/5.0 115Browser/35.6.0.3")
    }

    /// 诊断名不含凭据,可以进日志。
    func testNamesCarryNoCredentials() {
        let endpoint = Pan115Endpoint.qrCodeLogin(app: "web", account: "SECRET-ACCOUNT")
        XCTAssertEqual(endpoint.name, "qrcode/login")
        XCTAssertFalse(endpoint.name.contains("SECRET"))
    }
}
