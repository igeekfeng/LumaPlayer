import XCTest
@testable import LumaPlayer

/// 播放决策引擎(API_CONTRACT.md 4.4 全分支)。
///
/// **全部用 fixture,零网络**:引擎是纯函数,输入一份 `PlaybackInfo`
/// 响应、输出一个 `PlaybackSession`,所以「仅转码可用」「无可播路径」
/// 这些真机上难构造的分支在这里全部覆盖住。
///
/// ⚠️ fixture 全部带 `_synthetic` 后缀 = 构造数据,未经真实服务器验证
/// (API_CONTRACT.md 9.4)。
final class PlaybackDecisionEngineTests: XCTestCase {

    private var urlBuilder: PlaybackURLBuilder {
        PlaybackURLBuilder(baseURL: testURL("https://emby.test"), apiPathPrefix: "/emby")
    }

    private let headers = ["X-Emby-Token": "FAKE_TOKEN_0123456789"]

    // MARK: - 正常路径

    func testDirectStreamAvailable() throws {
        let response = try decode("playback_direct_stream_synthetic.json")

        let session = try PlaybackDecisionEngine.session(
            for: response, itemID: "ITEM-1", urlBuilder: urlBuilder, headers: headers)

        XCTAssertEqual(session.plan.method, .directStream)
        XCTAssertEqual(session.plan.playSessionID, "PLAYSESSION-DIRECT-1")
        XCTAssertEqual(session.plan.mediaSourceID, "MEDIASOURCE-DIRECT-1")
        XCTAssertEqual(session.plan.headers, headers)
        // 4.5:static=true + 输出格式扩展名(DirectStream 输出 == 输入容器)
        XCTAssertEqual(
            session.plan.url.absoluteString,
            "https://emby.test/emby/Videos/ITEM-1/stream.mkv"
            + "?static=true&MediaSourceId=MEDIASOURCE-DIRECT-1"
            + "&PlaySessionId=PLAYSESSION-DIRECT-1"
        )
        // 轨道要解出来(1 视频 / 1 音轨 / 1 字幕)
        XCTAssertEqual(session.mediaSource.streamCount(of: "Video"), 1)
        XCTAssertEqual(session.mediaSource.streamCount(of: "Audio"), 1)
        XCTAssertEqual(session.mediaSource.streamCount(of: "Subtitle"), 1)
    }

    /// issue #2:MediaSource 带 DirectStreamUrl 时以它为准,而不是自拼 /Videos/{id}/stream
    func testDirectStreamPrefersServerProvidedURL() throws {
        let response = EmbyPlaybackInfoResponse(
            mediaSources: [
                EmbyMediaSource(
                    id: "MS-7", container: "mkv", supportsDirectStream: true,
                    supportsTranscoding: true, transcodingUrl: nil, mediaStreams: nil,
                    directStreamUrl: "/videos/7/original.mkv?MediaSourceId=MS-7&PlaySessionId=PS&api_key=FAKE_TOKEN_0123456789")
            ],
            playSessionID: "PS", errorCode: nil
        )

        let session = try PlaybackDecisionEngine.session(
            for: response, itemID: "7", urlBuilder: urlBuilder, headers: headers)

        XCTAssertEqual(session.plan.method, .directStream)
        XCTAssertEqual(
            session.plan.url.absoluteString,
            "https://emby.test/emby/videos/7/original.mkv?MediaSourceId=MS-7&PlaySessionId=PS")
    }

    func testTranscodeOnlyUsesTranscodingUrl() throws {
        let response = try decode("playback_transcode_only_synthetic.json")

        let session = try PlaybackDecisionEngine.session(
            for: response, itemID: "ITEM-TRANSCODE", urlBuilder: urlBuilder, headers: headers)

        XCTAssertEqual(session.plan.method, .transcode)
        // TranscodingUrl 是相对路径,必须拼到站点根上
        XCTAssertEqual(
            session.plan.url.absoluteString,
            "https://emby.test/emby/videos/ITEM-TRANSCODE/master.m3u8"
            + "?VideoCodec=h264&AudioCodec=aac"
        )
        XCTAssertEqual(session.plan.mediaSourceID, "MEDIASOURCE-TRANSCODE-1")
    }

    func testMultipleSourcesPrefersDirectStreamCapableOne() throws {
        let response = try decode("playback_multi_source_synthetic.json")

        let session = try PlaybackDecisionEngine.session(
            for: response, itemID: "ITEM-MULTI", urlBuilder: urlBuilder, headers: headers)

        // 第一个源只支持转码,第二个支持 DirectStream —— 必须选第二个
        XCTAssertEqual(session.plan.mediaSourceID, "MEDIASOURCE-B-Original")
        XCTAssertEqual(session.plan.method, .directStream)
        XCTAssertTrue(session.plan.url.absoluteString.contains("stream.mp4"))
    }

    func testMultipleSourcesWithoutDirectStreamFallsBackToTranscode() throws {
        var response = try decode("playback_multi_source_synthetic.json")
        // 把两个源都改成不支持 DirectStream:应退化到第一个源的转码地址
        response = EmbyPlaybackInfoResponse(
            mediaSources: [
                EmbyMediaSource(
                    id: "MS-A", container: "mkv", supportsDirectStream: false,
                    supportsTranscoding: true,
                    transcodingUrl: "/emby/videos/ITEM/master.m3u8",
                    mediaStreams: nil),
                EmbyMediaSource(
                    id: "MS-B", container: "mp4", supportsDirectStream: nil,
                    supportsTranscoding: true, transcodingUrl: nil, mediaStreams: nil),
            ],
            playSessionID: "PS", errorCode: nil
        )

        let session = try PlaybackDecisionEngine.session(
            for: response, itemID: "ITEM", urlBuilder: urlBuilder, headers: headers)

        XCTAssertEqual(session.plan.mediaSourceID, "MS-A")
        XCTAssertEqual(session.plan.method, .transcode)
    }

    // MARK: - 失败路径

    func testErrorCodeThrowsServerRejected() throws {
        let response = try decode("playback_error_code_synthetic.json")

        assertThrows(
            try PlaybackDecisionEngine.session(
                for: response, itemID: "ITEM", urlBuilder: urlBuilder, headers: headers),
            PlaybackError.serverRejected(code: "NoCompatibleStream")
        )
    }

    func testEmptyMediaSourcesThrowsNoMediaSource() throws {
        let response = try decode("playback_no_media_source_synthetic.json")

        assertThrows(
            try PlaybackDecisionEngine.session(
                for: response, itemID: "ITEM", urlBuilder: urlBuilder, headers: headers),
            PlaybackError.noMediaSource
        )
    }

    func testMissingMediaSourcesKeyIsAlsoNoMediaSource() throws {
        // MediaSources 整个字段缺失(不是空数组)—— 同样按「没有可播源」处理
        let response = EmbyPlaybackInfoResponse(
            mediaSources: nil, playSessionID: "PS", errorCode: nil)

        assertThrows(
            try PlaybackDecisionEngine.session(
                for: response, itemID: "ITEM", urlBuilder: urlBuilder, headers: headers),
            PlaybackError.noMediaSource
        )
    }

    func testNoDirectStreamAndNoTranscodingUrlThrowsNoPlayablePath() throws {
        let response = try decode("playback_no_playable_path_synthetic.json")

        assertThrows(
            try PlaybackDecisionEngine.session(
                for: response, itemID: "ITEM", urlBuilder: urlBuilder, headers: headers),
            PlaybackError.noPlayablePath
        )
    }

    func testMissingPlaySessionIDThrowsMissingRequiredField() throws {
        let response = try decode("playback_missing_session_id_synthetic.json")

        assertThrows(
            try PlaybackDecisionEngine.session(
                for: response, itemID: "ITEM", urlBuilder: urlBuilder, headers: headers),
            PlaybackError.missingRequiredField(name: "PlaySessionId")
        )
    }

    /// 8.1:`MediaSource.Id` 必填 —— 缺失即响应损坏,解码阶段就失败,
    /// 而不是解出一个 id 为空的源继续走下去。
    func testMissingMediaSourceIDFailsDecodingNotCrash() throws {
        let data = try FixtureLoader.data("playback_missing_source_id_synthetic.json")
        XCTAssertThrowsError(try JSONDecoder().decode(EmbyPlaybackInfoResponse.self, from: data))
    }

    /// 可选字段缺失不崩溃:`MediaStreams` / `TranscodingUrl` / `Container`
    /// 都没给时仍能选出播放路径(API_CONTRACT.md 8.1)。
    func testOptionalFieldsMissingStillDecides() throws {
        let response = EmbyPlaybackInfoResponse(
            mediaSources: [
                EmbyMediaSource(
                    id: "MS-MIN", container: nil, supportsDirectStream: true,
                    supportsTranscoding: nil, transcodingUrl: nil, mediaStreams: nil)
            ],
            playSessionID: "PS-MIN",
            errorCode: nil
        )

        let session = try PlaybackDecisionEngine.session(
            for: response, itemID: "ITEM-MIN", urlBuilder: urlBuilder, headers: headers)

        XCTAssertEqual(session.plan.method, .directStream)
        // 容器未知 → 用不带扩展名的 /stream(4.5 两种写法都合法)
        XCTAssertTrue(session.plan.url.absoluteString.contains("/Videos/ITEM-MIN/stream?"))
        XCTAssertNil(session.mediaSource.streamCount(of: "Audio"))
    }

    // MARK: - 辅助

    private func decode(_ fixture: String) throws -> EmbyPlaybackInfoResponse {
        try JSONDecoder().decode(
            EmbyPlaybackInfoResponse.self,
            from: try FixtureLoader.data(fixture))
    }

    private func assertThrows<T>(
        _ expression: @autoclosure () throws -> T,
        _ expected: PlaybackError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try expression()
            XCTFail("应当抛出 \(expected)", file: file, line: line)
        } catch let error as PlaybackError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("抛出了非 PlaybackError: \(error)", file: file, line: line)
        }
    }
}
