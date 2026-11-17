import CryptoKit
import XCTest
@testable import LumaPlayer

/// 弹幕匹配精度(`docs/DANMAKU.md` §3):媒体指纹、TMDB 降级层、唯一候选采用。⛔ 零真实网络:全走 `MockEmbyURLProtocol`。
final class DanmakuMatchTests: XCTestCase {

    private let host = DandanplayBase.official.host
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

    private func temporaryURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "LumaMatch-\(name)-\(UUID().uuidString)", directoryHint: .notDirectory)
        temporaryURLs.append(url)
        return url
    }

    private func makeClient() -> DandanplayClient {
        DandanplayClient(
            session: MockEmbyURLProtocol.makeSession(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    private func makeService() async throws -> (DanmakuService, DanmakuBindingStore) {
        let store = CredentialStore(storage: CredentialFileStore(fileURL: temporaryURL("cred")))
        try await store.saveDandanplayCredentials(credentials)
        let bindings = DanmakuBindingStore(fileURL: temporaryURL("bindings"))
        let service = DanmakuService(
            credentials: store, client: makeClient(), bindings: bindings,
            cache: DanmakuCommentCache(directory: temporaryURL("cache")))
        return (service, bindings)
    }

    private func stubComments(_ episodeID: Int64) {
        MockEmbyURLProtocol.stub(
            .json(#"{"count":1,"comments":[{"cid":9,"p":"1.00,1,16777215,u","m":"hi"}]}"#),
            host: host, path: "/api/v2/comment/\(episodeID)")
    }

    private func candidate(
        _ episodeID: Int64, animeID: Int64 = 100, animeTitle: String? = "某番",
        episodeTitle: String?, type: String? = nil
    ) -> DanmakuCandidate {
        DanmakuCandidate(
            episodeID: episodeID, animeID: animeID, animeTitle: animeTitle,
            episodeTitle: episodeTitle, typeDescription: nil, type: type, shift: nil)
    }

    // MARK: - ① 集号 token

    func testEpisodeTokenParsesEveryObservedShape() {
        XCTAssertEqual(DanmakuEpisodeToken.parse("第5话 没用的魔法")?.numberValue, 5)
        XCTAssertEqual(DanmakuEpisodeToken.parse("第 02 集")?.numberValue, 2)
        XCTAssertEqual(DanmakuEpisodeToken.parse("第十二话")?.numberValue, 12)
        XCTAssertEqual(DanmakuEpisodeToken.parse("EP06")?.numberValue, 6)
        XCTAssertEqual(DanmakuEpisodeToken.parse("E07 标题")?.numberValue, 7)
        XCTAssertEqual(DanmakuEpisodeToken.parse("05")?.numberValue, 5)
        // 全角数字
        XCTAssertEqual(DanmakuEpisodeToken.parse("第０３话")?.numberValue, 3)
        // 特典命名空间
        XCTAssertEqual(DanmakuEpisodeToken.parse("S2 圣地巡礼"), .special(kind: .special, index: 2))
        XCTAssertEqual(DanmakuEpisodeToken.parse("C1 OP"), .special(kind: .extra, index: 1))
        XCTAssertEqual(DanmakuEpisodeToken.parse("O3"), .special(kind: .other, index: 3))
    }

    /// ⛔ 不给默认值,更不「标题里出现过这个数字就算」。
    func testEpisodeTokenRefusesToGuess() {
        XCTAssertNil(DanmakuEpisodeToken.parse(nil))
        XCTAssertNil(DanmakuEpisodeToken.parse(""))
        XCTAssertNil(DanmakuEpisodeToken.parse("特别篇"))
        // S01E05 是季集写法,不是特典 S01
        XCTAssertNil(DanmakuEpisodeToken.parse("S01E05"))
        // 1080p 不是集号(行首数字后面跟字母)
        XCTAssertNil(DanmakuEpisodeToken.parse("1080p 某番"))
        // 「第 N 季」是季号,不是集号
        XCTAssertNil(DanmakuEpisodeToken.parse("第2季"))
    }

    // MARK: - ③ 唯一候选

    func testUniqueMatchPicksTheOnlyConsistentEpisode() {
        let candidates = [
            candidate(1, episodeTitle: "第1话"),
            candidate(5, episodeTitle: "第5话"),
            candidate(6, episodeTitle: "第6话"),
        ]
        let target = DanmakuCandidateMatcher.Target(
            title: "某番", episodeNumber: 5, seasonNumber: 1)
        XCTAssertEqual(
            DanmakuCandidateMatcher.uniqueMatch(in: candidates, target: target)?.episodeID, 5)
    }

    /// 两个候选都对得上 = 不猜,交回用户。
    func testUniqueMatchRefusesAmbiguity() {
        let candidates = [
            candidate(5, animeID: 100, episodeTitle: "第5话"),
            candidate(5, animeID: 200, animeTitle: "某番 第二季", episodeTitle: "第5话"),
        ]
        let target = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: candidates, target: target))
    }

    /// 哪怕标题完全一致。
    func testEpisodeMismatchIsRejected() {
        let candidates = [candidate(3, episodeTitle: "第3话")]
        let target = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: candidates, target: target))
    }

    /// `S5` 里的 5 不是第 5 话。
    func testSpecialCandidateDoesNotFillPlainEpisode() {
        let candidates = [candidate(9, episodeTitle: "S5 圣地巡礼")]
        let target = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: candidates, target: target))
    }

    func testSeasonMismatchIsRejected() {
        let firstSeason = [candidate(5, animeTitle: "某番", episodeTitle: "第5话")]
        let target = DanmakuCandidateMatcher.Target(
            title: "某番", episodeNumber: 5, seasonNumber: 2)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: firstSeason, target: target))

        let secondSeason = [candidate(55, animeTitle: "某番 第二季", episodeTitle: "第5话")]
        XCTAssertEqual(
            DanmakuCandidateMatcher.uniqueMatch(in: secondSeason, target: target)?.episodeID, 55)
    }

    /// 集号对上也救不回来。
    func testMovieAndEpisodeAreMutuallyExclusive() {
        let movie = [candidate(7, episodeTitle: "第5话", type: "movie")]
        let episodeTarget = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: movie, target: episodeTarget))

        let episode = [candidate(7, episodeTitle: "第5话", type: "tvseries")]
        let movieTarget = DanmakuCandidateMatcher.Target(title: "某番", isMovie: true)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: episode, target: movieTarget))
    }

    /// 归一后互不包含时不能靠集号撞上就采用。
    func testTitleMismatchIsRejected() {
        let candidates = [candidate(5, animeTitle: "完全无关的日剧", episodeTitle: "第5话")]
        let target = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: candidates, target: target))
    }

    // MARK: - ③ 接进 resolve:唯一候选自动采用

    func testResolveAdoptsUniqueFuzzyCandidate() async throws {
        let (service, bindings) = try await makeService()
        MockEmbyURLProtocol.stub(.json(#"""
            {"success":true,"isMatched":false,"matches":[
              {"episodeId":101,"animeId":100,"animeTitle":"某番","episodeTitle":"第1话","type":"tvseries"},
              {"episodeId":105,"animeId":100,"animeTitle":"某番","episodeTitle":"第5话","type":"tvseries"},
              {"episodeId":106,"animeId":100,"animeTitle":"某番","episodeTitle":"第6话","type":"tvseries"}]}
            """#), host: host, path: "/api/v2/match")
        stubComments(105)

        let query = DanmakuMediaQuery(
            itemKey: "item-5", seriesKey: nil, episodeNumber: 5, seasonNumber: 1,
            title: "某番", matchFileName: "某番 05", fileSize: nil)
        let resolution = try await service.resolve(query, source: .official, durationSeconds: nil)

        guard case .loaded(let loaded) = resolution else { return XCTFail("应当自动采用唯一候选:\(resolution)") }
        XCTAssertEqual(loaded.binding.episodeID, 105)
        // 采用后要写绑定:下一集不再重新匹配
        let binding = await bindings.episode(for: "item-5", source: DanmakuSource.officialID)
        XCTAssertEqual(binding?.episodeID, 105)
    }

    /// ⛔ 不能把「不猜」改成「猜一个」。
    func testResolveStillAsksUserWhenCandidatesRemainAmbiguous() async throws {
        let (service, _) = try await makeService()
        MockEmbyURLProtocol.stub(.json(#"""
            {"success":true,"isMatched":false,"matches":[
              {"episodeId":1,"animeId":100,"animeTitle":"某番","episodeTitle":"第5话","type":"tvseries"},
              {"episodeId":2,"animeId":200,"animeTitle":"某番 第二季","episodeTitle":"第5话","type":"tvseries"}]}
            """#), host: host, path: "/api/v2/match")

        let query = DanmakuMediaQuery(
            itemKey: "item-5", seriesKey: nil, episodeNumber: 5, seasonNumber: nil,
            title: "某番", matchFileName: "某番 05", fileSize: nil)
        let resolution = try await service.resolve(query, source: .official, durationSeconds: nil)
        guard case .needsSelection(let candidates) = resolution else {
            return XCTFail("歧义时应当让用户挑:\(resolution)")
        }
        XCTAssertEqual(candidates.map(\.episodeID), [1, 2])
    }

    // MARK: - ① 指纹接进 /match

    func testMatchRequestUsesRealFingerprintWhenAvailable() async throws {
        let (service, _) = try await makeService()
        MockEmbyURLProtocol.stub(.json(#"""
            {"success":true,"isMatched":true,
             "matches":[{"episodeId":105,"animeId":100,"animeTitle":"某番","episodeTitle":"第5话"}]}
            """#), host: host, path: "/api/v2/match")
        stubComments(105)

        let query = DanmakuMediaQuery(
            itemKey: "item-5", seriesKey: nil, episodeNumber: 5, title: "某番",
            matchFileName: "某番 05", fileSize: 12_345)
        let hash = String(repeating: "a", count: 32)
        _ = try await service.resolve(
            query, source: .official, durationSeconds: 1420,
            matchContext: DanmakuMatchContext(tmdbID: nil, isMovie: false, fileHash: hash))

        let body = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/match")?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["fileHash"] as? String, hash)
        XCTAssertEqual(json["matchMode"] as? String, "hashAndFileName")
        XCTAssertEqual(json["fileSize"] as? Int, 12_345)
    }

    func testMatchRequestFallsBackToPlaceholderWithoutFingerprint() async throws {
        let (service, _) = try await makeService()
        MockEmbyURLProtocol.stub(.json(#"""
            {"success":true,"isMatched":true,
             "matches":[{"episodeId":105,"animeId":100,"animeTitle":"某番","episodeTitle":"第5话"}]}
            """#), host: host, path: "/api/v2/match")
        stubComments(105)

        let query = DanmakuMediaQuery(
            itemKey: "item-5", seriesKey: nil, episodeNumber: 5, title: "某番",
            matchFileName: "某番 05", fileSize: nil)
        _ = try await service.resolve(query, source: .official, durationSeconds: nil)

        let body = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/match")?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["fileHash"] as? String, DandanplayMatchRequest.placeholderFileHash)
        XCTAssertEqual(json["matchMode"] as? String, "fileNameOnly")
    }

    // MARK: - ② TMDB 降级层

    func testTMDBFallbackResolvesEpisodeWhenMatchFails() async throws {
        let (service, _) = try await makeService()
        MockEmbyURLProtocol.stub(.json(#"""
            {"success":true,"isMatched":false,"matches":[]}
            """#), host: host, path: "/api/v2/match")
        MockEmbyURLProtocol.stub(.json(#"""
            {"success":true,"hasMore":false,"animes":[
              {"animeId":100,"animeTitle":"某番","type":"tvseries","episodes":[
                {"episodeId":101,"episodeTitle":"第1话"},
                {"episodeId":105,"episodeTitle":"第5话"}]}]}
            """#), host: host, path: "/api/v2/search/episodes")
        stubComments(105)

        let query = DanmakuMediaQuery(
            itemKey: "item-5", seriesKey: nil, episodeNumber: 5, title: "某番",
            matchFileName: "某番 05", fileSize: nil)
        let resolution = try await service.resolve(
            query, source: .official, durationSeconds: nil,
            matchContext: DanmakuMatchContext(tmdbID: 63926, isMovie: false, fileHash: nil))

        guard case .loaded(let loaded) = resolution else { return XCTFail("应当由 TMDB 层命中:\(resolution)") }
        XCTAssertEqual(loaded.binding.episodeID, 105)

        let search = try XCTUnwrap(
            MockEmbyURLProtocol.recordedRequests().last { $0.url.path == "/api/v2/search/episodes" })
        let components = try XCTUnwrap(URLComponents(url: search.url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "tmdbId" }?.value, "63926")
        XCTAssertEqual(items.first { $0.name == "tmdbIdType" }?.value, "0", "剧集用 0")
        XCTAssertEqual(items.first { $0.name == "episode" }?.value, "5")
        XCTAssertNil(items.first { $0.name == "anime" }, "按 TMDB 查时不传作品名")
    }

    func testTMDBFallbackTriesBothIDSpacesForMovies() async throws {
        let (service, _) = try await makeService()
        MockEmbyURLProtocol.stub(.json(#"{"success":true,"isMatched":false,"matches":[]}"#),
                                 host: host, path: "/api/v2/match")
        // 第一次(电影 ID 空间)空,第二次(电视剧 ID 空间)有结果
        MockEmbyURLProtocol.stub(sequence: [
            .json(#"{"success":true,"hasMore":false,"animes":[]}"#),
            .json(#"""
                {"success":true,"hasMore":false,"animes":[
                  {"animeId":900,"animeTitle":"某剧场版","type":"movie","episodes":[
                    {"episodeId":9001,"episodeTitle":"剧场版"}]}]}
                """#),
        ], host: host, path: "/api/v2/search/episodes")
        stubComments(9001)

        let query = DanmakuMediaQuery(
            itemKey: "movie-1", seriesKey: nil, episodeNumber: nil, title: "某剧场版",
            isMovie: true, matchFileName: "某剧场版", fileSize: nil)
        let resolution = try await service.resolve(
            query, source: .official, durationSeconds: nil,
            matchContext: DanmakuMatchContext(tmdbID: 777, isMovie: true, fileHash: nil))

        guard case .loaded(let loaded) = resolution else { return XCTFail("应当命中:\(resolution)") }
        XCTAssertEqual(loaded.binding.episodeID, 9001)

        let requests = MockEmbyURLProtocol.recordedRequests()
            .filter { $0.url.path == "/api/v2/search/episodes" }
        XCTAssertEqual(requests.count, 2)
        let types = requests.compactMap { request -> String? in
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "tmdbIdType" }?.value
        }
        XCTAssertEqual(types, ["1", "0"], "先按电影 ID 查,再试电视剧 ID")
    }

    /// 没 TMDB ID 时不打 TMDB 那一层。
    func testNoTMDBRequestWithoutID() async throws {
        let (service, _) = try await makeService()
        MockEmbyURLProtocol.stub(.json(#"{"success":true,"isMatched":false,"matches":[]}"#),
                                 host: host, path: "/api/v2/match")
        MockEmbyURLProtocol.stub(.json(#"{"success":true,"hasMore":false,"animes":[]}"#),
                                 host: host, path: "/api/v2/search/episodes")

        let query = DanmakuMediaQuery(
            itemKey: "item-5", seriesKey: nil, episodeNumber: 5, title: "某番",
            matchFileName: "某番 05", fileSize: nil)
        do {
            _ = try await service.resolve(query, source: .official, durationSeconds: nil)
        } catch {
            let paths = MockEmbyURLProtocol.recordedRequests().map { "\($0.url.scheme ?? "")://\($0.url.host() ?? "")\($0.url.path)" }
            return XCTFail("resolve 抛错:\(error) 请求:\(paths)")
        }

        // 第 6 层的关键词搜索会发(见 `testKeywordFallbackResolvesWhenMatchReturnsNothing`),
        // 但那一次不带 tmdbId —— 没有 ID 就不该按 ID 查。
        let searches = MockEmbyURLProtocol.recordedRequests()
            .filter { $0.url.path == "/api/v2/search/episodes" }
        XCTAssertTrue(searches.allSatisfy { request in
            (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .allSatisfy { $0.name != "tmdbId" }
        })
    }

    // MARK: - ③ 关键词搜索降级层(自建源的 `/match` 常常什么都不回)

    /// danmu_api 实测形状:`/match` 回空,弹窗里按 `query.searchKeyword` + 集号一搜就命中。
    /// 自动加载必须搜到、并且只发一次关键词请求。
    func testKeywordFallbackResolvesWhenMatchReturnsNothing() async throws {
        let (service, bindings) = try await makeService()
        MockEmbyURLProtocol.stub(.json(#"{"success":true,"isMatched":false,"matches":[]}"#),
                                 scheme: "http", host: "127.0.0.1", path: "/87654321/api/v2/match")
        MockEmbyURLProtocol.stub(
            .json(#"""
                {"success":true,"hasMore":false,"animes":[
                  {"animeId":100,"animeTitle":"某番","type":"tvseries","episodes":[
                    {"episodeId":105,"episodeTitle":"第5话"}]}]}
                """#),
            scheme: "http", host: "127.0.0.1", path: "/87654321/api/v2/search/episodes")
        MockEmbyURLProtocol.stub(
            .json(#"{"count":1,"comments":[{"cid":9,"p":"1.00,1,16777215,u","m":"hi"}]}"#),
            scheme: "http", host: "127.0.0.1", path: "/87654321/api/v2/comment/105")

        let query = DanmakuMediaQuery(
            itemKey: "item-5", seriesKey: "series-x", episodeNumber: 5, seasonNumber: 1,
            title: "某番", matchFileName: "某番 05", fileSize: nil)
        let baseURL = "http://127.0.0.1:9321/87654321"
        let resolution: DanmakuResolution
        do {
            resolution = try await service.resolve(
                query, source: DanmakuSource(id: "custom-1", name: "自建", kind: .custom(baseURL: baseURL)),
                durationSeconds: nil)
        } catch {
            let paths = MockEmbyURLProtocol.recordedRequests().map { "\($0.url.scheme ?? "")://\($0.url.host() ?? "")\($0.url.path)" }
            return XCTFail("resolve 抛错:\(String(describing: error)) 请求:\(paths)")
        }
        guard case .loaded(let loaded) = resolution else {
            let paths = MockEmbyURLProtocol.recordedRequests().map { "\($0.url.scheme ?? "")://\($0.url.host() ?? "")\($0.url.path)" }
            return XCTFail("关键词层应当命中:-\(resolution) 请求:\(paths)")
        }
        XCTAssertEqual(loaded.binding.episodeID, 105)
        let binding = await bindings.episode(for: "item-5", source: "custom-1")
        XCTAssertEqual(binding?.episodeID, 105, "采用后要写绑定,下一集不再搜")

        let searches = MockEmbyURLProtocol.recordedRequests()
            .filter { $0.url.path == "/87654321/api/v2/search/episodes" }
        XCTAssertEqual(searches.count, 1)
        let items = URLComponents(url: searches[0].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "anime" }?.value, query.searchKeyword,
                       "要和弹窗预填的关键词一致")
        XCTAssertEqual(items.first { $0.name == "episode" }?.value, "5")
        XCTAssertNil(items.first { $0.name == "tmdbId" })
    }

    /// 搜索有结果但对不上这一集:如实交回用户,⛔ 不取第一个。
    func testKeywordFallbackStillAsksUserWhenNothingFits() async throws {
        let (service, _) = try await makeService()
        MockEmbyURLProtocol.stub(.json(#"{"success":true,"isMatched":false,"matches":[]}"#),
                                 host: host, path: "/api/v2/match")
        MockEmbyURLProtocol.stub(
            .json(#"""
                {"success":true,"hasMore":false,"animes":[
                  {"animeId":100,"animeTitle":"某番","type":"tvseries","episodes":[
                    {"episodeId":101,"episodeTitle":"第1话"},
                    {"episodeId":106,"episodeTitle":"第6话"}]}]}
                """#),
            host: host, path: "/api/v2/search/episodes")

        let query = DanmakuMediaQuery(
            itemKey: "item-5", seriesKey: nil, episodeNumber: 5, seasonNumber: 1,
            title: "某番", matchFileName: "某番 05", fileSize: nil)
        let resolution = try await service.resolve(query, source: .official, durationSeconds: nil)
        guard case .needsSelection(let candidates) = resolution else {
            return XCTFail("对不上时应该让用户挑:-\(resolution)")
        }
        XCTAssertEqual(candidates.map(\.episodeID), [101, 106], "候选要带上搜索结果,弹窗里才有东西可选")
    }

    // MARK: - ③ 关键词搜索结果的择优(按服务端排序取第一条门槛全过的)

    /// 同一部剧在 3 个作品下都有第 5 话:取排在最前的那条,而不是「唯一候选」那样直接放弃。
    func testRankedPickUsesServerOrderAmongConsistentCandidates() {
        let candidates = [
            candidate(1, animeID: 100, animeTitle: "某番", episodeTitle: "第5话"),
            candidate(2, animeID: 200, animeTitle: "某番", episodeTitle: "第5话"),
            candidate(3, animeID: 300, animeTitle: "某番", episodeTitle: "第5话"),
        ]
        let target = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5, seasonNumber: 1)
        XCTAssertEqual(DanmakuCandidateMatcher.rankedPick(in: candidates, target: target)?.episodeID, 1)
    }

    /// 排序在前但门槛不过(错集 / 错季 / 同名不同片)的必须跳过。
    func testRankedPickSkipsCandidatesThatFailHardGates() {
        let candidates = [
            candidate(1, animeID: 100, animeTitle: "完全无关的日剧", episodeTitle: "第5话"),
            candidate(2, animeID: 200, animeTitle: "某番 第二季", episodeTitle: "第5话"),
            candidate(3, animeID: 300, animeTitle: "某番", episodeTitle: "第1话"),
            candidate(4, animeID: 400, animeTitle: "某番", episodeTitle: "第5话"),
        ]
        let target = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5, seasonNumber: 1)
        XCTAssertEqual(DanmakuCandidateMatcher.rankedPick(in: candidates, target: target)?.episodeID, 4)
    }

    /// 一条都对不上时不猜。
    func testRankedPickRefusesWhenNothingPassesGates() {
        let candidates = [
            candidate(1, animeID: 100, animeTitle: "某番", episodeTitle: "第1话"),
            candidate(2, animeID: 200, animeTitle: "某番", episodeTitle: "第6话"),
        ]
        let target = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5)
        XCTAssertNil(DanmakuCandidateMatcher.rankedPick(in: candidates, target: target))
    }

    /// 这一集没集号信息(`episodeTitle` 认不出)且只有这一条 → 它就是这一集。
    func testRankedPickAcceptsSoleCandidateWithoutEpisodeInfo() {
        let candidates = [candidate(9, animeID: 100, animeTitle: "某番", episodeTitle: "剧场版")]
        let target = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5)
        XCTAssertEqual(DanmakuCandidateMatcher.rankedPick(in: candidates, target: target)?.episodeID, 9)
    }
}
