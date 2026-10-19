import CoreGraphics
import XCTest
@testable import LumaPlayer

/// 弹幕链路:弹弹play 端点 / 签名 / 传输(`DandanplayClient`)、弹幕解析、媒体身份、
/// 匹配编排(`DanmakuService`)、排版(`DanmakuLayout`)、时钟外推(`DanmakuClock`)、预渲染(`DanmakuSprite`)、逐帧诊断。
///
/// ⛔ **零真实网络**:全走 `MockEmbyURLProtocol`。真实弹弹play 调用要等用户在设置里
/// 填了自己的 AppId / AppSecret 才能跑,在此之前按 CLAUDE.md 硬规则 2 标「未在真实服务验证」。
final class DanmakuTests: XCTestCase {

    private let host = DandanplayEndpoint.host
    private let credentials = DandanplayCredentials(appID: "testapp", appSecret: "testsecret")
    private var temporaryURLs: [URL] = []

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
    }

    override func tearDown() {
        MockEmbyURLProtocol.reset()
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        temporaryURLs = []
        super.tearDown()
    }

    private func makeClient() -> DandanplayClient {
        DandanplayClient(session: MockEmbyURLProtocol.makeSession(), now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    private func temporaryURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "LumaPlayerTests-\(name)-\(UUID().uuidString)", directoryHint: .notDirectory)
        temporaryURLs.append(url)
        return url
    }

    // MARK: - 签名(§1)

    /// `base64(sha256(AppId + Timestamp + Path + AppSecret))`。
    /// 期望值由 Python `hashlib` 独立算出,不是拿被测实现自己算的。
    func testSignatureMatchesOfficialFormula() {
        XCTAssertEqual(
            DandanplayClient.signature(
                appID: "testapp", timestamp: 1_700_000_000,
                path: "/api/v2/comment/123450001", appSecret: "testsecret"),
            "xTBDPIDKEWp4x9CBkFe/rUk8O7DQtcInPlSZEKxwNlw=")
    }

    /// 请求带签名三件套;⛔ AppSecret 本身绝不出现在请求里(不用凭证模式)。
    func testRequestCarriesSignatureHeadersButNeverTheSecret() async throws {
        MockEmbyURLProtocol.stub(.json(#"{"count":0,"comments":[]}"#), host: host, path: "/api/v2/comment/123450001")
        _ = try await makeClient().comments(episodeID: 123450001, conversion: .simplified, credentials: credentials)

        let request = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/comment/123450001"))
        XCTAssertEqual(request.header("X-AppId"), "testapp")
        XCTAssertEqual(request.header("X-Timestamp"), "1700000000")
        // 签名路径不含查询串(§1)
        XCTAssertEqual(request.header("X-Signature"), "xTBDPIDKEWp4x9CBkFe/rUk8O7DQtcInPlSZEKxwNlw=")
        XCTAssertNil(request.header("X-AppSecret"))
        XCTAssertFalse(request.headers.values.contains { $0.contains("testsecret") })
        XCTAssertFalse(request.url.absoluteString.contains("testsecret"))
        XCTAssertEqual(request.url.query, "withRelated=true&chConvert=1")
    }

    func testMissingCredentialsDoNotSendAnyRequest() async {
        do {
            _ = try await makeClient().searchEpisodes(
                anime: "测试", episode: nil, credentials: DandanplayCredentials(appID: " ", appSecret: "x"))
            XCTFail("应当抛 credentialsMissing")
        } catch {
            XCTAssertEqual(error as? DandanplayError, .credentialsMissing)
        }
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    // MARK: - 端点(§2 - §5)

    func testSearchEndpointEncodesChineseAndOmitsUnknownEpisode() throws {
        let url = try XCTUnwrap(DandanplayEndpoint.searchEpisodes(anime: "进击的巨人", episode: nil).url)
        XCTAssertEqual(url.path, "/api/v2/search/episodes")
        let query = try XCTUnwrap(url.query)
        XCTAssertFalse(query.contains("进击"), "中文未编码:\(query)")
        XCTAssertFalse(query.contains("episode="), "集数未知时不传:\(query)")

        let withEpisode = try XCTUnwrap(DandanplayEndpoint.searchEpisodes(anime: "EVA", episode: "3").url?.query)
        XCTAssertEqual(withEpisode, "anime=EVA&episode=3")
    }

    /// 可选字段为 nil 时不出现在请求体里(⛔ 不填 0 冒充「文件大小」)。
    func testMatchBodyOmitsUnknownFields() throws {
        let body = try XCTUnwrap(DandanplayEndpoint.match(DandanplayMatchRequest(
            fileName: "某剧 S01E03", fileHash: nil, fileSize: nil, videoDuration: nil,
            matchMode: DandanplayMatchRequest.fileNameOnly)).body())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["fileName"] as? String, "某剧 S01E03")
        XCTAssertEqual(json["matchMode"] as? String, "fileNameOnly")
        XCTAssertNil(json["fileHash"])
        XCTAssertNil(json["fileSize"])
        XCTAssertNil(json["videoDuration"])    }

    func testEndpointNamesExcludeUserContent() {
        XCTAssertEqual(DandanplayEndpoint.searchEpisodes(anime: "私密标题", episode: nil).name, "search/episodes")
        XCTAssertEqual(DandanplayEndpoint.comments(episodeID: 1, withRelated: true, chineseConversion: .none).method, "GET")
        XCTAssertEqual(DandanplayEndpoint.match(DandanplayMatchRequest(
            fileName: "x", fileHash: nil, fileSize: nil, videoDuration: nil, matchMode: "fileNameOnly")).method, "POST")
    }

    // MARK: - 错误映射

    func testForbiddenMapsToCredentialError() async {
        MockEmbyURLProtocol.stub(.status(403), host: host, path: "/api/v2/bangumi/1")
        do {
            _ = try await makeClient().bangumi(animeID: 1, credentials: credentials)
            XCTFail("应当抛错")
        } catch let error as DandanplayError {
            XCTAssertEqual(error, .forbidden(reason: nil))
            XCTAssertTrue(error.needsCredentials)
        } catch {
            XCTFail("错误类型不对:\(error)")
        }
    }

    func testSuccessFalseBecomesAPIError() async {
        MockEmbyURLProtocol.stub(
            .json(#"{"errorCode":1001,"success":false,"errorMessage":"参数错误","animes":null}"#),
            host: host, path: "/api/v2/search/episodes")
        do {
            _ = try await makeClient().searchEpisodes(anime: "ab", episode: nil, credentials: credentials)
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error as? DandanplayError, .api(code: 1001, message: "参数错误", detail: nil))
        }
    }

    /// 参数校验失败时服务端会给 `errorDetail` 指向具体字段,要如实带进用户可见的错误(`ResponseBase`)。
    func testAPIFailureCarriesErrorDetail() async {
        MockEmbyURLProtocol.stub(
            .json(#"""
                {"isMatched":false,"matches":null,"errorCode":2,"success":false,
                 "errorMessage":"一个或多个参数不符合规则","errorDetail":"fileHash"}
                """#),
            host: host, path: "/api/v2/match")
        do {
            _ = try await makeClient().match(
                DandanplayMatchRequest(
                    fileName: "某番 01", fileHash: nil, fileSize: nil, videoDuration: nil,
                    matchMode: DandanplayMatchRequest.fileNameOnly),
                credentials: credentials)
            XCTFail("应当抛错")
        } catch let error as DandanplayError {
            XCTAssertEqual(error, .api(code: 2, message: "一个或多个参数不符合规则", detail: "fileHash"))
            XCTAssertTrue(error.userMessage.contains("fileHash"), error.userMessage)
        } catch {
            XCTFail("错误类型不对:\(error)")
        }
    }

    // MARK: - 弹幕解析(§5)

    func testCommentParsingMapsModesAndColors() {
        let raw = [
            DandanplayComment(cid: 3, p: "12.34,1,16777215,u1", m: "滚动"),
            DandanplayComment(cid: 2, p: "5.00,5,16711680,u2", m: "顶部红"),
            DandanplayComment(cid: 1, p: "5.00,4,255,u3", m: "底部蓝"),
            DandanplayComment(cid: 4, p: "1.0,7,0,u4", m: "未知模式"),
            DandanplayComment(cid: 5, p: "abc,1,0,u5", m: "坏时间"),
            DandanplayComment(cid: 6, p: "1.0,1,0,u6", m: "   "),
            DandanplayComment(cid: 7, p: nil, m: "无参数"),
        ]
        let (comments, dropped) = DanmakuComment.fromDandanplay(raw)
        XCTAssertEqual(dropped, 4)
        XCTAssertEqual(comments.map(\.id), [1, 2, 3], "按时间升序,同一时间按 id")
        XCTAssertEqual(comments[0].mode, .bottom)
        XCTAssertEqual(comments[0].color, 0x0000FF)
        XCTAssertEqual(comments[1].mode, .top)
        XCTAssertEqual(comments[1].color, 0xFF0000)
        XCTAssertEqual(comments[2].mode, .scroll)
        XCTAssertEqual(comments[2].time, 12.34, accuracy: 0.0001)
    }

    // MARK: - 媒体身份

    func testBaiduQueryUsesRealFileNameAndDirectoryAsSeries() {
        let file = BaiduPanFile(
            fsID: 42, path: "/apps/LumaPlayer/某番/某番 S01E05 1080p.mkv", name: "某番 S01E05 1080p.mkv",
            sizeBytes: 1_234_567, isDirectory: false, category: nil, modifiedAt: nil, thumbnailURL: nil)
        let query = DanmakuMediaQuery.make(for: .baiduPan(file: file))
        XCTAssertEqual(query.itemKey, "baidu|fsid:42")
        XCTAssertEqual(query.seriesKey, "baidu|dir:/apps/LumaPlayer/某番")
        XCTAssertEqual(query.episodeNumber, 5)
        XCTAssertEqual(query.matchFileName, "某番 S01E05 1080p", "去掉扩展名,不含目录")
        XCTAssertEqual(query.fileSize, 1_234_567)
    }

    func testBaiduMovieHasNoSeriesKey() {
        let file = BaiduPanFile(
            fsID: 7, path: "/apps/LumaPlayer/电影/某电影 (2020).mp4", name: "某电影 (2020).mp4",
            sizeBytes: nil, isDirectory: false, category: nil, modifiedAt: nil, thumbnailURL: nil)
        let query = DanmakuMediaQuery.make(for: .baiduPan(file: file))
        XCTAssertNil(query.seriesKey)
        XCTAssertNil(query.episodeNumber)
        XCTAssertNil(query.fileSize)
    }

    func testEmbyEpisodeQuerySynthesizesSceneStyleName() throws {
        let item = try JSONDecoder().decode(EmbyItem.self, from: Data(#"""
            {"Id":"ep1","Name":"第五话","Type":"Episode","SeriesId":"s1","SeriesName":"某番",
             "IndexNumber":5,"ParentIndexNumber":2}
            """#.utf8))
        let server = ServerProfile(displayName: "t", baseURL: try XCTUnwrap(URL(string: "https://emby.test")), deviceID: "D")
        let query = DanmakuMediaQuery.make(for: .emby(server: server, item: item))
        XCTAssertEqual(query.matchFileName, "某番 S02E05")
        XCTAssertEqual(query.searchKeyword, "某番")
        XCTAssertEqual(query.episodeNumber, 5)
        XCTAssertEqual(query.itemKey, "emby|\(server.id.uuidString)|ep1")
        XCTAssertEqual(query.seriesKey, "emby|\(server.id.uuidString)|series:s1")
        XCTAssertEqual(DanmakuMediaQuery.synthesizedEpisodeName(series: "X", season: nil, episode: 3), "X 03")
    }

    // MARK: - 编排(DanmakuService)

    private func makeService() async throws -> (DanmakuService, DanmakuBindingStore) {
        let store = CredentialStore(storage: CredentialFileStore(fileURL: temporaryURL("cred")))
        try await store.saveDandanplayCredentials(credentials)
        let bindings = DanmakuBindingStore(fileURL: temporaryURL("bindings"))
        let service = DanmakuService(
            credentials: store, client: makeClient(), bindings: bindings,
            cache: DanmakuCommentCache(directory: temporaryURL("cache")))
        return (service, bindings)
    }

    private let query = DanmakuMediaQuery(
        itemKey: "item-5", seriesKey: "series-x", episodeNumber: 5, seasonNumber: 1,
        title: "某番", matchFileName: "某番 05", fileSize: nil)

    private func stubComments(_ episodeID: Int64) {
        MockEmbyURLProtocol.stub(
            .json(#"{"count":1,"comments":[{"cid":9,"p":"1.00,1,16777215,u","m":"hi"}]}"#),
            host: host, path: "/api/v2/comment/\(episodeID)")
    }

    func testCredentialsMissingIsReportedBeforeAnyRequest() async throws {
        let service = DanmakuService(
            credentials: CredentialStore(storage: CredentialFileStore(fileURL: temporaryURL("cred"))),
            client: makeClient(),
            bindings: DanmakuBindingStore(fileURL: temporaryURL("b")),
            cache: DanmakuCommentCache(directory: temporaryURL("c")))
        do {
            _ = try await service.resolve(query, durationSeconds: nil)
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error as? DandanplayError, .credentialsMissing)
        }
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    /// 精确关联(`isMatched`)直接采用,并记住这一集与这一部剧。
    func testExactMatchLoadsAndBindsSeries() async throws {
        let (service, bindings) = try await makeService()
        MockEmbyURLProtocol.stub(.json(#"""
            {"errorCode":0,"success":true,"isMatched":true,
             "matches":[{"episodeId":1000105,"animeId":10001,"animeTitle":"某番","episodeTitle":"第5话","shift":1.5}]}
            """#), host: host, path: "/api/v2/match")
        stubComments(1000105)

        let resolution = try await service.resolve(query, durationSeconds: 1420.4)
        guard case .loaded(let loaded) = resolution else { return XCTFail("应当直接加载:\(resolution)") }
        XCTAssertEqual(loaded.comments.map(\.text), ["hi"])
        XCTAssertEqual(loaded.binding.shift, 1.5)
        let episodeBinding = await bindings.episode(for: "item-5")
        let seriesBinding = await bindings.series(for: "series-x")
        XCTAssertEqual(episodeBinding?.episodeID, 1000105)
        XCTAssertEqual(seriesBinding?.animeID, 10001)

        let body = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/match")?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["videoDuration"] as? Int, 1420)
        XCTAssertEqual(json["fileHash"] as? String, DandanplayMatchRequest.placeholderFileHash)
        XCTAssertEqual((json["fileHash"] as? String)?.count, 32, "服务端要求 32 位,少一位就回 errorCode 2")
    }

    /// 模糊结果 ⛔ 不自动取第一个,交给用户挑。
    func testFuzzyMatchAsksUserToChoose() async throws {
        let (service, _) = try await makeService()
        MockEmbyURLProtocol.stub(.json(#"""
            {"success":true,"isMatched":false,
             "matches":[{"episodeId":1,"animeId":1,"animeTitle":"A"},{"episodeId":2,"animeId":2,"animeTitle":"B"}]}
            """#), host: host, path: "/api/v2/match")

        let resolution = try await service.resolve(query, durationSeconds: nil)
        guard case .needsSelection(let candidates) = resolution else { return XCTFail("应当让用户挑") }
        XCTAssertEqual(candidates.map(\.episodeID), [1, 2])
        XCTAssertNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/comment/1"))
    }

    /// 剧绑定过作品:其它集按集号在作品剧集列表里对上,⛔ 不再走 `/match`。
    func testSeriesBindingResolvesOtherEpisodesByNumber() async throws {
        let (service, bindings) = try await makeService()
        try await bindings.bind(
            .init(episodeID: 1000101, animeID: 10001, animeTitle: "某番", episodeTitle: "第1话", shift: nil),
            itemKey: "item-1", seriesKey: "series-x")
        MockEmbyURLProtocol.stub(.json(#"""
            {"success":true,"bangumi":{"animeId":10001,"animeTitle":"某番","episodes":[
              {"episodeId":1000101,"episodeTitle":"第1话","episodeNumber":"1"},
              {"episodeId":1000105,"episodeTitle":"第5话","episodeNumber":"5"},
              {"episodeId":1000199,"episodeTitle":"特别篇","episodeNumber":"S1"}]}}
            """#), host: host, path: "/api/v2/bangumi/10001")
        stubComments(1000105)

        let resolution = try await service.resolve(query, durationSeconds: nil)
        guard case .loaded(let loaded) = resolution else { return XCTFail("应当按集号对上:\(resolution)") }
        XCTAssertEqual(loaded.binding.episodeID, 1000105)
        XCTAssertNil(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/match"))
    }

    func testDuplicateEpisodeNumbersAreNotGuessed() {
        let episodes = [
            DandanplayBangumiEpisode(episodeId: 1, episodeTitle: nil, episodeNumber: "5"),
            DandanplayBangumiEpisode(episodeId: 2, episodeTitle: nil, episodeNumber: "05"),
        ]
        XCTAssertNil(DanmakuService.episode(number: 5, in: episodes))
        XCTAssertEqual(DanmakuService.episode(number: 5, in: Array(episodes.prefix(1)))?.episodeId, 1)
    }

    /// 第二次加载同一集走磁盘缓存(官方要求缓存,§6)。
    func testCommentsAreCachedPerEpisode() async throws {
        let (service, bindings) = try await makeService()
        try await bindings.bind(
            .init(episodeID: 77, animeID: 1, animeTitle: nil, episodeTitle: nil, shift: nil),
            itemKey: "item-5", seriesKey: nil)
        stubComments(77)
        _ = try await service.resolve(query, durationSeconds: nil)
        _ = try await service.resolve(query, durationSeconds: nil)
        let fetches = MockEmbyURLProtocol.recordedRequests().filter { $0.url.path == "/api/v2/comment/77" }
        XCTAssertEqual(fetches.count, 1)
    }

    // MARK: - 排版

    private func comment(_ id: Int64, _ time: Double, _ mode: DanmakuComment.Mode = .scroll) -> DanmakuComment {
        DanmakuComment(id: id, time: time, mode: mode, color: 0xFFFFFF, text: "x")
    }

    private let parameters = DanmakuLayout.Parameters(
        viewportWidth: 1000, viewportHeight: 130, fontSize: 20, scrollDuration: 10, displayArea: 1)

    func testLaneCountFollowsDisplayArea() {
        XCTAssertEqual(parameters.laneCount, 5) // 130 / 26
        var half = parameters
        half.displayArea = 0.5
        XCTAssertEqual(half.laneCount, 2)
    }

    /// 同一行的下一条要等上一条尾巴离开右缘(含间距);所有行都占着就丢弃。
    func testScrollingCommentsNeverOverlapAndOverflowIsDropped() {
        let comments = (0..<7).map { comment(Int64($0), 0) }
        let placed = DanmakuLayout.layout(
            comments, widthPerPoint: Array(repeating: 5, count: 7), parameters: parameters)
        XCTAssertEqual(placed.map(\.lane), [0, 1, 2, 3, 4], "5 行同时只能放 5 条")

        // 宽 100pt + 间距 30pt,速度 100pt/s → 1.3 秒后第 0 行空出来
        let later = DanmakuLayout.layout(
            [comment(0, 0), comment(1, 1.0), comment(2, 1.3)],
            widthPerPoint: [5, 5, 5], parameters: parameters)
        XCTAssertEqual(later.map(\.lane), [0, 1, 0])
        XCTAssertEqual(later[0].end, 11, accuracy: 0.0001, "(1000 + 100) / 100")
    }

    func testStaticCommentsUseTheirOwnLanesAndFilters() {
        var params = parameters
        let comments = [comment(0, 0, .top), comment(1, 0, .top), comment(2, 0, .bottom), comment(3, 0)]
        let placed = DanmakuLayout.layout(comments, widthPerPoint: [1, 1, 1, 1], parameters: params)
        XCTAssertEqual(placed.map(\.lane), [0, 1, 0, 0])
        XCTAssertEqual(placed[0].end, DanmakuLayout.staticDuration)

        params.showsTop = false
        params.showsScroll = false
        XCTAssertEqual(
            DanmakuLayout.layout(comments, widthPerPoint: [1, 1, 1, 1], parameters: params).map(\.comment.id), [2])
    }

    func testVisibleWindowFindsOnlyOnScreenComments() {
        let comments = [comment(0, 0), comment(1, 20), comment(2, 30), comment(3, 31)]
        let placed = DanmakuLayout.layout(comments, widthPerPoint: [1, 1, 1, 1], parameters: parameters)
        let lifetime = DanmakuLayout.maxLifetime(of: placed)
        let visible = DanmakuLayout.visible(in: placed, at: 30.1, maxLifetime: lifetime).filter { $0.end > 30.1 }
        XCTAssertEqual(visible.map(\.comment.id), [1, 2])
    }

    // MARK: - 时钟

    @MainActor
    func testClockAbsorbsSmallErrorBySlewingNotJumping() {
        let clock = DanmakuClock()
        let t0 = 1000.0
        clock.update(position: 10, isPaused: false, speed: 2, now: t0)
        XCTAssertEqual(clock.time(at: t0 + 0.1), 10.2, accuracy: 1e-9)

        // 位置报 10.3、外推是 10.4:误差 -0.1。当下位置不跳
        clock.update(position: 10.3, isPaused: false, speed: 2, now: t0 + 0.2)
        XCTAssertEqual(clock.time(at: t0 + 0.2), 10.4, accuracy: 1e-9)
        // 1 秒内匀速吸收:过一半吸收一半
        XCTAssertEqual(clock.time(at: t0 + 0.7), 10.4 + 1.0 - 0.05, accuracy: 1e-9)
        // 吸收完回到倍速,不过冲
        XCTAssertEqual(clock.time(at: t0 + 1.2), 10.4 + 2.0 - 0.1, accuracy: 1e-9)
        XCTAssertEqual(clock.time(at: t0 + 2.2), 10.4 + 4.0 - 0.1, accuracy: 1e-9)
    }

    @MainActor
    func testClockStaysContinuousWhenUpdatesArriveMidSlew() {
        let clock = DanmakuClock()
        let t0 = 1000.0
        clock.update(position: 10, isPaused: false, speed: 1, now: t0)
        clock.update(position: 10.25, isPaused: false, speed: 1, now: t0 + 0.2)
        let before = clock.time(at: t0 + 0.45)
        clock.update(position: 10.4, isPaused: false, speed: 1, now: t0 + 0.45)
        XCTAssertEqual(clock.time(at: t0 + 0.45), before, accuracy: 1e-9, "接力吸收时位置不跳")
    }

    @MainActor
    func testClockStretchesSlewForLargerErrorToCapSpeedChange() {
        let clock = DanmakuClock()
        let t0 = 1000.0
        clock.update(position: 10, isPaused: false, speed: 1, now: t0)
        // 误差 0.3 秒:按 1 秒吸收要变速 30%,拉长到 3 秒、变速封顶 10%
        clock.update(position: 10.5, isPaused: false, speed: 1, now: t0 + 0.2)
        XCTAssertEqual(clock.time(at: t0 + 1.7), 10.2 + 1.5 + 0.15, accuracy: 1e-9)
        XCTAssertEqual(clock.time(at: t0 + 3.2), 10.2 + 3.0 + 0.3, accuracy: 1e-9)
    }

    @MainActor
    func testClockSnapsOnSeekAndStopsWhenPaused() {
        let clock = DanmakuClock()
        let t0 = 1000.0
        clock.update(position: 10, isPaused: false, speed: 2, now: t0)
        // 大误差(seek):直接对齐
        clock.update(position: 100, isPaused: false, speed: 2, now: t0 + 0.4)
        XCTAssertEqual(clock.time(at: t0 + 0.4), 100, accuracy: 1e-9)
        XCTAssertEqual(clock.time(at: t0 + 0.5), 100.2, accuracy: 1e-9)

        // 暂停:时间停住
        clock.update(position: 100, isPaused: true, speed: 2, now: t0 + 0.5)
        XCTAssertEqual(clock.time(at: t0 + 5), 100, accuracy: 1e-9)
        // 恢复:直接对齐到报来的位置
        clock.update(position: 100.1, isPaused: false, speed: 2, now: t0 + 6)
        XCTAssertEqual(clock.time(at: t0 + 6), 100.1, accuracy: 1e-9)
    }

    // MARK: - 预渲染

    func testSpriteAlignsToDevicePixels() {
        XCTAssertEqual(DanmakuSprite.aligned(10.3, scale: 2), 10.5)
        XCTAssertEqual(DanmakuSprite.aligned(10.2, scale: 2), 10)
        XCTAssertEqual(DanmakuSprite.aligned(10.4, scale: 1), 10)
        XCTAssertEqual(DanmakuSprite.aligned(10.4, scale: 0), 10.4)
    }

    func testSpriteOutlineColorFollowsTextBrightness() {
        XCTAssertTrue(DanmakuSprite.usesLightOutline(0x000000))
        XCTAssertTrue(DanmakuSprite.usesLightOutline(0x101040))
        XCTAssertFalse(DanmakuSprite.usesLightOutline(0xFFFFFF))
        XCTAssertFalse(DanmakuSprite.usesLightOutline(0xFF0000))
    }

    func testSpriteRendersFillAndOutlineAtPixelSize() throws {
        let scale: CGFloat = 2
        let rendered = try XCTUnwrap(DanmakuSprite.render(
            text: "弹幕 Test", color: 0xFFFFFF, fontSize: 24, lineHeight: 24 * 1.3, scale: scale))
        // 位图像素与 pt 尺寸严格是 scale 倍:上屏不做重采样
        XCTAssertEqual(CGFloat(rendered.image.width), rendered.size.width * scale)
        XCTAssertEqual(CGFloat(rendered.image.height), rendered.size.height * scale)
        XCTAssertGreaterThanOrEqual(rendered.size.height, 24 * 1.3 + rendered.margin * 2)

        // 读回像素:白字黑边,两种颜色都应出现
        let width = rendered.image.width
        let height = rendered.image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(rendered.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        var fill = 0
        var outline = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 220 {
            if pixels[index] > 220 { fill += 1 } else if pixels[index] < 40 { outline += 1 }
        }
        XCTAssertGreaterThan(fill, 0, "应有白色字形")
        XCTAssertGreaterThan(outline, 0, "应有黑色描边")
    }

    // MARK: - 逐帧诊断

    /// 120 Hz 屏上第 `refresh` 次刷新的一帧(速度 200pt/s):回调在上屏前 8ms 到达;
    /// `timeOffset` 模拟时钟校正带来的额外时间跳动,`late` 模拟回调晚到
    private func frame(
        _ refresh: Int, timeOffset: Double = 0, rate: Double = 1, late: Double = 0, visible: Bool = true
    ) -> DanmakuFrameStats.Frame {
        let target = 5000 + Double(refresh) / 120
        return DanmakuFrameStats.Frame(
            hostTime: target - 0.008 + late, targetTime: target, refreshInterval: 1.0 / 120,
            danmakuTime: 10 + Double(refresh) / 120 * rate + timeOffset,
            velocity: 200, rate: rate, workDuration: 0.001, visibleCount: 3, windowVisible: visible)
    }

    func testFrameStatsUniformMotionHasNoDropsOrJumps() throws {
        var stats = DanmakuFrameStats()
        for i in 0..<120 { stats.record(frame(i, rate: 2)) }
        let summary = try XCTUnwrap(stats.summary(window: 1))
        XCTAssertEqual(summary.frameCount, 120)
        XCTAssertEqual(summary.refreshInterval, 1.0 / 120, accuracy: 1e-9)
        XCTAssertEqual(summary.intervalMedian, 1.0 / 120, accuracy: 1e-9)
        XCTAssertEqual(summary.droppedFrames, 0)
        XCTAssertEqual(summary.redraws, 0)
        XCTAssertEqual(summary.callbackJitterMax, 0, accuracy: 1e-9)
        XCTAssertEqual(summary.marginMin, 0.007, accuracy: 1e-9)
        XCTAssertEqual(summary.jumpCount, 0)
        XCTAssertEqual(summary.snapCount, 0)
        XCTAssertEqual(summary.speedDeviationMax, 0, accuracy: 1e-9)
        XCTAssertEqual(summary.windowVisibleFrames, 120)
    }

    /// 时钟微调速度(每帧多走 2% 的时间)不算跳动,只体现为速度偏差
    func testFrameStatsReportsSlewAsSpeedDeviationNotJumps() throws {
        var stats = DanmakuFrameStats()
        for i in 0..<120 {
            stats.record(frame(i, timeOffset: Double(i) / 120 * 0.02, visible: i < 100))
        }
        let summary = try XCTUnwrap(stats.summary(window: 1))
        XCTAssertEqual(summary.jumpCount, 0)
        XCTAssertEqual(summary.speedDeviationMax, 0.02, accuracy: 1e-6)
        XCTAssertEqual(summary.windowVisibleFrames, 100)
        XCTAssertTrue(summary.description.contains("可见 100/120"))
    }

    /// 回归:整体只跟上每 4 次刷新里的 1 次(120 Hz 屏上 30 帧)。
    /// 按中位数判定会把 33ms 当正常、一帧也数不出来;按刷新间隔判定每次都跳过 3 次刷新。
    func testFrameStatsCountsDropsAgainstRefreshIntervalNotMedian() throws {
        var stats = DanmakuFrameStats()
        for i in stride(from: 0, to: 80, by: 4) { stats.record(frame(i)) }
        let summary = try XCTUnwrap(stats.summary(window: 1))
        XCTAssertEqual(summary.intervalMedian, 4.0 / 120, accuracy: 1e-9)
        XCTAssertEqual(summary.droppedFrames, 19 * 3)
        XCTAssertEqual(summary.redraws, 0)
    }

    func testFrameStatsCountsRedrawAndLateCallback() throws {
        var stats = DanmakuFrameStats()
        for i in 0..<10 { stats.record(frame(i)) }
        // 同一次刷新回调了两次
        stats.record(frame(9))
        // 回调晚到 10ms:做完时这一帧已经上屏
        stats.record(frame(10, late: 0.010))
        let summary = try XCTUnwrap(stats.summary(window: 1))
        XCTAssertEqual(summary.redraws, 1)
        XCTAssertEqual(summary.droppedFrames, 0)
        XCTAssertEqual(summary.marginMin, -0.003, accuracy: 1e-9)
        XCTAssertEqual(summary.callbackJitterMax, 0.010, accuracy: 1e-9)
    }

    func testFrameStatsSeparatesClockJumpFromSeek() throws {
        var stats = DanmakuFrameStats()
        for i in 0..<10 { stats.record(frame(i)) }
        // 时钟校正:时间多走了 0.01 秒 → 横向跳 2pt
        for i in 10..<20 { stats.record(frame(i, timeOffset: 0.01)) }
        // seek:时间一下跳了 30 秒
        for i in 20..<30 { stats.record(frame(i, timeOffset: 30)) }
        let summary = try XCTUnwrap(stats.summary(window: 1))
        XCTAssertEqual(summary.jumpCount, 1)
        XCTAssertEqual(summary.jumpMax, 2, accuracy: 1e-6)
        XCTAssertEqual(summary.snapCount, 1)
    }

    func testFrameStatsSkipsResumeGapAndResetsWindow() throws {
        var stats = DanmakuFrameStats()
        stats.record(frame(0))
        // 暂停 2 秒后恢复:这段间隔不计入
        stats.record(frame(240, timeOffset: -2))
        XCTAssertNil(stats.summary(window: 1))

        stats.record(frame(241, timeOffset: -2))
        XCTAssertEqual(try XCTUnwrap(stats.summary(window: 1)).droppedFrames, 0)

        stats.resetWindow()
        XCTAssertNil(stats.summary(window: 1))
        // 清空后仍以上一帧为起点
        stats.record(frame(242, timeOffset: -2))
        XCTAssertEqual(try XCTUnwrap(stats.summary(window: 1)).frameCount, 1)
    }
}
