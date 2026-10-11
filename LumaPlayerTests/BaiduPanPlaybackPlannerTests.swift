import XCTest
@testable import LumaPlayer

/// 百度源的播放映射(`BaiduPanPlaybackPlanner`,纯函数,零网络)。
///
/// 断言的核心有两条:
/// 1. **判定只有一处**:路线由 `PlaybackDecisionEngine` 决定,
///    这里不另立一份白名单;
/// 2. **地址原样采用**:`dlink` 的查询串带 `sign`,⛔ 不能过
///    `PlaybackURLBuilder`(那一趟 `URLComponents.queryItems` 往返会把
///    `%2B` 重编码成 `+`,签名一变就是 `31362`)。
final class BaiduPanPlaybackPlannerTests: XCTestCase {

    // MARK: - 地址必须逐字节原样

    /// ★ 这条是本次改造最要紧的回归守卫。`dlink` 里有三样东西一旦被动就废:
    /// `sign`(逐字节校验)、`access_token`、以及 `host`(诊断日志靠它认域名)。
    func testDirectStreamURLIsPassedThroughByteForByte() throws {
        // 故意用一个「含编码字符的签名」:它正是 %2B 会被重编码成 + 的那种输入
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

    /// ⚠️ 与 exp 分支的区别:`main` 用 libmpv,**没有** AVKit 那张能力表,
    /// 所以百度永远给得出 `dlink`(直连)→ 判定一律走直连。
    /// exp 上「mkv → 转码」是 AVKit 的容器能力决定的,不在 main 复现。
    func testEveryPlayableContainerGoesDirectStreamOnMPVCore() throws {
        for name in ["a.mp4", "a.mkv", "a.mov", "a.flac"] {
            let selection = try selection(for: makeFile(name: name))
            XCTAssertEqual(selection.route, .directStream, name)
            XCTAssertEqual(selection.session.plan.method, .directStream, name)
            XCTAssertEqual(selection.session.seekStrategy, .clientSeek, name)
        }
    }

    /// ⛔ 判据必须落在 `seekStrategy` 上,⛔ 不能靠 `plan.method` 反推:
    /// 百度转码流的 `method` 与 Emby 转码流**同名**,但一个拖不动、一个能重起。
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
        // ⚠️ 这个 UA 与 CDN 的 sign 绑死,不是随手取的
        XCTAssertEqual(
            selection.session.plan.headers["User-Agent"], BaiduPanUserAgent.download)
        // 会话 Id 是本地 UUID(百度没有会话上报),媒体源 Id 是 fs_id
        XCTAssertEqual(selection.session.plan.playSessionID, "ps-test")
        XCTAssertEqual(selection.session.plan.mediaSourceID, "42")
        XCTAssertEqual(selection.durationSeconds, 7125)
    }

    // MARK: - 合成的响应形状

    /// 合成的那条源 `mediaSource` **不是服务端响应**,只喂判定表与播放层:
    /// 容器取文件名后缀;⛔ **不塞 `MediaStreams`** —— 百度没有轨道级编码信息,
    /// 而 main 也没有需要它的消费者(没有 AVKit 那套核轨守卫)。
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

    /// 未知扩展名(无容器)时判定仍给直连 —— 容器维判不了不代表不能播。
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

    /// 走 `BaiduPanConnection.appendingAccessToken` 造直连地址 ——
    /// 与生产路径同一个函数,⛔ 不在测试里手拼 (那样就绕开了要验的东西)。
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
