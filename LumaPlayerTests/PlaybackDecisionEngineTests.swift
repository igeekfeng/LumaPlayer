import XCTest
@testable import LumaPlayer

/// 播放决策引擎(API_CONTRACT.md 4.4 全分支)。纯函数,全用 fixture,真机难构造的分支在这里覆盖。
/// `_synthetic` 后缀的 fixture 是构造数据,未经真实服务器验证(API_CONTRACT.md 9.4)。
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
        // 整份文件 → 交给内核 seek(与「是不是转码」不是一回事,见 PlaybackSeekStrategy)
        XCTAssertEqual(session.seekStrategy, .clientSeek)
        XCTAssertTrue(session.seekStrategy.allowsSeeking)
        XCTAssertNil(session.seekStrategy.unavailableReason)
        // 4.5:static=true + 输出格式扩展名(DirectStream 输出 == 输入容器)
        XCTAssertEqual(
            session.plan.url.absoluteString,
            "https://emby.test/emby/Videos/ITEM-1/stream.mkv"
            + "?static=true&MediaSourceId=MEDIASOURCE-DIRECT-1"
            + "&PlaySessionId=PLAYSESSION-DIRECT-1"
        )
        XCTAssertEqual(session.mediaSource.streamCount(of: "Video"), 1)
        XCTAssertEqual(session.mediaSource.streamCount(of: "Audio"), 1)
        XCTAssertEqual(session.mediaSource.streamCount(of: "Subtitle"), 1)
    }

    func testPreferredSourceOverridesDefaultSelection() throws {
        let response = EmbyPlaybackInfoResponse(
            mediaSources: [
                EmbyMediaSource(id: "MS-A", name: "1080p", container: "mkv", supportsDirectStream: true,
                                supportsTranscoding: true, transcodingUrl: nil, mediaStreams: nil),
                EmbyMediaSource(id: "MS-B", name: "4K", container: "mkv", supportsDirectStream: true,
                                supportsTranscoding: true, transcodingUrl: nil, mediaStreams: nil),
            ],
            playSessionID: "PS", errorCode: nil
        )

        let byDefault = try PlaybackDecisionEngine.session(
            for: response, itemID: "7", urlBuilder: urlBuilder, headers: headers)
        let chosen = try PlaybackDecisionEngine.session(
            for: response, itemID: "7", urlBuilder: urlBuilder, headers: headers,
            preferredSourceID: "MS-B")
        let unknown = try PlaybackDecisionEngine.session(
            for: response, itemID: "7", urlBuilder: urlBuilder, headers: headers,
            preferredSourceID: "GONE")

        XCTAssertEqual(byDefault.mediaSource.id, "MS-A")
        XCTAssertEqual(chosen.mediaSource.id, "MS-B")
        XCTAssertEqual(chosen.plan.mediaSourceID, "MS-B")
        XCTAssertEqual(chosen.availableSources.map(\.id), ["MS-A", "MS-B"])
        // 指定的版本找不到 → 回到默认规则
        XCTAssertEqual(unknown.mediaSource.id, "MS-A")
    }

    func testSingleSourceHasNoAlternatives() throws {
        let response = try decode("playback_direct_stream_synthetic.json")
        let session = try PlaybackDecisionEngine.session(
            for: response, itemID: "ITEM-1", urlBuilder: urlBuilder, headers: headers)
        XCTAssertTrue(session.availableSources.isEmpty)
    }

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
        // Emby 的转码有解:停流 + StartTimeTicks 重新起流(4.5)
        XCTAssertEqual(session.seekStrategy, .restartStream)
        XCTAssertTrue(session.seekStrategy.allowsSeeking)
    }

    // MARK: - 决策与地址分离(非 Emby 来源靠它复用同一张表)

    /// 百度源拿 `decision(for:)` 的结论、用自己的地址规则拼会话(`dlink` 不能过 `PlaybackURLBuilder`)。
    func testDecisionIsAddressFreeAndMatchesSession() throws {
        let response = try decode("playback_direct_stream_synthetic.json")

        let decision = try PlaybackDecisionEngine.decision(for: response)

        XCTAssertEqual(decision.method, .directStream)
        XCTAssertEqual(decision.playSessionID, "PLAYSESSION-DIRECT-1")
        XCTAssertEqual(decision.source.id, "MEDIASOURCE-DIRECT-1")

        // 媒体源与决策必须一致:「播的是 A、判的是 B」这类错都出在这里
        let session = try PlaybackDecisionEngine.session(
            for: response, itemID: "ITEM-1", urlBuilder: urlBuilder, headers: headers)
        XCTAssertEqual(session.mediaSource.id, decision.source.id)
    }

    /// 空串与缺失同义。⛔ 不让它走到拼地址那一步再报成另一种错(8.1)。
    func testEmptyTranscodingURLIsNoPlayablePathNotURLError() throws {
        let response = EmbyPlaybackInfoResponse(
            mediaSources: [
                EmbyMediaSource(
                    id: "MS-EMPTY", container: "mkv", supportsDirectStream: false,
                    supportsTranscoding: true, transcodingUrl: "", mediaStreams: nil)
            ],
            playSessionID: "PS", errorCode: nil
        )

        assertThrows(
            try PlaybackDecisionEngine.decision(for: response),
            PlaybackError.noPlayablePath
        )
        assertThrows(
            try PlaybackDecisionEngine.session(
                for: response, itemID: "ITEM", urlBuilder: urlBuilder, headers: headers),
            PlaybackError.noPlayablePath
        )
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

    /// 8.1:`MediaSource.Id` 必填,缺失即在解码阶段失败,不解出 id 为空的源继续走。
    func testMissingMediaSourceIDFailsDecodingNotCrash() throws {
        let data = try FixtureLoader.data("playback_missing_source_id_synthetic.json")
        XCTAssertThrowsError(try JSONDecoder().decode(EmbyPlaybackInfoResponse.self, from: data))
    }

    /// `MediaStreams` / `TranscodingUrl` / `Container` 都没给(8.1)。
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
