import XCTest
@testable import LumaPlayer

/// 上报请求在 HTTP 层真正发出的 JSON(API_CONTRACT.md 5.1):键名拼写、nil 是否省略、Content-Type 与 token 头只在这一层看得见。
final class PlaybackReportRequestTests: XCTestCase {
    private static let userID = "USER-1"
    private static let token = "FAKE_TOKEN_0123456789"

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

    /// 不使用的字段一个都不发(5.1)。
    func testProgressRequestCarriesFullBody() async throws {
        MockEmbyURLProtocol.stub(.status(200), path: "/emby/Sessions/Playing/Progress")

        try await makeConnection().reportPlayback(
            .sessionsPlayingProgress(Self.progressBody))

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/Sessions/Playing/Progress"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/emby/Sessions/Playing/Progress")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        XCTAssertEqual(request.header("X-Emby-Token"), Self.token)

        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(
            json as NSDictionary,
            [
                "ItemId": "ITEM-1",
                "MediaSourceId": "SOURCE-1",
                "PlaySessionId": "SESSION-1",
                "PlayMethod": "Transcode",
                "PositionTicks": 600_000_000,
                "IsPaused": true,
                "IsMuted": false,
                "VolumeLevel": 80,
                "CanSeek": false,
                "AudioStreamIndex": 2,
                "QueueableMediaTypes": ["Video"],
                "PlaybackRate": 1.25,
                "EventName": "TimeUpdate",
            ] as NSDictionary
        )
        // 一律不出现,而不是发 null
        XCTAssertNil(json["SubtitleStreamIndex"])
        XCTAssertNil(json["SubtitleOffset"])
        XCTAssertNil(json["LiveStreamId"])
    }

    /// 与 Stopped 结构相同,只是没有 EventName(5.1)。
    func testPlayingRequestOmitsEventName() async throws {
        MockEmbyURLProtocol.stub(.status(200), path: "/emby/Sessions/Playing")

        try await makeConnection().reportPlayback(.sessionsPlaying(Self.playingBody))

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/Sessions/Playing"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertNil(json["EventName"])
        XCTAssertEqual(json["ItemId"] as? String, "ITEM-1")
    }

    /// 按 2.5 处置:上报失败不影响播放(5.4),但「token 失效」必须让上层知道。
    func testUnauthorizedClearsToken() async throws {
        MockEmbyURLProtocol.stub(.status(401), path: "/emby/Sessions/Playing/Stopped")
        let connection = try await makeConnection()

        do {
            try await connection.reportPlayback(
                .sessionsPlayingStopped(Self.progressBody))
            XCTFail("应当抛出 unauthorized")
        } catch let error as EmbyAPIError {
            XCTAssertEqual(error, .unauthorized)
        }

        let profile = await connection.currentProfile()
        let remaining = try await credentials.token(forServer: profile.id)
        XCTAssertNil(remaining)
    }

    // MARK: - 辅助

    private static func body(
        eventName: PlaybackEventName? = nil,
        playbackRate: Double? = 1.25
    ) -> PlaybackReportBody {
        PlaybackReportBody(
            itemID: "ITEM-1",
            mediaSourceID: "SOURCE-1",
            playSessionID: "SESSION-1",
            playMethod: PlaybackMethod.transcode.rawValue,
            positionTicks: 600_000_000,
            isPaused: true,
            isMuted: false,
            volumeLevel: 80,
            canSeek: false,
            audioStreamIndex: 2,
            subtitleStreamIndex: nil,
            playbackRate: playbackRate,
            eventName: eventName?.rawValue
        )
    }

    private static var progressBody: PlaybackReportBody { body(eventName: .timeUpdate) }
    private static var playingBody: PlaybackReportBody { body() }

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
