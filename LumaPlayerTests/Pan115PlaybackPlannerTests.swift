import XCTest
@testable import LumaPlayer

/// 115 直链 → 播放决策(`docs/PAN115_API.md` §4)。纯函数,不联网。
///
/// ⛔ 这里不验证「115 真的会返回什么」—— 那些只能拿真实账号验,未做。
/// 本文件验的是:地址逐字节原样、只走 DirectStream、请求头按 `f` 参数给、seek 交给内核。
final class Pan115PlaybackPlannerTests: XCTestCase {

    // MARK: - 地址必须逐字节原样

    /// 115 直链的 `k` 是签名,`URLComponents.queryItems` 往返会把 `%2B` 改成 `+` ⇒ 403(§4.3)。
    func testDirectStreamURLIsPassedThroughByteForByte() throws {
        let raw = "https://cdnfhnfile.115cdn.net/abc/movie.mp4?t=1775898092&u=42&c=0&f=1&k=AbC%2BdEf%3D&v=1"
        let selection = try selection(link: try link(raw))

        XCTAssertEqual(selection.session.plan.url.absoluteString, raw)
        XCTAssertEqual(selection.session.plan.url.query, "t=1775898092&u=42&c=0&f=1&k=AbC%2BdEf%3D&v=1")
        XCTAssertEqual(selection.session.plan.url.scheme, "https")
    }

    // MARK: - 只有一种路线

    /// 115 只做原文件直连;转码 m3u8(§4.2)不在本项目实现里,所以判定表只会选 DirectStream。
    func testEveryPlayableContainerGoesDirectStream() throws {
        for name in ["a.mp4", "a.mkv", "a.mov", "a.flac", "noext"] {
            let selection = try selection(file: makeFile(name: name), link: try link())
            XCTAssertEqual(selection.session.plan.method, .directStream, name)
            XCTAssertEqual(selection.session.seekStrategy, .clientSeek, name)
            XCTAssertTrue(selection.session.seekStrategy.allowsSeeking, name)
        }
    }

    /// 会话 Id 是本地 UUID(115 没有会话上报),媒体源 Id 是 `fid`。
    func testSessionIdentifiersComeFromTheFile() throws {
        let selection = try selection(link: try link())
        XCTAssertEqual(selection.session.plan.playSessionID, "ps-test")
        XCTAssertEqual(selection.session.plan.mediaSourceID, "42")
        // 115 的列表接口不给时长,恒 nil,由内核自己探
        XCTAssertNil(selection.durationSeconds)
        XCTAssertNil(selection.session.mediaSource.mediaStreams, "⛔ 不得虚构轨道:115 不给编码信息")
    }

    // MARK: - 请求头

    /// `f` 空 / `1` 时只带 UA;UA 必须与取链时一致(§4.3)。
    func testHeadersPassThroughFromTheLink() throws {
        let uaOnly = try link("https://cdn.example.com/a.mp4?f=1")
        let selection = try selection(link: uaOnly)
        XCTAssertEqual(selection.session.plan.headers, uaOnly.headers)
        XCTAssertEqual(selection.session.plan.headers["User-Agent"], Pan115UserAgent.value)
        XCTAssertNil(selection.session.plan.headers["Cookie"])
    }

    /// `f=3` 时还要 Cookie —— 这份头由 `Pan115APIClient.playbackHeaders` 拼好,这里只保证不丢。
    func testCookieHeaderSurvivesThePlanner() throws {
        let withCookie = Pan115DownloadLink(
            url: try XCTUnwrap(URL(string: "https://cdn.example.com/a.mp4?f=3")),
            headers: ["User-Agent": Pan115UserAgent.value, "Cookie": "UID=u; CID=c; SEID=s"]
        )
        let selection = try selection(link: withCookie)
        XCTAssertEqual(selection.session.plan.headers["Cookie"], "UID=u; CID=c; SEID=s")
    }

    // MARK: - 合成的响应形状

    func testSyntheticResponseCarriesContainerButNoStreams() throws {
        let response = Pan115PlaybackPlanner.response(
            file: makeFile(name: "a.mkv"), link: try link(), playSessionID: "ps-test")
        let source = try XCTUnwrap(response.mediaSources?.first)
        XCTAssertEqual(source.id, "42")
        XCTAssertEqual(source.container, "mkv")
        XCTAssertNil(source.mediaStreams)
        XCTAssertEqual(source.supportsDirectStream, true)
        // 事实:本项目不实现 115 的转码流
        XCTAssertEqual(source.supportsTranscoding, false)
        XCTAssertNil(source.transcodingUrl)
        XCTAssertEqual(response.playSessionID, "ps-test")
        XCTAssertEqual(response.errorCode, nil)
    }

    func testFileWithoutExtensionHasNoContainer() throws {
        let response = Pan115PlaybackPlanner.response(
            file: makeFile(name: "noext"), link: try link(), playSessionID: "ps-test")
        XCTAssertNil(try XCTUnwrap(response.mediaSources?.first).container)
    }

    // MARK: - 辅助

    private func makeFile(name: String) -> BaiduPanFile {
        BaiduPanFile(
            fsID: 42,
            path: "/影视/\(name)",
            name: name,
            sizeBytes: 1024,
            isDirectory: false,
            category: nil,
            modifiedAt: nil,
            thumbnailURL: nil
        )
    }

    private func link(_ raw: String = "https://cdn.example.com/a.mp4?f=1") throws -> Pan115DownloadLink {
        Pan115DownloadLink(
            url: try XCTUnwrap(URL(string: raw)),
            headers: ["User-Agent": Pan115UserAgent.value]
        )
    }

    /// 与生产路径同一个函数,⛔ 不在测试里手拼。
    private func selection(
        file: BaiduPanFile? = nil,
        link: Pan115DownloadLink
    ) throws -> Pan115StreamSelection {
        try Pan115PlaybackPlanner.selection(
            file: file ?? makeFile(name: "a.mp4"),
            link: link,
            playSessionID: "ps-test"
        )
    }
}
