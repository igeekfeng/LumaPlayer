import XCTest
@testable import LumaPlayer

/// `QuarkAPIClient` 的传输层行为:信封判定、翻页、直链解析、换 token 的错误分档。
/// 全部用 `MockEmbyURLProtocol` 打桩(`scheme|host|path`),所以夸克的真实主机名可以原样用。
final class QuarkAPIClientTests: XCTestCase {
    private var session: URLSession!
    private var client: QuarkAPIClient!
    private let deviceID = "0123456789abcdef0123456789abcdef"

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
        // 限速器不参与这些断言(它们只看请求形状),用 0 间隔免得测试慢
        client = QuarkAPIClient(session: session, limiter: QuarkRateLimiter(minimumInterval: .zero))
    }

    override func tearDown() {
        MockEmbyURLProtocol.reset()
        session = nil
        client = nil
        super.tearDown()
    }

    private func stubQuark(_ body: String, path: String, statusCode: Int = 200) {
        MockEmbyURLProtocol.stub(
            .json(body, statusCode: statusCode), host: QuarkEndpoint.apiHost, path: path)
    }

    // MARK: - 信封判定

    /// `11001 Access Token无效` 要原样带出来,由 `QuarkConnection` 决定刷新后重试。
    func testTokenInvalidBecomesServerErrorWithCode() async {
        stubQuark(
            #"{"status":-1,"errno":11001,"error_info":"Access Token无效","req_id":"x"}"#,
            path: "/user", statusCode: 400)
        do {
            _ = try await client.userInfo(accessToken: "t", deviceID: deviceID)
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            XCTAssertEqual(error, .server(code: 11001, message: "Access Token无效"))
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// ⚠️ `10001`(签名 / 公参被拒)⛔ 不能折成「token 失效去刷新」。
    func testSignatureFailureDoesNotAskForReauthorization() async {
        stubQuark(
            #"{"status":-1,"errno":10001,"error_info":"签名验证失败，禁止访问","req_id":"x"}"#,
            path: "/file", statusCode: 400)
        do {
            _ = try await client.list(
                parentFid: "0", accessToken: "t", deviceID: deviceID, pageIndex: 0)
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            XCTAssertEqual(error, .server(code: 10001, message: "签名验证失败，禁止访问"))
            XCTAssertFalse(error.needsAuthorization)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// 二维码 / `query_token` 过期要单独成一档,否则用户看到的是「夸克返回了错误码 11002」。
    func testExpiredQRCodeBecomesQRCodeExpired() async {
        stubQuark(
            #"{"status":-1,"errno":11002,"error_info":"授权码Code二维码过期","req_id":"x"}"#,
            path: "/oauth/code", statusCode: 400)
        do {
            _ = try await client.code(queryToken: "qt", deviceID: deviceID)
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            XCTAssertEqual(error, .qrCodeExpired)
            XCTAssertTrue(error.needsAuthorization)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// 「用户未确认」是轮询的正常等待态:必须原样交给上层,⛔ 不能在传输层被折成失败。
    func testPendingAuthorizationSurfacesForCallerToKeepPolling() async {
        stubQuark(
            #"{"status":-1,"errno":11003,"error_info":"用户未确认授权","req_id":"x"}"#,
            path: "/oauth/code", statusCode: 400)
        do {
            _ = try await client.code(queryToken: "qt", deviceID: deviceID)
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            XCTAssertEqual(error, .server(code: 11003, message: "用户未确认授权"))
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    // MARK: - 扫码

    func testAuthorizeReturnsSession() async throws {
        stubQuark(
            #"{"status":0,"req_id":"r","qr_data":"iVBORw0KGgo=","query_token":"qt"}"#,
            path: "/oauth/authorize")
        let session = try await client.authorize(deviceID: deviceID)
        XCTAssertEqual(session.queryToken, "qt")
        XCTAssertEqual(session.imageBase64, "iVBORw0KGgo=")
    }

    /// 每次业务请求都要带签名三件套 + 设备 UA(§1、§2)。
    func testRequestsCarrySignatureHeadersAndDeviceUserAgent() async throws {
        stubQuark(
            #"{"status":0,"errno":0,"data":{"nickname":"n"}}"#, path: "/user")
        _ = try await client.userInfo(accessToken: "t", deviceID: deviceID)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/user"))
        XCTAssertNotNil(request.header("x-pan-tm"))
        XCTAssertEqual(request.header("x-pan-token")?.count, 64)
        XCTAssertEqual(request.header("x-pan-client-id"), QuarkEndpoint.clientID)
        XCTAssertEqual(request.header("User-Agent"), QuarkDeviceFingerprint.userAgent)
        // req_id 在查询串上,且是 32 位 hex
        let components = try XCTUnwrap(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let reqID = components.queryItems?.first { $0.name == "req_id" }?.value
        XCTAssertEqual(reqID?.count, 32)
        // 设备字段齐全
        let names = Set(components.queryItems?.map(\.name) ?? [])
        for expected in ["device_id", "device_brand", "platform", "channel", "app_ver"] {
            XCTAssertTrue(names.contains(expected), "缺查询参数 \(expected)")
        }
    }

    // MARK: - 翻页

    /// 总数给了:按「(page_index + 1) * page_size」推进判断还有没有下一页。
    func testHasMoreUsesServerPageArithmetic() {
        XCTAssertTrue(QuarkAPIClient.hasMore(
            fetched: 100, pageIndex: 0, pageSize: 100, totalCount: 250))
        XCTAssertFalse(QuarkAPIClient.hasMore(
            fetched: 50, pageIndex: 2, pageSize: 100, totalCount: 250))
        // 总数没给:退回「本页不满即到底」
        XCTAssertTrue(QuarkAPIClient.hasMore(
            fetched: 100, pageIndex: 0, pageSize: 100, totalCount: nil))
        XCTAssertFalse(QuarkAPIClient.hasMore(
            fetched: 20, pageIndex: 0, pageSize: 100, totalCount: nil))
    }

    /// ⚠️ 本页为空一律停:总数异常时靠它兜底,别死循环(参考 quarkDav 的做法)。
    func testEmptyPageAlwaysStopsEvenIfTotalCountIsWrong() {
        XCTAssertFalse(QuarkAPIClient.hasMore(
            fetched: 0, pageIndex: 0, pageSize: 100, totalCount: 500))
    }

    func testListPassesPageIndexAndDecodesEntries() async throws {
        stubQuark(
            #"{"status":0,"errno":0,"data":{"total_count":2,"files":[{"fid":"a","filename":"a.mp4","isdir":0,"category":1},{"fid":"b","filename":"b","isdir":1}]}}"#,
            path: "/file")
        let page = try await client.list(
            parentFid: "0", accessToken: "t", deviceID: deviceID, pageIndex: 1, pageSize: 100)
        XCTAssertEqual(page.pageIndex, 1)
        XCTAssertEqual(page.pageSize, 100)
        XCTAssertEqual(page.totalCount, 2)
        XCTAssertEqual(page.files.count, 2)
        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/file"))
        let components = try XCTUnwrap(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["method"], "list")
        XCTAssertEqual(items["page_index"], "1")
        // ⚠️ 排序参数按 OpenList 的取值固定(§5)
        XCTAssertEqual(items["order_by"], "3")
        XCTAssertEqual(items["desc"], "1")
        XCTAssertEqual(items["list_all"], "0")
    }

    // MARK: - 直链

    func testDownloadReturnsRawURL() async throws {
        let raw = "https://cdn.example.com/x?a=1&k=abc%2B"
        stubQuark(
            #"{"status":0,"errno":0,"data":{"fid":"f1","file_name":"a.mkv","size":10,"download_url":"\#(raw.replacingOccurrences(of: "\"", with: ""))"}}"#,
            path: "/file")
        let link = try await client.download(fid: "f1", accessToken: "t", deviceID: deviceID)
        XCTAssertEqual(link.url.absoluteString, raw)
        XCTAssertEqual(link.sizeBytes, 10)
        // TV 端 CDN 直链自带签名,⛔ 不预先塞头(§6.1)
        XCTAssertTrue(link.headers.isEmpty)
    }

    /// 没给地址时给「拿不到播放地址」,⛔ 不是解码错误。
    func testDownloadWithoutURLIsPlaybackUnsupported() async {
        stubQuark(
            #"{"status":0,"errno":0,"data":{"fid":"f1","download_url":""}}"#, path: "/file")
        do {
            _ = try await client.download(fid: "f1", accessToken: "t", deviceID: deviceID)
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            if case .playbackUnsupported = error { return }
            XCTFail("错误的错误档:\(error)")
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    // MARK: - 换 token(第三方主机)

    private func stubToken(_ body: String, statusCode: Int = 200) {
        MockEmbyURLProtocol.stub(
            .json(body, statusCode: statusCode),
            host: QuarkEndpoint.codeHost,
            path: QuarkEndpoint.codeBasePath + "/token")
    }

    func testExchangeTokenSuccess() async throws {
        stubToken(
            #"{"code":200,"message":"OK","data":{"status":0,"errno":0,"access_token":"a2","refresh_token":"r2","expires_in":3600}}"#)
        let tokens = try await client.exchangeToken(
            deviceID: deviceID, code: "c", refreshToken: nil)
        XCTAssertEqual(tokens.access, "a2")
        XCTAssertEqual(tokens.refresh, "r2")
    }

    /// `11004` 授权码无效:⛔ 不重试同一个 code,只能重新扫码(§8)。
    func testInvalidAuthorizationCodeIsSeparate() async {
        stubToken(
            #"{"code":200,"message":"OK","data":{"status":-1,"errno":11004,"error_info":"授权码Code无效"}}"#)
        do {
            _ = try await client.exchangeToken(deviceID: deviceID, code: "c", refreshToken: nil)
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            XCTAssertEqual(error, .authorizationCodeInvalid)
            XCTAssertTrue(error.needsAuthorization)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// `11000` 刷新令牌无效:只能重新扫码。
    func testInvalidRefreshTokenIsSeparate() async {
        stubToken(
            #"{"code":200,"message":"OK","data":{"status":-1,"errno":11000,"error_info":"Refresh Token无效"}}"#)
        do {
            _ = try await client.exchangeToken(
                deviceID: deviceID, code: nil, refreshToken: "r")
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            XCTAssertEqual(error, .refreshTokenInvalid)
            XCTAssertTrue(error.needsAuthorization)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// 请求体必须带齐设备字段(实测:缺 `req_id` / `app_ver` 会被第三方服务直接回 400)。
    func testExchangeTokenBodyCarriesDeviceFields() async throws {
        stubToken(
            #"{"code":200,"message":"OK","data":{"status":0,"errno":0,"access_token":"a","refresh_token":"r"}}"#)
        _ = try await client.exchangeToken(deviceID: deviceID, code: "c", refreshToken: nil)
        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/quarkdrive/token"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        let body = try XCTUnwrap(request.body)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: String])
        for key in ["req_id", "app_ver", "device_id", "device_brand", "platform",
                    "device_name", "device_model", "build_device", "build_product",
                    "device_gpu", "activity_rect", "channel", "code"] {
            XCTAssertNotNil(object[key], "请求体缺字段 \(key)")
        }
        XCTAssertEqual(object["device_id"], deviceID)
        XCTAssertNil(object["refresh_token"])
    }
}
