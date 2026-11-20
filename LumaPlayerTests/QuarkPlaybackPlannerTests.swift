import XCTest
@testable import LumaPlayer

/// `QuarkPlaybackPlanner` 与 `QuarkSessionPreparer` 的判定与失败档。
/// 夸克只有一条播放路径(原文件直连),⛔ 不走转码判定。
final class QuarkPlaybackPlannerTests: XCTestCase {

    private func makeFile(name: String = "电影.mkv", fsID: UInt64 = 42) -> BaiduPanFile {
        BaiduPanFile(
            fsID: fsID,
            path: "/影视/\(name)",
            name: name,
            sizeBytes: 1024,
            isDirectory: false,
            category: BaiduPanCategory.video,
            modifiedAt: nil,
            thumbnailURL: nil
        )
    }

    private func makeLink(
        _ raw: String = "https://cdn.example.com/v?a=1&k=sign%2Bvalue"
    ) throws -> QuarkDownloadLink {
        QuarkDownloadLink(url: try XCTUnwrap(URL(string: raw)), sizeBytes: 1024, headers: [:])
    }

    /// 只有 DirectStream:`supportsTranscoding` 是 false 的事实(§6.2 的 streaming 不是原画)。
    func testSelectionIsAlwaysDirectStream() throws {
        let selection = try QuarkPlaybackPlanner.selection(
            file: makeFile(), link: makeLink(), playSessionID: "session")
        XCTAssertEqual(selection.session.plan.method, .directStream)
        XCTAssertEqual(selection.session.seekStrategy, .clientSeek)
        // 时长单位未实测,⛔ 不填
        XCTAssertNil(selection.durationSeconds)
    }

    /// ⛔ 地址原样采用:`URLComponents.queryItems` 往返会把 `%2B` 改成 `+`,签名就废了。
    func testURLIsForwardedVerbatim() throws {
        let raw = "https://cdn.example.com/v?a=1&k=sign%2Bvalue"
        let selection = try QuarkPlaybackPlanner.selection(
            file: makeFile(), link: try makeLink(raw), playSessionID: "session")
        XCTAssertEqual(selection.session.plan.url.absoluteString, raw)
    }

    /// TV 端直链自带签名,参考实现都不挂头(§6.1)。
    func testHeadersStayEmpty() throws {
        let selection = try QuarkPlaybackPlanner.selection(
            file: makeFile(), link: makeLink(), playSessionID: "session")
        XCTAssertTrue(selection.session.plan.headers.isEmpty)
    }

    /// 合成响应只有一条源,且 `supportsTranscoding: false`;⛔ 不虚构 `MediaStreams`。
    func testSynthesizedResponseShape() throws {
        let file = makeFile()
        let response = QuarkPlaybackPlanner.response(
            file: file, link: try makeLink(), playSessionID: "session")
        XCTAssertEqual(response.playSessionID, "session")
        let source = try XCTUnwrap(response.mediaSources?.first)
        XCTAssertEqual(source.id, String(file.fsID))
        XCTAssertEqual(source.supportsDirectStream, true)
        XCTAssertEqual(source.supportsTranscoding, false)
        XCTAssertNil(source.transcodingUrl)
        XCTAssertNil(source.mediaStreams)
        // 容器取文件名后缀,只作展示 / 诊断
        XCTAssertEqual(source.container, "mkv")
    }

    /// 缺 `PlaySessionId` 会走判定表的必需字段校验 —— 这里给的是我们自己的,所以必过。
    func testNonPlayableFileStillProducesPlan() throws {
        // 判定表只管「有没有可播路径」,不给播放类型把关(那是来源自己的事)
        let audio = BaiduPanFile(
            fsID: 7, path: "/音乐/a.flac", name: "a.flac", sizeBytes: 10,
            isDirectory: false, category: BaiduPanCategory.audio,
            modifiedAt: nil, thumbnailURL: nil)
        let selection = try QuarkPlaybackPlanner.selection(
            file: audio, link: try makeLink(), playSessionID: "s")
        XCTAssertEqual(selection.session.plan.method, .directStream)
    }

    // MARK: - 会话准备

    /// 有起流位置就如实抛错(⛔ 不从 0 重开,否则进度会被写成 0)。
    func testSessionPreparerRejectsStartTime() async {
        let preparer = QuarkSessionPreparer(
            connection: QuarkConnection(
                credentials: CredentialStore(
                    storage: CredentialFileStore(fileURL: .temporaryCredentialsFile())),
                client: QuarkAPIClient(
                    session: MockEmbyURLProtocol.makeSession(),
                    limiter: QuarkRateLimiter(minimumInterval: .zero))),
            file: makeFile())
        do {
            _ = try await preparer.makeSession(startTimeTicks: 120_000_000)
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            if case .playbackUnsupported = error { return }
            XCTFail("错误的错误档:\(error)")
        } catch is CancellationError {
            XCTFail("不应被取消")
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }
}
