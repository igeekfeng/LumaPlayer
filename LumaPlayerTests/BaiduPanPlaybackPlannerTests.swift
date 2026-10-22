import XCTest
@testable import LumaPlayer

/// 路线只由 `PlaybackDecisionEngine` 决定,不另立白名单;`dlink` 带 `sign`,⛔ 不能过 `PlaybackURLBuilder`(`URLComponents.queryItems` 往返会把 `%2B` 重编码成 `+`,签名失效报 `31362`)。
final class BaiduPanPlaybackPlannerTests: XCTestCase {

    // MARK: - 地址必须逐字节原样

    /// `sign`(逐字节校验)、`access_token`、`host`(诊断日志靠它认域名)一动就废。
    func testDirectStreamURLIsPassedThroughByteForByte() throws {
        // 含编码字符的签名:正是 %2B 会被重编码成 + 的那种输入
        let rawDlink = "https://d.pcs.baidu.com/file/x?fid=42&sign=AbC%2BdEf%3D"
        let selection = try selection(for: makeFile(name: "a.mp4"), rawDlink: rawDlink)

        XCTAssertEqual(selection.route, .directStream)
        let url = selection.session.plan.url
        XCTAssertEqual(
            url.absoluteString,
            "https://d.pcs.baidu.com/file/x?fid=42&sign=AbC%2BdEf%3D&access_token=TOK",
            "dlink 被改写了 —— 签名会因此对不上(31362)")
        XCTAssertEqual(url.host, "d.pcs.baidu.com")
        XCTAssertEqual(url.query, "fid=42&sign=AbC%2BdEf%3D&access_token=TOK")
        // 普通 https:⛔ 不套自定义 scheme / 资源加载器
        XCTAssertEqual(url.scheme, "https")
    }

    // MARK: - 路线与 seek 契约

    /// libmpv 没有 AVKit 那张容器能力表,百度总给得出 `dlink`,一律直连。
    func testEveryPlayableContainerGoesDirectStreamOnMPVCore() throws {
        for name in ["a.mp4", "a.mkv", "a.mov", "a.flac"] {
            let selection = try selection(for: makeFile(name: name))
            XCTAssertEqual(selection.route, .directStream, name)
            XCTAssertEqual(selection.session.plan.method, .directStream, name)
            XCTAssertEqual(selection.session.seekStrategy, .clientSeek, name)
        }
    }

    /// ⛔ 判据必须是 `seekStrategy`,不能靠 `plan.method` 反推:百度与 Emby 转码流 `method` 同名,但一个拖不动、一个能重起。
    func testUnsupportedSeekStrategyBlocksSeekingWithAReason() {
        let strategy = PlaybackSeekStrategy.unsupported(reason: "云端转码流不支持拖动进度")

        XCTAssertFalse(strategy.allowsSeeking)
        XCTAssertEqual(strategy.unavailableReason, "云端转码流不支持拖动进度")
        XCTAssertTrue(PlaybackSeekStrategy.clientSeek.allowsSeeking)
        XCTAssertTrue(PlaybackSeekStrategy.restartStream.allowsSeeking)
        XCTAssertNil(PlaybackSeekStrategy.restartStream.unavailableReason)
    }

    // MARK: - 请求头与会话口径

    func testDirectStreamUsesDownloadUserAgent() throws {
        let selection = try selection(for: makeFile(name: "a.mp4"))
        // 这个 UA 与 CDN 的 sign 绑死
        XCTAssertEqual(
            selection.session.plan.headers["User-Agent"], BaiduPanUserAgent.download)
        // 会话 Id 是本地 UUID(百度没有会话上报),媒体源 Id 是 fs_id
        XCTAssertEqual(selection.session.plan.playSessionID, "ps-test")
        XCTAssertEqual(selection.session.plan.mediaSourceID, "42")
        XCTAssertEqual(selection.durationSeconds, 7125)
    }

    // MARK: - 合成的响应形状

    /// 合成的 `mediaSource` 不是服务端响应;⛔ 不塞 `MediaStreams`:百度没有轨道级编码信息,也没有消费者需要它。
    func testSyntheticResponseCarriesContainerButNoStreams() throws {
        let response = BaiduPanPlaybackPlanner.response(
            file: makeFile(name: "a.mp4"),
            directStreamURL: try XCTUnwrap(URL(string: "https://d.pcs.baidu.com/file/x")),
            streamingURL: try XCTUnwrap(URL(string: "https://pan.baidu.com/rest/2.0/xpan/file?method=streaming")),
            playSessionID: "ps-test"
        )

        let source = try XCTUnwrap(response.mediaSources?.first)
        XCTAssertEqual(source.id, "42")
        XCTAssertEqual(source.container, "mp4")
        XCTAssertNil(source.mediaStreams, "⛔ 不得虚构轨道:百度不给编码信息")
        XCTAssertEqual(source.supportsDirectStream, true)
        XCTAssertEqual(source.supportsTranscoding, true)
        XCTAssertEqual(response.playSessionID, "ps-test")
        XCTAssertEqual(response.errorCode, nil)
    }

    /// 容器维判不了不代表不能播。
    func testFileWithoutExtensionStillGoesDirectStream() throws {
        let file = BaiduPanFile(
            fsID: 42, path: "/apps/L/noext", name: "noext", sizeBytes: 1,
            isDirectory: false, category: 1, modifiedAt: nil, thumbnailURL: nil)
        let selection = try selection(for: file)

        XCTAssertEqual(selection.route, .directStream)
        XCTAssertNil(selection.session.mediaSource.container)
    }

    // MARK: - 辅助

    private func makeFile(name: String) -> BaiduPanFile {
        BaiduPanFile(
            fsID: 42,
            path: "/apps/LumaPlayer/\(name)",
            name: name,
            sizeBytes: 1024,
            isDirectory: false,
            category: nil,
            modifiedAt: nil,
            thumbnailURL: nil
        )
    }

    /// 与生产路径同一个函数,⛔ 不在测试里手拼。
    private func selection(
        for file: BaiduPanFile,
        rawDlink: String = "https://d.pcs.baidu.com/file/x?sign=abc"
    ) throws -> BaiduPanStreamSelection {
        let direct = try XCTUnwrap(
            BaiduPanConnection.appendingAccessToken(to: rawDlink, token: "TOK"))
        let streaming = try XCTUnwrap(BaiduPanEndpoint.streaming(
            accessToken: "TOK", path: file.path,
            type: file.kind == .audio ? .audio : .video,
            probeOnly: false, adToken: nil
        ).url)
        return try BaiduPanPlaybackPlanner.selection(
            file: file,
            directStreamURL: direct,
            streamingURL: streaming,
            durationSeconds: 7125,
            playSessionID: "ps-test"
        )
    }
}
