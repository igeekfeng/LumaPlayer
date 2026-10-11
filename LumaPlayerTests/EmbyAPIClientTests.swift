import XCTest
@testable import LumaPlayer

/// HTTP 状态码映射、解码、取消、以及「token 是实例状态」的隔离性
/// (API_CONTRACT.md 第 7 节)。
///
/// 全部走 `MockEmbyURLProtocol`,**零真实网络依赖**。
final class EmbyAPIClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
    }

    private func makeClient() -> EmbyAPIClient {
        EmbyAPIClient(
            builder: EmbyRequestBuilder(
                baseURL: testURL("https://emby.test"),
                apiPathPrefix: "/emby",
                deviceID: "DEVICE-UUID-1",
                deviceName: "Mac",
                appVersion: "1.2.3"
            ),
            session: session
        )
    }

    // MARK: - 成功路径

    func testDecodesPublicServerInfo() async throws {
        MockEmbyURLProtocol.stub(
            .json(try FixtureLoader.json("public_info.json")),
            path: "/emby/System/Info/Public"
        )
        let info: EmbyServerInfo = try await makeClient().send(.publicSystemInfo)
        XCTAssertEqual(info.version, "4.7.11.0")
        XCTAssertEqual(info.serverName, "emby.test")
    }

    func testSendsTokenHeaderFromInstanceState() async throws {
        MockEmbyURLProtocol.stub(.status(200), path: "/emby/System/Info")
        let client = makeClient()
        await client.setCredentials(accessToken: "TOKEN-A", userID: "USER-A")
        _ = try await client.sendVoid(.systemInfo)

        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "System/Info"))
        XCTAssertEqual(request.header("X-Emby-Token"), "TOKEN-A")
        XCTAssertTrue(request.header("Authorization")?.contains("UserId=\"USER-A\"") == true)
    }

    // MARK: - 状态码映射(API_CONTRACT.md 第 7 节全表)

    func testStatusMapping() async throws {
        let cases: [(Int, EmbyAPIError)] = [
            (401, .unauthorized),
            (403, .forbidden),
            (404, .notFound),
            (429, .rateLimited),
            (500, .server(status: 500)),
            (503, .server(status: 503)),
            (418, .unexpectedStatus(418)),
            (302, .unexpectedStatus(302)),
        ]
        for (status, expected) in cases {
            MockEmbyURLProtocol.reset()
            MockEmbyURLProtocol.stub(.status(status), path: "/emby/System/Info")
            do {
                _ = try await makeClient().sendVoid(.systemInfo)
                XCTFail("\(status) 应当抛错")
            } catch let error as EmbyAPIError {
                XCTAssertEqual(error, expected, "状态码 \(status) 映射错误")
            }
        }
    }

    func testTwoHundredRangeIsSuccess() async throws {
        MockEmbyURLProtocol.stub(.status(204), path: "/emby/Sessions/Logout")
        try await makeClient().sendVoid(.logout)
    }

    // MARK: - 传输错误

    func testCancelledIsMappedToCancelled() async throws {
        // 取消是正常流程,UI 不得显示为错误(API_CONTRACT.md 第 7 节)
        MockEmbyURLProtocol.stub(.failure(.cancelled), path: "/emby/System/Info")
        do {
            _ = try await makeClient().sendVoid(.systemInfo)
            XCTFail("取消应当抛错")
        } catch let error as EmbyAPIError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testTransportErrorKeepsURLErrorCode() async throws {
        MockEmbyURLProtocol.stub(.failure(.notConnectedToInternet), path: "/emby/System/Info")
        do {
            _ = try await makeClient().sendVoid(.systemInfo)
            XCTFail("传输失败应当抛错")
        } catch let error as EmbyAPIError {
            XCTAssertEqual(error, .transport(.notConnectedToInternet))
        }
    }

    func testDecodingErrorCarriesEndpointName() async throws {
        MockEmbyURLProtocol.stub(.json("{ not json ]"), path: "/emby/System/Info/Public")
        do {
            let _: EmbyServerInfo = try await makeClient().send(.publicSystemInfo)
            XCTFail("坏 JSON 应当抛 decoding")
        } catch let error as EmbyAPIError {
            guard case .decoding(_, let endpointName) = error else {
                return XCTFail("期望 .decoding,实际 \(error)")
            }
            XCTAssertEqual(endpointName, "System/Info/Public")
        }
    }

    // MARK: - 多服务器隔离(token 不共享)

    func testTwoClientsDoNotShareToken() async throws {
        MockEmbyURLProtocol.stub(.status(200), host: "emby.test", path: "/emby/System/Info")
        MockEmbyURLProtocol.stub(.status(200), host: "other.test", path: "/emby/System/Info")
        let clientA = makeClient()
        let clientB = EmbyAPIClient(
            builder: EmbyRequestBuilder(
                baseURL: testURL("https://other.test"),
                apiPathPrefix: "/emby",
                deviceID: "DEVICE-UUID-1",
                deviceName: "Mac",
                appVersion: "1.2.3"
            ),
            session: session
        )
        await clientA.setCredentials(accessToken: "TOKEN-A", userID: "USER-A")
        await clientB.setCredentials(accessToken: "TOKEN-B", userID: "USER-B")

        try await clientA.sendVoid(.systemInfo)
        try await clientB.sendVoid(.systemInfo)

        let requests = MockEmbyURLProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].header("X-Emby-Token"), "TOKEN-A")
        XCTAssertEqual(requests[1].header("X-Emby-Token"), "TOKEN-B")
    }
}
