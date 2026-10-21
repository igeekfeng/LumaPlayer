import XCTest
@testable import LumaPlayer

/// 在线字幕(assrt):端点拼装、响应解码、错误映射、下载与缓存。
///
/// 全部走 `MockEmbyURLProtocol`(按 scheme + host + path 拦截),零真实网络。
/// ⛔ 验不到的部分:真实 assrt 的返回、配额、以及真实字幕挂到画面上 ——
/// 前者要有 API 密钥,后两者要真机(见 `KNOWN_ISSUES.md` B 节)。
final class AssrtSubtitleTests: XCTestCase {

    private static let token = "TESTTOKEN123"

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
    }

    override func tearDown() {
        MockEmbyURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - 端点

    func testSearchURLCarriesKeywordAndClampsCount() throws {
        let url = try XCTUnwrap(AssrtEndpoint.search(keyword: "三体", position: 0, count: 99)
            .url())
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(components.host, "api.assrt.net")
        XCTAssertEqual(components.path, "/v1/sub/search")
        XCTAssertEqual(items["q"], "三体")
        XCTAssertEqual(items["pos"], "0")
        XCTAssertEqual(items["cnt"], "15", "服务端最多 15 条,超出要在这里夹住")
        XCTAssertNil(items["token"], "⛔ token 不进查询串")
    }

    func testDetailURLCarriesID() throws {
        let url = try XCTUnwrap(AssrtEndpoint.detail(id: 602333).url())
        XCTAssertEqual(url.path, "/v1/sub/detail")
        XCTAssertTrue(url.query?.contains("id=602333") == true)
    }

    func testRequestPutsTokenInHeaderAndNotInURL() throws {
        let client = AssrtClient()
        let request = try client.request(
            for: .search(keyword: "三体", position: 0, count: 15), token: Self.token)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.token)")
        XCTAssertFalse(
            request.url?.absoluteString.contains(Self.token) == true,
            "⛔ token 不得出现在 URL 里(会进日志)")
    }

    func testRequestWithoutTokenThrows() {
        let client = AssrtClient()
        XCTAssertThrowsError(try client.request(for: .detail(id: 1), token: "")) { error in
            XCTAssertEqual(error as? AssrtError, .missingToken)
        }
    }

    // MARK: - 挑选文件

    func testPickPrefersSRTAndIgnoresGraphics() throws {
        let files = try [
            ("a.idx", "https://x/a.idx"),
            ("a.ass", "https://x/a.ass"),
            ("a.srt", "https://x/a.srt"),
            ("a.sub", "https://x/a.sub"),
        ].map { AssrtSubtitleFile(fileName: $0.0, url: try XCTUnwrap(URL(string: $0.1))) }

        let picked = SubtitleService.pick(files)
        XCTAssertEqual(picked?.file.fileName, "a.srt")
        XCTAssertEqual(picked?.index, 2)

        XCTAssertNil(
            SubtitleService.pick([files[0], files[3]]),
            "idx / sub 是图形字幕的配套文件,在线这一路不能挑")
    }

    // MARK: - 搜索

    func testSearchSendsBearerTokenAndDecodesResults() async throws {
        MockEmbyURLProtocol.stub(
            .json(Self.searchJSON), host: "api.assrt.net", path: "/v1/sub/search")

        let client = AssrtClient(session: MockEmbyURLProtocol.makeSession())
        let results = try await client.search(keyword: "big", token: Self.token)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, 594897)
        XCTAssertEqual(results[0].title, "老大哥（美版） 第17季第26集/Big Brother US S17E26")
        XCTAssertEqual(results[0].format, "Subrip(srt)")
        XCTAssertEqual(results[0].language, "韩  双语")
        XCTAssertEqual(results[0].releaseSite, "人人影视YYeTs")

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/v1/sub/search"))
        XCTAssertEqual(request.header("Authorization"), "Bearer \(Self.token)")
        XCTAssertFalse(
            request.url.absoluteString.contains(Self.token),
            "⛔ token 不得出现在 URL 里(会进日志)")
    }

    func testSearchRejectsKeywordShorterThanThreeWithoutNetwork() async {
        let client = AssrtClient(session: MockEmbyURLProtocol.makeSession())
        do {
            _ = try await client.search(keyword: "ab", token: Self.token)
            XCTFail("关键词太短必须拒绝")
        } catch let error as AssrtError {
            XCTAssertEqual(error, .keywordTooShort)
            XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty, "不该发请求")
        } catch {
            XCTFail("错误类型不对:\(error)")
        }
    }

    func testSearchMapsBusinessStatusToErrors() async {
        for (status, expected) in [(101, AssrtError.keywordTooShort), (30900, .quotaExceeded), (20001, .invalidToken)] {
            MockEmbyURLProtocol.reset()
            MockEmbyURLProtocol.stub(
                .json(#"{"status":\#(status),"message":"boom"}"#),
                host: "api.assrt.net", path: "/v1/sub/search")
            let client = AssrtClient(session: MockEmbyURLProtocol.makeSession())
            do {
                _ = try await client.search(keyword: "abcdef", token: Self.token)
                XCTFail("status \(status) 应报错")
            } catch let error as AssrtError {
                XCTAssertEqual(error, expected, "status \(status) 映射错了")
            } catch {
                XCTFail("错误类型不对:\(error)")
            }
        }
    }

    // MARK: - 详情

    func testDetailDecodesFileListAndArchive() async throws {
        MockEmbyURLProtocol.stub(
            .json(Self.detailJSON), host: "api.assrt.net", path: "/v1/sub/detail")

        let client = AssrtClient(session: MockEmbyURLProtocol.makeSession())
        let detail = try await client.detail(id: 602333, token: Self.token)

        XCTAssertEqual(detail.id, 602333)
        XCTAssertEqual(detail.files.map(\.fileName), ["a.ass", "a.srt"])
        XCTAssertEqual(detail.files.last?.url.lastPathComponent, "a.srt")
        XCTAssertEqual(detail.archiveFileName, "pack.rar")
        XCTAssertNotNil(detail.archiveURL)
        XCTAssertTrue(detail.hasAnyDownload)
    }

    func testDetailWithoutSubsIsNotFound() async {
        MockEmbyURLProtocol.stub(
            .json(#"{"status":0,"sub":{"subs":[]}}"#),
            host: "api.assrt.net", path: "/v1/sub/detail")
        let client = AssrtClient(session: MockEmbyURLProtocol.makeSession())
        do {
            _ = try await client.detail(id: 1, token: Self.token)
            XCTFail("没有 subs 应当 notFound")
        } catch let error as AssrtError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("错误类型不对:\(error)")
        }
    }

    // MARK: - 下载与缓存(整条链路)

    func testDownloadPrefersSRTAndCachesFile() async throws {
        let (service, directory) = try await makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        MockEmbyURLProtocol.stub(
            .json(Self.detailJSON), host: "api.assrt.net", path: "/v1/sub/detail")
        MockEmbyURLProtocol.stub(
            .bytes(Data(Self.srtText.utf8), statusCode: 200),
            host: "file0.assrt.net", path: "/onthefly/602333/-/1/a.srt")

        let result = SubtitleSearchResult(
            id: 602333, title: "洛东江大决战", videoName: nil, language: "双语",
            format: "Subrip(srt)", releaseSite: nil, uploadTime: nil, voteScore: 0)

        let stored = try await service.download(result)
        XCTAssertEqual(stored.url.pathExtension, "srt", "同时有 ass / srt 时优先 srt")
        let text = try String(data: Data(contentsOf: stored.url), encoding: .utf8)
        XCTAssertEqual(text, Self.srtText)
        XCTAssertEqual(stored.encodingOutcome, .alreadyUTF8)

        // 再下一次:命中缓存,不再请求文件,也不重做编码判断
        let cached = try await service.download(result)
        XCTAssertEqual(cached.url, stored.url)
        XCTAssertNil(cached.encodingOutcome, "缓存命中时不该假装又判断了一次编码")
        let fileRequests = MockEmbyURLProtocol.recordedRequests()
            .filter { $0.url.path.hasSuffix("/a.srt") }
        XCTAssertEqual(fileRequests.count, 1, "第二次应当命中缓存")
    }

    func testDownloadRejectsGraphicsOnlySubtitle() async throws {
        let (service, directory) = try await makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        MockEmbyURLProtocol.stub(
            .json(#"""
            {"status":0,"sub":{"subs":[{"id":1,"filename":"pack.rar","filelist":[
              {"f":"a.idx","s":"10KB","url":"https://file0.assrt.net/a.idx"},
              {"f":"a.sub","s":"900KB","url":"https://file0.assrt.net/a.sub"}
            ]}]}}
            """#),
            host: "api.assrt.net", path: "/v1/sub/detail")

        let result = SubtitleSearchResult(
            id: 1, title: "图形字幕", videoName: nil, language: nil,
            format: "VobSub", releaseSite: nil, uploadTime: nil, voteScore: 0)
        do {
            _ = try await service.download(result)
            XCTFail("只有图形字幕时必须拒绝")
        } catch let error as AssrtError {
            XCTAssertEqual(error, .noTextFile)
        } catch {
            XCTFail("错误类型不对:\(error)")
        }
    }

    func testDownloadWithoutTokenThrowsMissingToken() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "assrt-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        let credentials = CredentialStore(storage: storage)
        let service = SubtitleService(
            credentials: credentials,
            store: SubtitleFileStore(directory: directory),
            client: AssrtClient(session: MockEmbyURLProtocol.makeSession()))
        do {
            _ = try await service.search(keyword: "三体全集")
            XCTFail("没有密钥必须报错")
        } catch let error as AssrtError {
            XCTAssertEqual(error, .missingToken)
        } catch {
            XCTFail("错误类型不对:\(error)")
        }
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
        try? await storage.removeAll()
    }

    // MARK: - 展示与口径

    func testDetailLineSkipsEmptyParts() {
        let full = SubtitleSearchResult(
            id: 1, title: "t", videoName: nil, language: "简体", format: "SRT",
            releaseSite: "字幕组", uploadTime: nil, voteScore: 0)
        XCTAssertEqual(full.detailLine, "简体 · SRT · 字幕组")

        let sparse = SubtitleSearchResult(
            id: 2, title: "t", videoName: nil, language: nil, format: nil,
            releaseSite: nil, uploadTime: nil, voteScore: 0)
        XCTAssertNil(sparse.detailLine, "全空时不显示空括号")
    }

    func testPreferredOrderCoversExactlySupportedExtensions() {
        XCTAssertEqual(
            Set(SubtitleFormats.preferredOrder), SubtitleFormats.fileExtensions,
            "优先级表与格式集合必须一致,否则会挑到挂不上的文件或漏掉某个格式")
        XCTAssertEqual(
            SubtitleFormats.downloadableOrder, ["srt", "ass", "ssa", "vtt"],
            "在线下载不接 .sub(站上的 .sub 多半是 VobSub 的配套图形文件)")
    }

    // MARK: - 工具

    private func makeService() async throws -> (SubtitleService, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "assrt-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        let credentials = CredentialStore(storage: storage)
        try await credentials.saveAssrtToken(Self.token)
        let service = SubtitleService(
            credentials: credentials,
            store: SubtitleFileStore(directory: directory),
            client: AssrtClient(session: MockEmbyURLProtocol.makeSession()))
        return (service, directory)
    }

    private static let srtText = "1\n00:00:01,000 --> 00:00:02,000\n你好\n"

    private static let searchJSON = #"""
    {"status":0,"sub":{"subs":[{
      "native_name":"老大哥（美版） 第17季第26集\/Big Brother US S17E26",
      "videoname":"big.brother.us.s17e26.720p.hdtv.x264-bajskorv",
      "revision":0,"subtype":"Subrip(srt)","upload_time":"2015-08-21 22:11:00",
      "vote_score":0,"id":594897,"release_site":"人人影视YYeTs",
      "lang":{"langlist":{"langdou":true},"desc":"韩  双语"}
    }],"action":"search","keyword":"big","result":"succeed"}}
    """#

    private static let detailJSON = #"""
    {"status":0,"sub":{"result":"succeed","action":"detail","subs":[{
      "id":602333,"filename":"pack.rar","native_name":"洛东江大决战","subtype":"VobSub",
      "url":"https://file0.assrt.net/download/602333/pack.rar?_=1&-=abc&api=1",
      "filelist":[
        {"f":"a.ass","s":"60KB","url":"https://file0.assrt.net/onthefly/602333/-/1/a.ass"},
        {"f":"a.srt","s":"52KB","url":"https://file0.assrt.net/onthefly/602333/-/1/a.srt"}
      ]
    }]}}
    """#
}
