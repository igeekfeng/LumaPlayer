import XCTest
@testable import LumaPlayer

/// `Pan115APIClient` 的传输层行为:错误码映射、翻页、直链请求头。
///
/// ⚠️ **未在真实服务器验证**。这里全部用 `MockEmbyURLProtocol` 造响应 ——
/// 它按 `scheme|host|path` 打桩,所以 115 的真实主机名(`webapi.115.com` 等)可以原样用。
/// `downloadURL` 的**成功**路径测不了:响应要用客户端那次的随机 key 加密,桩造不出来(见该用例注释)。
final class Pan115APIClientTests: XCTestCase {
    private var session: URLSession!
    private var client: Pan115APIClient!
    private let credential = Pan115Credential(uid: "u", cid: "c", seid: "s", kid: nil)

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
        // 限速器不参与这些断言(它们只看请求形状),用 0 间隔免得测试慢
        client = Pan115APIClient(session: session, limiter: Pan115RateLimiter(minimumInterval: .zero))
    }

    override func tearDown() {
        MockEmbyURLProtocol.reset()
        session = nil
        client = nil
        super.tearDown()
    }

    // MARK: - 错误码映射

    /// 被踢下线要单独成一档,否则 UI 会显示「115 返回 40101035」而不是「请重新扫码」。
    func testKickedOutCodeBecomesKickedOut() async {
        stubFiles(#"{"state":0,"errno":40101035,"error":"kicked"}"#)
        do {
            _ = try await client.list(cid: "0", credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .kickedOut)
            XCTAssertTrue(error.needsAuthorization)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// `state: false` + 「请先登录」(§3 无 Cookie 时的实测形态)必须映射到「要重新授权」。
    /// ⚠️ 回归:曾经只把 `state` 解成 `Int`,布尔 false 变 nil 被静默放过,最终报成
    /// 「响应里没有 cid」而不是跳扫码屏。
    func testBooleanFalseStateBecomesNotAuthorized() async {
        stubFiles(#"{"state":false,"error":"请先登录","request":"/natsort/files.php"}"#)
        do {
            _ = try await client.list(cid: "0", credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .notAuthorized)
            XCTAssertTrue(error.needsAuthorization)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// `state: false` 但文案认不出时⛔ 不猜,原样带码(且不能折成 notAuthorized)。
    func testBooleanFalseStateWithUnknownMessageStaysServerError() async {
        stubFiles(#"{"state":false,"error":"未知业务失败"}"#)
        do {
            _ = try await client.list(cid: "0", credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .server(code: 0, message: "未知业务失败"))
            XCTAssertFalse(error.needsAuthorization)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// getid 也必须认 `state:false`:这正是「缺少 cid」那次的实际路径。
    func testGetIDBooleanFalseStateBecomesNotAuthorized() async {
        MockEmbyURLProtocol.stub(
            .json(#"{"state":false,"error":"请先登录"}"#),
            host: "webapi.115.com", path: "/files/getid")
        do {
            _ = try await client.directoryID(path: "/", credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .notAuthorized)
            XCTAssertTrue(error.needsAuthorization)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// `990001` = 登录超时,归到「要重新授权」。
    func testNotLoggedInCodeBecomesNotAuthorized() async {
        stubFiles(#"{"state":0,"errno":990001,"error":"请重新登录"}"#)
        do {
            _ = try await client.list(cid: "0", credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .notAuthorized)
            XCTAssertTrue(error.needsAuthorization)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// 二维码过期在 `state: 0` + `errno 40199002` 里(`115driver pkg/driver/error.go:121`),
    /// ⛔ 不能折成通用 `.server`,否则用户看不到「重新获取二维码」。
    func testQRCodeExpiredCodeBecomesQRCodeExpired() async {
        MockEmbyURLProtocol.stub(
            .json(#"{"state":0,"errno":40199002,"error":"qrcode expired"}"#),
            // ⚠️ 桩按 `URL.path` 匹配,而 `URL` 会把尾部斜杠去掉(`/get/status/` → `/get/status`)
            host: "qrcodeapi.115.com", path: "/get/status")
        do {
            _ = try await client.qrCodeStatus(
                Pan115QRCodeSession(uid: "u", time: 1, sign: "s", content: "c"))
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .qrCodeExpired)
            XCTAssertTrue(error.needsAuthorization)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// 其它业务错误原样带码,由 `serverMessage` 决定文案。
    /// ⚠️ 这里不能用 `590075` / `40110000` —— 那两个已经是频控档,见 `testTooFrequentCodeEntersCoolDown`。
    func testUnknownCodeBecomesServerError() async {
        stubFiles(#"{"state":0,"errno":123456,"error":"未知错误"}"#)
        do {
            _ = try await client.list(cid: "0", credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .server(code: 123456, message: "未知错误"))
            XCTAssertFalse(error.needsAuthorization)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// 非频控的 5xx 仍是传输错误。⚠️ 405/403/429 不是这一档:那三个是风控,
    /// 归到 `.rateLimited` 并让限速器冷却(见 `testWAFStatusEntersCoolDown`)。
    func testNonSuccessStatusBecomesTransportError() async {
        MockEmbyURLProtocol.stub(
            .json("<html>oops</html>", statusCode: 500),
            host: "webapi.115.com", path: "/files")
        do {
            _ = try await client.list(cid: "0", credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .transport("HTTP 500"))
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    // MARK: - 翻页

    /// 满页就继续要下一页,直到不满页为止。`pageSize` 是 1000(硬上限 1150,§3)。
    func testListFollowsPagesUntilShortPage() async throws {
        // `count` 是**目录总数**:两页加起来 1003 条
        let first = Self.pageJSON(count: Pan115APIClient.pageSize, start: 0, total: 1003)
        let second = Self.pageJSON(count: 3, start: Pan115APIClient.pageSize, total: 1003)
        MockEmbyURLProtocol.stub(sequence: [.json(first), .json(second)],
                                 host: "webapi.115.com", path: "/files")

        let entries = try await client.list(cid: "0", credential: credential)
        XCTAssertEqual(entries.count, Pan115APIClient.pageSize + 3)

        let requests = MockEmbyURLProtocol.recordedRequests().filter { $0.url.path == "/files" }
        XCTAssertEqual(requests.count, 2)
        // 第二次的 offset 正好跳过第一页
        XCTAssertEqual(offsetParameter(of: requests[1]), String(Pan115APIClient.pageSize))
    }

    /// 一页没满就不再发请求。
    func testListStopsAfterSingleShortPage() async throws {
        MockEmbyURLProtocol.stub(.json(Self.pageJSON(count: 5, start: 0)),
                                 host: "webapi.115.com", path: "/files")
        let entries = try await client.list(cid: "0", credential: credential)
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(MockEmbyURLProtocol.recordedRequests().filter { $0.url.path == "/files" }.count, 1)
    }

    /// 翻页有上限(§6:⛔ 不自动翻超过 5 页)。
    func testListStopsAtMaxPages() async throws {
        // 总数说「还有 100 万条」→ 每页都满,只能靠 maxPages 兜住。
        // 服务端正常回显请求的 offset(§3),所以会一直翻到 maxPages。
        MockEmbyURLProtocol.stub(
            .dynamic { url in Self.pageJSON(count: Pan115APIClient.pageSize, start: Self.offset(of: url), total: 1_000_000) },
            host: "webapi.115.com", path: "/files")
        _ = try await client.list(cid: "0", credential: credential)
        let requests = MockEmbyURLProtocol.recordedRequests().filter { $0.url.path == "/files" }
        XCTAssertEqual(requests.count, Pan115APIClient.maxPages)
    }

    /// 服务端不认我们请求的 offset(它悄悄从头开始算了)→ 必须停。
    ///
    /// ⚠️ aps 接口的文档明写 offset 越界会「相当于 offset=0,从头开始」(§3),
    /// 服务端不报错,继续翻就会把同一页反复取。
    ///
    /// 第一页正常(offset 本来就是 0,服务端认);第二页请求 offset=1000,
    /// 服务端却回 offset=0 → 认出来了,停。
    func testListStopsWhenOffsetIsNotHonored() async throws {
        // 每次都回 offset=0(从头开始),但 `count` 说还有更多
        let wrapped = Self.pageJSON(count: Pan115APIClient.pageSize, start: 0, total: 1_000_000)
        MockEmbyURLProtocol.stub(sequence: [.json(wrapped), .json(wrapped), .json(wrapped)],
                                 host: "webapi.115.com", path: "/files")
        _ = try await client.list(cid: "0", credential: credential)
        let requests = MockEmbyURLProtocol.recordedRequests().filter { $0.url.path == "/files" }
        XCTAssertEqual(requests.count, 2, "第二页发现 offset 不认就得停,⛔ 不能继续取同一页")
    }

    // MARK: - `count` 的语义(目录总条目数)

    /// `count` 是目录总数 → 「还有没有下一页」可以精确判断,⛔ 不必靠「不满页」猜。
    func testHasMoreUsesTheDirectoryTotal() {
        // 取满了,但总数还有剩 → 还有
        XCTAssertTrue(Pan115APIClient.hasMore(
            fetched: 1000, offset: 0, limit: 1000, totalCount: 1500))
        // 取完了,总数正好取完 → 到底
        XCTAssertFalse(Pan115APIClient.hasMore(
            fetched: 500, offset: 1000, limit: 1000, totalCount: 1500))
        // ⚠️ 目录比一页还小 → 到底(总数说了算,⛔ 不是「本页满不满」)
        XCTAssertFalse(Pan115APIClient.hasMore(
            fetched: 2, offset: 0, limit: 1000, totalCount: 10))
    }

    /// 推进量用**服务端口径**(`offset + limit`),⛔ 不用解码后的条数 ——
    /// 缺 `cid` 的条目被丢掉会让它少于服务端实际推进的条数 ⇒ 多发一次空请求。
    func testHasMoreUsesTheServerStride() {
        // 服务端推进了 1000 条(其中 3 条缺 cid 被丢掉),总数 1000 → 到底
        XCTAssertFalse(Pan115APIClient.hasMore(
            fetched: 997, offset: 0, limit: 1000, totalCount: 1000))
        // 总数还有剩 → 还有下一页
        XCTAssertTrue(Pan115APIClient.hasMore(
            fetched: 997, offset: 0, limit: 1000, totalCount: 2000))
    }

    /// 服务端没给总数时退回「不满页即到底」(与 OpenList 一致)。
    func testHasMoreFallsBackToShortPageWithoutTotal() {
        XCTAssertTrue(Pan115APIClient.hasMore(
            fetched: 1000, offset: 0, limit: 1000, totalCount: nil))
        XCTAssertFalse(Pan115APIClient.hasMore(
            fetched: 999, offset: 1000, limit: 1000, totalCount: nil))
    }

    // MARK: - 直链请求头(§4.3)

    /// `f` 空 / `1` 只要 UA;`f=3` 要 UA + Cookie,且优先用取链响应给的 `Set-Cookie`。
    func testPlaybackHeadersFollowTheFParameter() {
        let cookie = "UID=u; CID=c; SEID=s"
        let setCookie = ["PHPSESSID=abc123; Path=/; HttpOnly"]

        let none = Pan115APIClient.playbackHeaders(
            for: url("https://cdn.example.com/a.mp4?f="), cookie: cookie, responseCookies: [])
        XCTAssertEqual(none, ["User-Agent": Pan115UserAgent.value])

        let uaOnly = Pan115APIClient.playbackHeaders(
            for: url("https://cdn.example.com/a.mp4?f=1"), cookie: cookie, responseCookies: [])
        XCTAssertEqual(uaOnly, ["User-Agent": Pan115UserAgent.value])

        let withCookie = Pan115APIClient.playbackHeaders(
            for: url("https://cdn.example.com/a.mp4?f=3"), cookie: cookie,
            responseCookies: setCookie)
        XCTAssertEqual(withCookie["User-Agent"], Pan115UserAgent.value)
        XCTAssertEqual(withCookie["Cookie"], "PHPSESSID=abc123")
    }

    /// 没有 `Set-Cookie` 时退回登录 Cookie(`f=3` 也要能播)。
    func testCookieRequirementFallsBackToLoginCookie() {
        let headers = Pan115APIClient.playbackHeaders(
            for: url("https://cdn.example.com/a.mp4?f=3"),
            cookie: "UID=u; CID=c; SEID=s", responseCookies: [])
        XCTAssertEqual(headers["Cookie"], "UID=u; CID=c; SEID=s")
    }

    /// 认不出的档位只带 UA,⛔ 不猜要不要 Cookie。
    func testUnknownRequirementKeepsOnlyUserAgent() {
        let headers = Pan115APIClient.playbackHeaders(
            for: url("https://cdn.example.com/a.mp4?f=9"), cookie: "UID=u", responseCookies: [])
        XCTAssertEqual(headers, ["User-Agent": Pan115UserAgent.value])
    }

    /// 取链与播放必须同一个 UA —— 否则 `f=1` 的直链会 403。
    func testUserAgentMatchesTheOneSentByEndpoints() {
        let headers = Pan115APIClient.playbackHeaders(
            for: url("https://cdn.example.com/a.mp4?f=1"), cookie: "", responseCookies: [])
        XCTAssertEqual(headers["User-Agent"], Pan115Endpoint.fileList(cid: "0", offset: 0, limit: 1)
            .headers["User-Agent"])
    }

    /// 一个 `Set-Cookie` 头里被合并了多段(逗号分隔)时要全部拆出来。
    func testCookieValueSplitsMergedSetCookieHeaders() {
        let value = Pan115APIClient.cookieValue(fromSetCookieHeaders: [
            "A=1; Path=/, B=2; Path=/",
        ])
        XCTAssertEqual(value, "A=1; B=2")
    }

    func testCookieValueIgnoresAttributesAndEmptyValues() {
        XCTAssertNil(Pan115APIClient.cookieValue(fromSetCookieHeaders: ["Path=/; HttpOnly"]))
        XCTAssertNil(Pan115APIClient.cookieValue(fromSetCookieHeaders: ["EMPTY=; Path=/"]))
        XCTAssertNil(Pan115APIClient.cookieValue(fromSetCookieHeaders: []))
    }

    /// 「目录不存在」不是鉴权问题,但浏览页必须能认出它来回落片库根 —— 否则片库根被删之后
    /// 每次进来都停在一条错误页上。115 用业务错误码表示(没有 HTTP 404)。
    func testDirectoryMissingCodesAreRecognized() async {
        for code in [800001, 10014, 20009] {
            MockEmbyURLProtocol.reset()
            stubFiles(#"{"state":0,"errno":\#(code),"error":"目录不存在"}"#)
            do {
                _ = try await client.list(cid: "999", credential: credential)
                XCTFail("应当抛错")
            } catch let error as Pan115Error {
                XCTAssertTrue(error.isDirectoryUnavailable, "码 \(code) 应算「目录不在了」")
                XCTAssertFalse(error.needsAuthorization, "码 \(code) 不是鉴权问题")
            } catch {
                XCTFail("错误的类型:\(error)")
            }
        }
    }

    /// 表外的码不该被当成「目录不在了」—— 否则真出错时会被静默吞掉、回落掉片库根。
    func testOtherErrorCodesAreNotTreatedAsMissingDirectory() async {
        stubFiles(#"{"state":0,"errno":123456,"error":"未知错误"}"#)
        do {
            _ = try await client.list(cid: "0", credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertFalse(error.isDirectoryUnavailable)
            XCTAssertEqual(error, .server(code: 123456, message: "未知错误"))
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    // MARK: - 频控

    /// `590075 操作太频繁` 是风控的第一档,必须单独成档并让限速器进入冷却 ——
    /// 折成通用 `.server` 的话调用方只会照常重试,把临时频控拖成域名级 WAF 拦截。
    func testTooFrequentCodeEntersCoolDown() async {
        let limiter = Pan115RateLimiter(minimumInterval: .zero)
        let limited = Pan115APIClient(session: session, limiter: limiter)
        stubFiles(#"{"state":0,"errno":590075,"error":"操作太频繁"}"#)
        do {
            _ = try await limited.list(cid: "0", credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            guard case .rateLimited(let retryAfter) = error else {
                return XCTFail("应当是 rateLimited,实际是 \(error)")
            }
            XCTAssertGreaterThan(retryAfter, 0)
            XCTAssertFalse(error.needsAuthorization)
            XCTAssertFalse(error.isDirectoryUnavailable)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
        // 冷却期内一个请求都不发
        let recorded = MockEmbyURLProtocol.recordedRequests().count
        do {
            _ = try await limited.list(cid: "0", credential: credential)
            XCTFail("冷却期内应当直接失败")
        } catch let error as Pan115Error {
            guard case .rateLimited = error else {
                return XCTFail("应当是 rateLimited,实际是 \(error)")
            }
        } catch {
            XCTFail("错误的类型:\(error)")
        }
        XCTAssertEqual(
            MockEmbyURLProtocol.recordedRequests().count, recorded,
            "冷却期内不该再打 115")
    }

    /// WAF 的 405 HTML 也是频控,不是普通传输错误:认出来就该停手。
    func testWAFStatusEntersCoolDown() async {
        let limiter = Pan115RateLimiter(minimumInterval: .zero)
        let limited = Pan115APIClient(session: session, limiter: limiter)
        // 阿里云 WAF 拦下来时回的是 HTML 页面,不是 115 的 JSON
        MockEmbyURLProtocol.stub(
            .json("<html>blocked</html>", statusCode: 405),
            host: "webapi.115.com", path: "/files")
        do {
            _ = try await limited.list(cid: "0", credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            guard case .rateLimited = error else {
                return XCTFail("应当是 rateLimited,实际是 \(error)")
            }
        } catch {
            XCTFail("错误的类型:\(error)")
        }
        let coolDown = await limiter.remainingCoolDown
        XCTAssertNotNil(coolDown, "405 之后应当还在冷却中")
    }

    // MARK: - 扫码渠道(§2.2 第 4 步)

    /// 默认渠道 `tv` 必须真的出现在第 4 步的 path 与 form 里(不是只在类型上「默认」)。
    /// ⚠️ 这是防止误改回 `web` 的回归闸:`web` 与用户常用浏览器同 ssoent 组,会互踢。
    func testQRCodeLoginSendsDefaultTVChannelOnTheWire() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"state":1,"data":{"cookie":{"UID":"u","CID":"c","SEID":"s"}}}"#),
            host: "passportapi.115.com", path: "/app/1.0/tv/1.0/login/qrcode")
        let credential = try await client.qrCodeLogin(
            Pan115QRCodeSession(uid: "TOKEN-UID", time: 1, sign: "s", content: "c"))
        XCTAssertEqual(credential.uid, "u")
        let request = try XCTUnwrap(
            MockEmbyURLProtocol.recordedRequests().first { $0.url.path.contains("login/qrcode") })
        XCTAssertTrue(request.url.path.hasSuffix("/app/1.0/tv/1.0/login/qrcode"), request.url.path)
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertEqual(body, "account=TOKEN-UID&app=tv")
    }

    // MARK: - downloadURL

    /// ⚠️ **只测失败路径**。成功路径的响应必须用客户端那一次的随机 key 加密,
    /// 而 key 不随请求发出(它内嵌在密文里,`decode` 用的是调用方传的那个),
    /// 桩无法生成合法密文 —— 这一段只能靠真实账号验证(`KNOWN_ISSUES.md`)。
    func testDownloadURLSurfacesBusinessError() async {
        MockEmbyURLProtocol.stub(
            .json(#"{"state":0,"errno":990001,"error":"请重新登录"}"#),
            host: "proapi.115.com", path: "/app/chrome/downurl")
        do {
            _ = try await client.downloadURL(pickCode: "PC1", credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .notAuthorized)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// 空 pick_code 在发请求前就拒绝(省一次风控额度)。
    func testDownloadURLRejectsEmptyPickCodeWithoutNetwork() async {
        do {
            _ = try await client.downloadURL(pickCode: "", credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .pickCodeMissing("pick_code 为空"))
        } catch {
            XCTFail("错误的类型:\(error)")
        }
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    // MARK: - 删除(§9)

    /// 删除 = `POST /rb/delete`,body 是带下标的 `fid[0]=<id>`(中括号要整体编码),带 Cookie;
    /// 成功只认显式 `state:1`。
    func testDeleteSendsIndexedFIDFormAndAcceptsStateOne() async throws {
        MockEmbyURLProtocol.stub(
            .json(#"{"state":1}"#), host: "webapi.115.com", path: "/rb/delete")
        try await client.delete(ids: ["987"], credential: credential)

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/rb/delete"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(request.body), as: UTF8.self),
            "fid%5B0%5D=987")
        XCTAssertEqual(request.header("Cookie"), credential.cookieHeader)
    }

    /// 没有 `state:1` 的响应(这里 `{}`)⛔ 不能当成删掉了:删除是写操作,
    /// 「无法证伪」不等于「成功」。
    func testDeleteRequiresExplicitStateOne() async {
        MockEmbyURLProtocol.stub(.json(#"{}"#), host: "webapi.115.com", path: "/rb/delete")
        do {
            try await client.delete(ids: ["1"], credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            guard case .decoding(_, let detail) = error else {
                return XCTFail("应当是 decoding,实际是 \(error)")
            }
            XCTAssertTrue(detail.contains("state"), detail)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// `231011`「文件已删除,请勿重复操作」是幂等档:API 层如实抛 `.alreadyDeleted`,
    /// 由 `Pan115Connection` 当成功处理(见 `Pan115ConnectionTests`)。
    func testAlreadyDeletedCodeBecomesAlreadyDeleted() async {
        MockEmbyURLProtocol.stub(
            .json(#"{"state":0,"errno":231011,"error":"文件已删除，请勿重复操作"}"#),
            host: "webapi.115.com", path: "/rb/delete")
        do {
            try await client.delete(ids: ["1"], credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .alreadyDeleted)
            XCTAssertFalse(error.needsAuthorization)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// 删除失败⛔ 不重试:重试就是第二次删除,还多一次风控面(§9)。
    func testDeleteDoesNotRetry() async {
        MockEmbyURLProtocol.stub(
            .json(#"{"state":0,"errno":990003,"error":"操作失败。"}"#),
            host: "webapi.115.com", path: "/rb/delete")
        do {
            try await client.delete(ids: ["1"], credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .server(code: 990003, message: "操作失败。"))
        } catch {
            XCTFail("错误的类型:\(error)")
        }
        XCTAssertEqual(
            MockEmbyURLProtocol.recordedRequests().filter { $0.url.path == "/rb/delete" }.count,
            1, "⛔ 删除只发一次,失败不重试")
    }

    /// `990009`「删除操作尚未执行完成」是 115 的后台任务,不是频控 ——
    /// 折成 `rateLimited` 会让 App 白锁 30 分钟(§9)。
    func testOperationBusyCodeIsNotRateLimited() async {
        let limiter = Pan115RateLimiter(minimumInterval: .zero)
        let limited = Pan115APIClient(session: session, limiter: limiter)
        MockEmbyURLProtocol.stub(
            .json(#"{"state":0,"errno":990009,"error":"删除操作尚未执行完成，请稍后再试！"}"#),
            host: "webapi.115.com", path: "/rb/delete")
        do {
            try await limited.delete(ids: ["1"], credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            guard case .server(let code, _) = error else {
                return XCTFail("应当是 server,实际是 \(error)")
            }
            XCTAssertEqual(code, 990009)
            XCTAssertEqual(error.userMessage, "115 还在处理上一次删除或还原,请过几秒再试。")
        } catch {
            XCTFail("错误的类型:\(error)")
        }
        let coolDown = await limiter.remainingCoolDown
        XCTAssertNil(coolDown, "990009 不是频控,⛔ 不要进冷却")
    }

    /// 空 id 在发请求前就拒绝(省一次风控额度)。
    func testDeleteRejectsEmptyIDsWithoutNetwork() async {
        do {
            try await client.delete(ids: [], credential: credential)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .invalidRequest("没有要删除的文件 ID"))
        } catch {
            XCTFail("错误的类型:\(error)")
        }
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    // MARK: - 辅助

    private func stubFiles(_ body: String) {
        MockEmbyURLProtocol.stub(.json(body), host: "webapi.115.com", path: "/files")
    }

    private func url(_ text: String) -> URL {
        URL(string: text)!
    }

    private func offsetParameter(of request: MockEmbyURLProtocol.RecordedRequest) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "offset" }?
            .value
    }

    /// 请求里的 `offset`(给动态 mock 用)。
    private static func offset(of url: URL) -> Int {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "offset" }?
            .value
            .flatMap(Int.init) ?? 0
    }

    /// 造一页 `count` 条(全是视频文件),`fid` 从 `start` 起递增。
    ///
    /// ⚠️ `count` 是**目录总条目数**(官方 SDK 的注释是「当前目录文件数量」;
    /// `get_file_count` 更是用 `page_size=1` 只取一条却从 `count` 读出总数),
    /// ⛔ 不是本页条数。`total` 为 nil 时按「总数 = 本页条数」处理(到头了)。
    private static func pageJSON(count: Int, start: Int, total: Int? = nil) -> String {
        let entries = (0..<count).map { index -> String in
            let id = start + index
            return """
            {"fid":"\(id)","cid":"0","n":"f\(id).mp4","s":"1024","pc":"PC\(id)","sha":"SHA",
             "te":1767319445,"iv":"1"}
            """
        }
        let totalCount = total ?? count
        return #"{"state":1,"cid":"0","count":\#(totalCount),"offset":\#(start),"data":[\#(entries.joined(separator: ","))]}"#
    }
}
