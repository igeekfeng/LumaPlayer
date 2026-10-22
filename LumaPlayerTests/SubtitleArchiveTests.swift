import XCTest
@testable import LumaPlayer

/// 字幕压缩包:本地解压(`SubtitleArchiveExtractor`)与 assrt 单文件失败后的整包兜底。
/// 包用 `/usr/bin/bsdtar` 现场打,顺带验了沙箱里能起 bsdtar 子进程。⛔ 验不到真实 RAR 包(libarchive 能读不能写)。
final class SubtitleArchiveTests: XCTestCase {

    private static let token = "TESTTOKEN123"
    private static let srtText = "1\n00:00:01,000 --> 00:00:02,000\n你好\n"
    private static let assText = "[Script Info]\nTitle: test\n"

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
    }

    override func tearDown() {
        MockEmbyURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - 解压

    func testExtractsOnlyTextSubtitlesSortedByPath() async throws {
        let archive = try Self.makeZip([
            "b.SRT": Self.srtText,
            "sub/[Sakurato] x [CHS&CHT].zh-Hans.ass": Self.assText,
            "movie.mkv": "not a subtitle",
            "a.idx": "graphics",
        ])
        let entries = try await SubtitleArchiveExtractor.textSubtitles(in: archive)
        XCTAssertEqual(entries.map(\.fileName), ["b.SRT", "[Sakurato] x [CHS&CHT].zh-Hans.ass"])
        XCTAssertEqual(entries.first?.data, Data(Self.srtText.utf8))
    }

    func testArchiveWithoutTextSubtitlesIsEmpty() async throws {
        let archive = try Self.makeZip(["a.idx": "graphics", "a.sub": "graphics"])
        let entries = try await SubtitleArchiveExtractor.textSubtitles(in: archive)
        XCTAssertTrue(entries.isEmpty)
    }

    func testGarbageIsUnreadable() async {
        do {
            _ = try await SubtitleArchiveExtractor.textSubtitles(in: Data("not an archive".utf8))
            XCTFail("读不开的包必须报错,不能当成「没有字幕」")
        } catch let error as SubtitleArchiveExtractor.ExtractError {
            guard case .unreadable = error else { return XCTFail("错误类型不对:\(error)") }
        } catch {
            XCTFail("错误类型不对:\(error)")
        }
    }

    // MARK: - 错误页识别

    func testDownloadRejectionRecognizesAssrtErrorPages() {
        XCTAssertEqual(
            AssrtClient.downloadRejection(finalURL: URL(string: "https://assrt.net/download/error/L29u")),
            .downloadRejected(expired: false))
        XCTAssertEqual(
            AssrtClient.downloadRejection(finalURL: URL(string: "https://assrt.net/download/failed/L29u")),
            .downloadRejected(expired: true))
        XCTAssertNil(AssrtClient.downloadRejection(
            finalURL: URL(string: "https://file0.assrt.net/download/1/a.rar")))
        XCTAssertNil(AssrtClient.downloadRejection(
            finalURL: URL(string: "https://example.test/download/error/x")), "别家的路径不认")
    }

    // MARK: - 整包兜底(整条链路)

    func testFallsBackToArchiveWhenSingleFileFails() async throws {
        let (service, directory) = try await makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        MockEmbyURLProtocol.stub(.json(Self.detailJSON), host: "api.assrt.net", path: "/v1/sub/detail")
        // 单文件那条:服务端解压坏了(真实是 302 到错误页再 493,这里直接给 493)
        MockEmbyURLProtocol.stub(
            .bytes(Data("<page/>".utf8), statusCode: 493),
            host: "file0.assrt.net", path: "/onthefly/712929/-/1/a.srt")
        MockEmbyURLProtocol.stub(
            .bytes(try Self.makeZip(["pack/a.srt": Self.srtText, "pack/a.ass": Self.assText]), statusCode: 200),
            host: "file0.assrt.net", path: "/download/712929/pack.rar")

        let stored = try await service.download(Self.result)
        XCTAssertEqual(try String(data: Data(contentsOf: stored.url), encoding: .utf8), Self.srtText,
                       "取与 filelist 同名的那个")
        XCTAssertEqual(stored.relativePath, "assrt-712929/a.srt",
                       "与单文件那条路落进同一个组、保留原文件名,下次直接命中")
    }

    func testArchiveOnlyDetailExtractsByPriority() async throws {
        let (service, directory) = try await makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        MockEmbyURLProtocol.stub(.json(#"""
        {"status":0,"sub":{"subs":[{"id":712929,"filename":"pack.rar",
          "url":"http:\/\/file0.assrt.net\/download\/712929\/pack.rar?_=1&-=abc&api=1","filelist":[]}]}}
        """#), host: "api.assrt.net", path: "/v1/sub/detail")
        MockEmbyURLProtocol.stub(
            .bytes(try Self.makeZip(["x.ass": Self.assText, "y.srt": Self.srtText]), statusCode: 200),
            host: "file0.assrt.net", path: "/download/712929/pack.rar")

        let stored = try await service.download(Self.result)
        XCTAssertEqual(stored.relativePath, "assrt-712929/y.srt", "srt 优先,保留包里的原文件名")
    }

    // MARK: - 辅助

    private static let result = SubtitleSearchResult(
        id: 712929, title: "一拳超人", videoName: nil, language: nil,
        format: "ASS", releaseSite: nil, uploadTime: nil, voteScore: 0)

    private static let detailJSON = #"""
    {"status":0,"sub":{"subs":[{
      "id":712929,"filename":"pack.rar",
      "url":"http:\/\/file0.assrt.net\/download\/712929\/pack.rar?_=1&-=abc&api=1",
      "filelist":[
        {"f":"a.ass","s":"41KB","url":"http:\/\/file0.assrt.net\/onthefly\/712929\/-\/1\/a.ass?_=1&-=abc&api=1"},
        {"f":"a.srt","s":"41KB","url":"http:\/\/file0.assrt.net\/onthefly\/712929\/-\/1\/a.srt?_=1&-=abc&api=1"}
      ]
    }]}}
    """#

    private func makeService() async throws -> (SubtitleService, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "assrt-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        let credentials = CredentialStore(storage: CredentialFileStore(fileURL: .temporaryCredentialsFile()))
        try await credentials.saveAssrtToken(Self.token)
        let service = SubtitleService(
            credentials: credentials,
            store: SubtitleFileStore(directory: directory),
            client: AssrtClient(session: MockEmbyURLProtocol.makeSession()))
        return (service, directory)
    }

    /// 用 bsdtar 现场打一个 zip(键是包内路径)。
    private static func makeZip(_ files: [String: String]) throws -> Data {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "zip-src-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "src", directoryHint: .isDirectory)
        for (path, text) in files {
            let url = source.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let zip = root.appending(path: "out.zip")
        let process = Process()
        process.executableURL = SubtitleArchiveExtractor.bsdtarURL
        process.arguments = ["-a", "-c", "-f", zip.path, "-C", source.path, "."]
        process.environment = ["LC_ALL": "en_US.UTF-8"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "打包失败")
        return try Data(contentsOf: zip)
    }
}
