import XCTest
@testable import LumaPlayer

/// `PlaybackSessionCoordinator` 端到端:PlaybackInfo 请求 → 决策 → 会话与认证头。走 `MockEmbyURLProtocol`,零真实网络。
final class PlaybackSessionCoordinatorTests: XCTestCase {
    private static let userID = "USER-1"
    private static let token = "FAKE_TOKEN_0123456789"
    private static let itemID = "ITEM-1"

    private var session: URLSession!
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() async throws {
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
        session = nil
    }

    // MARK: - 请求

    /// 4.3:不发 `EnableDirectPlay`(带 profile 时发 false 会连 DirectStream 一起关掉),
    /// 另外两个开关为 true,并带最小 `DeviceProfile`(直连不限 + 转码输出)。
    func testPlaybackInfoRequestSendsExpectedBody() async throws {
        stubPlaybackInfo("playback_direct_stream_synthetic.json")

        _ = try await makeCoordinator().makeSession()

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/PlaybackInfo"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/emby/Items/\(Self.itemID)/PlaybackInfo")
        XCTAssertEqual(request.header("X-Emby-Token"), Self.token)

        let body = try XCTUnwrap(request.body)
        let fields = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(fields["UserId"] as? String, Self.userID)
        XCTAssertNil(fields["EnableDirectPlay"])
        XCTAssertEqual(fields["EnableDirectStream"] as? Bool, true)
        XCTAssertEqual(fields["EnableTranscoding"] as? Bool, true)
        // 最小 DeviceProfile:视频容器/编码不限(API_CONTRACT.md 4.3)
        let profile = try XCTUnwrap(fields["DeviceProfile"] as? [String: Any])
        let direct = try XCTUnwrap(profile["DirectPlayProfiles"] as? [[String: Any]])
        XCTAssertEqual(direct.count, 1)
        XCTAssertEqual(direct.first?["Type"] as? String, "Video")
        XCTAssertNil(direct.first?["Container"])
        // 转码侧明确声明输出:HLS / TS + H.264 + AAC
        let transcoding = try XCTUnwrap(profile["TranscodingProfiles"] as? [[String: Any]])
        XCTAssertEqual(transcoding.count, 1)
        XCTAssertEqual(transcoding.first?["Type"] as? String, "Video")
        XCTAssertEqual(transcoding.first?["Container"] as? String, "ts")
        XCTAssertEqual(transcoding.first?["Protocol"] as? String, "hls")
        XCTAssertEqual(transcoding.first?["VideoCodec"] as? String, "h264")
        XCTAssertEqual(transcoding.first?["AudioCodec"] as? String, "aac")
        XCTAssertEqual(transcoding.first?["Context"] as? String, "Streaming")
    }

    // MARK: - 起播位置(4.5)

    /// 4.5:转码流不能客户端 seek,要带 `StartTimeTicks` 重新起流。
    func testStartTimeTicksIsSentWhenRequested() async throws {
        stubPlaybackInfo("playback_transcode_only_synthetic.json")

        _ = try await makeCoordinator().makeSession(startTimeTicks: 600_000_000)

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/PlaybackInfo"))
        let fields = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(fields["StartTimeTicks"] as? Int, 600_000_000)
    }

    /// 不带起播位置时整个键**省略**(`null` 也不发):它是服务端判断
    /// 「要不要转码」的输入之一,DirectStream 路径不该多给这个信号。
    func testStartTimeTicksIsOmittedByDefault() async throws {
        stubPlaybackInfo("playback_direct_stream_synthetic.json")

        _ = try await makeCoordinator().makeSession()

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/PlaybackInfo"))
        let fields = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertNil(fields["StartTimeTicks"])
    }

    // MARK: - 决策结果

    func testCoordinatorProducesDirectStreamPlanWithAuthHeaders() async throws {
        stubPlaybackInfo("playback_direct_stream_synthetic.json")

        let playback = try await makeCoordinator().makeSession()

        XCTAssertEqual(playback.plan.method, .directStream)
        XCTAssertTrue(playback.plan.url.absoluteString.contains("static=true"))
        // mpv 自己发 HTTP 请求:漏了认证头就是 401,且从 mpv 侧很难定位(API_CONTRACT.md 第 6 节)
        XCTAssertEqual(playback.plan.headers["X-Emby-Token"], Self.token)
        XCTAssertTrue(
            playback.plan.headers["Authorization"]?.contains("UserId=\"\(Self.userID)\"") == true)
    }

    func testCoordinatorProducesTranscodePlan() async throws {
        stubPlaybackInfo("playback_transcode_only_synthetic.json")

        let playback = try await makeCoordinator().makeSession()

        XCTAssertEqual(playback.plan.method, .transcode)
        XCTAssertEqual(
            playback.plan.url.absoluteString,
            "https://emby.test/emby/videos/ITEM-TRANSCODE/master.m3u8"
            + "?VideoCodec=h264&AudioCodec=aac")
    }

    func testCoordinatorSurfacesNoPlayablePath() async throws {
        stubPlaybackInfo("playback_no_playable_path_synthetic.json")

        do {
            _ = try await makeCoordinator().makeSession()
            XCTFail("应当抛出 noPlayablePath")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .noPlayablePath)
        }
    }

    /// 401 由 `ServerConnection` 按 API_CONTRACT.md 2.5 处理:
    /// 只清这一台的 token,并且如实抛 `.unauthorized` 让上层走重新登录。
    func testUnauthorizedIsPropagated() async throws {
        MockEmbyURLProtocol.stub(
            .status(401),
            path: "/emby/Items/\(Self.itemID)/PlaybackInfo"
        )
        let connection = try await makeConnection()

        do {
            _ = try await PlaybackSessionCoordinator(connection: connection, itemID: Self.itemID)
                .makeSession()
            XCTFail("应当抛出 unauthorized")
        } catch let error as EmbyAPIError {
            XCTAssertEqual(error, .unauthorized)
        }
        // `await` 不能出现在 XCTAssert 的 autoclosure 里,先取出来再断言
        let profile = await connection.currentProfile()
        let remainingToken = try await credentials.token(forServer: profile.id)
        XCTAssertNil(remainingToken)
    }

    // MARK: - 辅助

    private func stubPlaybackInfo(_ fixture: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            MockEmbyURLProtocol.stub(
                .json(try FixtureLoader.json(fixture)),
                path: "/emby/Items/\(Self.itemID)/PlaybackInfo"
            )
        } catch {
            XCTFail("读 fixture 失败: \(error)", file: file, line: line)
        }
    }

    private func makeCoordinator() async throws -> PlaybackSessionCoordinator {
        PlaybackSessionCoordinator(
            connection: try await makeConnection(), itemID: Self.itemID)
    }

    private func makeConnection() async throws -> ServerConnection {
        let profile = ServerProfile(
            displayName: "emby.test",
            baseURL: testURL("https://emby.test"),
            apiPathPrefix: "/emby",
            userID: Self.userID,
            username: "testuser",
            deviceID: "DEVICE-UUID-1"
        )
        try await credentials.saveToken(Self.token, forServer: profile.id)
        return ServerConnection(profile: profile, credentials: credentials, session: session)
    }
}
