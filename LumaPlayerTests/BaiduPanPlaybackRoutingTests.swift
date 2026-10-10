import XCTest
@testable import LumaPlayer

/// 百度源的播放路由(过 Rust 决策器,⛔ 不在这里另立一份能力表)。
///
/// 断言的核心是**路线选择的依据**:
/// - 容器是 AVKit 原生的(mp4)→ 直连(`dlink`),客户端 seek;
/// - 容器不是原生的(mkv)→ 云端转码 HLS,且**不能拖进度**。
///
/// 判定用的是 `luma-emby::decision` 与同一张能力表(`avkit-capability`),
/// 所以这里的断言同时也是「百度源没有走第二条判定路径」的守卫。
final class BaiduPanPlaybackRoutingTests: XCTestCase {

    // MARK: - 直连

    func testMP4GoesDirectStreamOverPlainHTTPS() throws {
        let file = makeFile(name: "a.mp4", category: nil)
        let selection = try selection(for: file)

        XCTAssertEqual(selection.route, .directStream)
        XCTAssertEqual(selection.session.plan.method, .directStream)
        // ⛔ 不套自定义 scheme / 资源加载器:实测那条路 AVFoundation 只肯
        //    「从 0 读到尾」,而普通 https + 认证头起播/seek 都正常(文档 §11.10)
        XCTAssertEqual(selection.session.plan.url.scheme, "https")
        XCTAssertEqual(selection.session.seekStrategy, .clientSeek)
        // ⚠️ 这个 UA 与 CDN 的 sign 绑死(换 UA 立刻 31362),不是随手取的
        XCTAssertEqual(selection.session.plan.headers["User-Agent"], "pan.baidu.com")
        // 会话 Id 是本地 UUID(百度没有会话上报接口),媒体源 Id 是 fs_id
        XCTAssertEqual(selection.session.plan.playSessionID, "ps-test")
        XCTAssertEqual(selection.session.plan.mediaSourceID, "42")
        XCTAssertEqual(selection.durationSeconds, 7125)
    }

    /// `dlink` 必须**原样**交给内核:查询串里有 `sign`(截断 / 重新编码 → `31362`)
    /// 与 `access_token`,`host` 也要留着 —— 诊断日志靠它认域名。
    func testDirectStreamURLIsPassedThroughUnchanged() throws {
        let file = makeFile(name: "a.mp4", category: nil)
        let selection = try selection(for: file)
        let url = selection.session.plan.url
        XCTAssertEqual(url.host, "d.baidupcs.com")
        XCTAssertEqual(url.path, "/file/x")
        XCTAssertEqual(url.query, "sign=abc&access_token=TOK")
    }

    // MARK: - 转码

    func testMKVGoesTranscodeAndCannotBeScrubbed() throws {
        let file = makeFile(name: "a.mkv", category: nil)
        let selection = try selection(for: file)

        XCTAssertEqual(selection.route, .transcode)
        XCTAssertEqual(selection.session.plan.method, .transcode)
        // 转码流也是普通 https:分片是绝对地址,播放器直接取,不走任何代理
        XCTAssertEqual(selection.session.plan.url.scheme, "https")
        // ⛔ 判据必须落在 seekStrategy 上:`method=streaming` 没有起流位置参数,
        //    重新请求只会从头开始(§5.4)。
        guard case .unsupported(let reason) = selection.session.seekStrategy else {
            return XCTFail("百度转码流应判成不可拖动,实际:\(selection.session.seekStrategy)")
        }
        XCTAssertTrue(reason.contains("拖动"), "理由要说清是拖不动:\(reason)")
        XCTAssertFalse(selection.session.seekStrategy.allowsSeeking)
        let ua = try XCTUnwrap(selection.session.plan.headers["User-Agent"])
        XCTAssertTrue(ua.hasPrefix("xpanvideo;"), "转码流要 xpanvideo 的 UA:\(ua)")
    }

    // MARK: - 核轨口径

    /// 视频文件要求视频 + 音频两轨都在:这是抓住「有画面没声音」的手段
    /// (文档 §2.1 实测:AVFoundation 遇到不认识的编码是**静默删轨**)。
    func testVideoFileRequiresBothVideoAndAudioTracks() {
        let streams = BaiduPanPlaybackPlanner.tracks(for: .video)
        XCTAssertEqual(streams.count, 2)
        XCTAssertEqual(streams.map(\.type), ["Video", "Audio"])
        // ⛔ codec 一律 nil:百度不给轨道级编码信息,填一个猜的值比不填危险
        XCTAssertTrue(streams.allSatisfy { $0.codec == nil })
    }

    func testAudioFileRequiresOnlyAudioTrack() {
        let streams = BaiduPanPlaybackPlanner.tracks(for: .audio)
        XCTAssertEqual(streams.map(\.type), ["Audio"])
    }

    func testUnplayableKindRequiresNothing() {
        XCTAssertTrue(BaiduPanPlaybackPlanner.tracks(for: .other).isEmpty)
    }

    // MARK: - 合成的 PlaybackInfo

    /// 决策输入**不带** `MediaStreams`:百度没有轨道级编码信息,塞一条没有
    /// `codec` 的轨会被能力表判成「需要转码」,把每个文件都推去转码。
    func testSyntheticPlaybackInfoOmitsMediaStreams() throws {
        let json = try BaiduPanPlaybackPlanner.syntheticPlaybackInfoJSON(
            file: makeFile(name: "a.mp4", category: nil),
            directStreamURL: URL(string: "https://d.baidupcs.com/file/x")!,
            streamingURL: URL(string: "https://pan.baidu.com/rest/2.0/xpan/file?method=streaming")!,
            durationSeconds: 7125,
            playSessionID: "ps-test"
        )
        XCTAssertTrue(json.contains("\"PlaySessionId\":\"ps-test\""))
        XCTAssertTrue(json.contains("\"Container\":\"mp4\""))
        XCTAssertTrue(json.contains("\"DirectStreamUrl\""))
        XCTAssertTrue(json.contains("\"TranscodingUrl\""))
        XCTAssertTrue(json.contains("\"RunTimeTicks\":71250000000"))
        XCTAssertFalse(json.contains("MediaStreams"), "⛔ 不得塞 MediaStreams:\(json)")
    }

    /// 未知扩展名(无 Container)时,决策只按容器维判不了 → 仍给直连,
    /// 由起播后的核轨兜住真正的失败(已登记 KNOWN_ISSUES)。
    func testFileWithoutExtensionDoesNotFailDecision() throws {
        let file = BaiduPanFile(
            fsID: 42, path: "/apps/L/noext", name: "noext", sizeBytes: 1,
            isDirectory: false, category: 1, modifiedAt: nil, thumbnailURL: nil)
        let selection = try selection(for: file)
        XCTAssertEqual(selection.route, .directStream)
    }

    // MARK: - 辅助

    private func makeFile(name: String, category: Int?) -> BaiduPanFile {
        BaiduPanFile(
            fsID: 42,
            path: "/apps/LumaPlayer/\(name)",
            name: name,
            sizeBytes: 1024,
            isDirectory: false,
            category: category,
            modifiedAt: nil,
            thumbnailURL: nil
        )
    }

    private func selection(for file: BaiduPanFile) throws -> BaiduPanStreamSelection {
        let direct = try XCTUnwrap(BaiduPanConnection.appendingAccessToken(
            to: "https://d.baidupcs.com/file/x?sign=abc", token: "TOK"))
        let streaming = try XCTUnwrap(BaiduPanEndpoint.streaming(
            accessToken: "TOK", path: file.path,
            type: file.kind == .audio ? .audio : .video,
            probeOnly: false, adToken: nil
        ).url)
        let decision = try BaiduPanPlaybackPlanner.decision(
            file: file,
            directStreamURL: direct,
            streamingURL: streaming,
            durationSeconds: 7125,
            playSessionID: "ps-test"
        )
        return try BaiduPanPlaybackPlanner.selection(
            file: file,
            decision: decision,
            directStreamURL: direct,
            streamingURL: streaming,
            durationSeconds: 7125
        )
    }
}
