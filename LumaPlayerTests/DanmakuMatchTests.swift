import CryptoKit
import XCTest
@testable import LumaPlayer

/// 弹幕匹配精度的三块新能力(`docs/DANMAKU.md` §3):
///
/// 1. **媒体指纹**(`DanmakuFingerprint`):前 16 MiB 的 MD5,只在直连流上算,
///    严格校验 `Content-Range`,拿不到就返回 nil;
/// 2. **TMDB 降级层**(`DanmakuService.searchByTMDB`):`/match` 落空后按
///    `search/episodes?tmdbId=` 再查一次;
/// 3. **唯一候选采用**(`DanmakuCandidateMatcher` + `DanmakuEpisodeToken`):
///    模糊候选里只有一集确定对得上时才自动采用,否则仍然交给用户。
///
/// ⛔ **零真实网络**:全走 `MockEmbyURLProtocol`。
final class DanmakuMatchTests: XCTestCase {

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

    /// 认不出就返回 nil —— ⛔ 不给默认值,更不「标题里出现过这个数字就算」。
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

    /// 两个候选都对得上 = 不猜,交回用户(与「⛔ 不自动取第一个模糊结果」同一立场)。
    func testUniqueMatchRefusesAmbiguity() {
        let candidates = [
            candidate(5, animeID: 100, episodeTitle: "第5话"),
            candidate(5, animeID: 200, animeTitle: "某番 第二季", episodeTitle: "第5话"),
        ]
        let target = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: candidates, target: target))
    }

    /// 集号冲突是硬门槛:第 3 话不能顶替第 5 话,哪怕标题完全一致。
    func testEpisodeMismatchIsRejected() {
        let candidates = [candidate(3, episodeTitle: "第3话")]
        let target = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: candidates, target: target))
    }

    /// 特典候选不得顶替正片(`S5` 里的 5 不是第 5 话)。
    func testSpecialCandidateDoesNotFillPlainEpisode() {
        let candidates = [candidate(9, episodeTitle: "S5 圣地巡礼")]
        let target = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: candidates, target: target))
    }

    /// 季号冲突:目标第二季第 5 话,候选是第一季第 5 话 → 出局。
    func testSeasonMismatchIsRejected() {
        let firstSeason = [candidate(5, animeTitle: "某番", episodeTitle: "第5话")]
        let target = DanmakuCandidateMatcher.Target(
            title: "某番", episodeNumber: 5, seasonNumber: 2)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: firstSeason, target: target))

        let secondSeason = [candidate(55, animeTitle: "某番 第二季", episodeTitle: "第5话")]
        XCTAssertEqual(
            DanmakuCandidateMatcher.uniqueMatch(in: secondSeason, target: target)?.episodeID, 55)
    }

    /// 剧场版与剧集是不同作品:类型不匹配直接出局,集号对上也救不回来。
    func testMovieAndEpisodeAreMutuallyExclusive() {
        let movie = [candidate(7, episodeTitle: "第5话", type: "movie")]
        let episodeTarget = DanmakuCandidateMatcher.Target(title: "某番", episodeNumber: 5)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: movie, target: episodeTarget))

        let episode = [candidate(7, episodeTitle: "第5话", type: "tvseries")]
        let movieTarget = DanmakuCandidateMatcher.Target(title: "某番", isMovie: true)
        XCTAssertNil(DanmakuCandidateMatcher.uniqueMatch(in: episode, target: movieTarget))
    }

    /// 标题完全对不上(归一后互不包含)时不能靠集号撞上就采用。
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
        let resolution = try await service.resolve(query, durationSeconds: nil)

        guard case .loaded(let loaded) = resolution else { return XCTFail("应当自动采用唯一候选:\(resolution)") }
        XCTAssertEqual(loaded.binding.episodeID, 105)
        // 采用后要写绑定:下一集不再重新匹配
        let binding = await bindings.episode(for: "item-5")
        XCTAssertEqual(binding?.episodeID, 105)
    }

    /// 仍然模糊时交回用户 —— 新逻辑不能把「不猜」改成「猜一个」。
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
        let resolution = try await service.resolve(query, durationSeconds: nil)
        guard case .needsSelection(let candidates) = resolution else {
            return XCTFail("歧义时应当让用户挑:\(resolution)")
        }
        XCTAssertEqual(candidates.map(\.episodeID), [1, 2])
    }

    // MARK: - ① 指纹接进 /match

    /// 有指纹 → `hashAndFileName` + 真 Hash;没有 → `fileNameOnly` + 占位串。
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
            query, durationSeconds: 1420,
            matchContext: DanmakuMatchContext(tmdbID: nil, isMovie: false, fileHash: hash))

        let body = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/match")?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["fileHash"] as? String, hash)
        XCTAssertEqual(json["matchMode"] as? String, "hashAndFileName")
        XCTAssertEqual(json["fileSize"] as? Int, 12_345)
    }

    /// 没有指纹时行为与改动前完全一致(占位串 + fileNameOnly)。
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
        _ = try await service.resolve(query, durationSeconds: nil)

        let body = try XCTUnwrap(MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/match")?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["fileHash"] as? String, DandanplayMatchRequest.placeholderFileHash)
        XCTAssertEqual(json["matchMode"] as? String, "fileNameOnly")
    }

    // MARK: - ② TMDB 降级层

    /// `/match` 落空 + 有 TMDB ID → 按 `tmdbId` 查一次,按集号挑唯一命中。
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
            query, durationSeconds: nil,
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

    /// 电影用 `tmdbIdType=1`;剧集那套查不到时会再试电影那套。
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
            query, durationSeconds: nil,
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

    /// 没有 TMDB ID 时不发 `/search/episodes`(不多打一次服务器)。
    func testNoTMDBRequestWithoutID() async throws {
        let (service, _) = try await makeService()
        MockEmbyURLProtocol.stub(.json(#"{"success":true,"isMatched":false,"matches":[]}"#),
                                 host: host, path: "/api/v2/match")

        let query = DanmakuMediaQuery(
            itemKey: "item-5", seriesKey: nil, episodeNumber: 5, title: "某番",
            matchFileName: "某番 05", fileSize: nil)
        _ = try await service.resolve(query, durationSeconds: nil)

        XCTAssertTrue(
            MockEmbyURLProtocol.recordedRequests()
                .allSatisfy { $0.url.path != "/api/v2/search/episodes" })
    }
}
