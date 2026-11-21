import XCTest
@testable import LumaPlayer

/// TMDB 发现端点与解码(`docs/DISCOVERY.md` §3)。
/// 参数名对着官方 OpenAPI 规格(`paths./3/trending/all/{time_window}`、
/// `paths./3/discover/movie`)核实。
final class TMDBDiscoveryTests: XCTestCase {

    // MARK: - 路径

    func testTrendingPathCarriesMediaTypeAndWindow() throws {
        let endpoint = TMDBEndpoint.trending(
            mediaType: .all, window: .week, page: 1, language: "zh-CN")
        let url = try XCTUnwrap(endpoint.url)
        XCTAssertEqual(url.path, "/3/trending/all/week")
        XCTAssertEqual(url.query, "page=1&language=zh-CN")
    }

    func testDiscoverPaths() throws {
        XCTAssertEqual(
            try XCTUnwrap(
                TMDBEndpoint.discoverMovie(TMDBDiscoverQuery(), language: "zh-CN").url).path,
            "/3/discover/movie")
        XCTAssertEqual(
            try XCTUnwrap(
                TMDBEndpoint.discoverTV(TMDBDiscoverQuery(), language: "zh-CN").url).path,
            "/3/discover/tv")
    }

    // MARK: - 查询参数

    func testDiscoverQueryOmitsEmptyValues() {
        let query = TMDBDiscoverQuery()
        let items = query.queryItems
        let names = items.map(\.name)
        XCTAssertEqual(names, ["sort_by", "page", "include_adult"])
        // 官方默认就是 false,但显式传:让「搜到成人内容」这件事不可能发生
        XCTAssertEqual(items.first { $0.name == "include_adult" }?.value, "false")
        // ⛔ 空值不传,不写空串
        XCTAssertFalse(names.contains("with_genres"))
        XCTAssertFalse(names.contains("vote_count.gte"))
    }

    func testDiscoverQueryCarriesAllFilters() {
        var query = TMDBDiscoverQuery()
        query.sortBy = .rating
        query.page = 3
        query.genreIDs = [28, 12]
        query.minimumRating = 7.5
        query.minimumVoteCount = 200
        query.releasedAfter = "2020-01-01"
        query.releasedBefore = "2026-12-31"
        query.originalLanguage = "zh"

        let items = Dictionary(uniqueKeysWithValues: query.queryItems.map { ($0.name, $0.value) })
        XCTAssertEqual(items["sort_by"], "vote_average.desc")
        XCTAssertEqual(items["page"], "3")
        XCTAssertEqual(items["with_genres"], "28,12")
        XCTAssertEqual(items["vote_average.gte"], "7.5")
        XCTAssertEqual(items["vote_count.gte"], "200")
        XCTAssertEqual(items["primary_release_date.gte"], "2020-01-01")
        XCTAssertEqual(items["primary_release_date.lte"], "2026-12-31")
        XCTAssertEqual(items["with_original_language"], "zh")
    }

    // MARK: - 解码

    /// `trending/all` 会混进人物:按 `media_type` 分派,人物丢掉。
    func testTrendingDropsPersonEntries() throws {
        let json = """
        {
          "page": 1,
          "total_pages": 2,
          "total_results": 3,
          "results": [
            {"media_type": "movie", "id": 1, "title": "电影", "release_date": "2026-01-01", "vote_average": 8.1},
            {"media_type": "tv", "id": 2, "name": "剧集", "first_air_date": "2026-02-01"},
            {"media_type": "person", "id": 3, "name": "某人"}
          ]
        }
        """
        let response = try JSONDecoder().decode(
            TMDBDiscoverResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.totalPages, 2)
        XCTAssertEqual(response.page, 1)
        let matches = response.results.compactMap { $0.match(fallbackKind: nil) }
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].kind, .movie)
        XCTAssertEqual(matches[0].title, "电影")
        XCTAssertEqual(matches[1].kind, .tv)
        XCTAssertEqual(matches[1].title, "剧集")
    }

    /// discover 的响应不带 `media_type`:用端点限定的类型兜底
    func testDiscoverUsesFallbackKind() throws {
        let json = """
        {"page": 1, "total_pages": 1, "total_results": 1,
         "results": [{"id": 9, "title": "只有电影的字段"}]}
        """
        let response = try JSONDecoder().decode(
            TMDBDiscoverResponse.self, from: Data(json.utf8))
        let match = try XCTUnwrap(response.results.first?.match(fallbackKind: .movie))
        XCTAssertEqual(match.kind, .movie)
        XCTAssertEqual(match.tmdbID, 9)
    }

    /// 没有 `media_type` 也没有兜底类型 → nil(⛔ 不猜)
    func testMissingMediaTypeWithoutFallbackIsDropped() throws {
        let json = """
        {"page": 1, "total_pages": 1, "total_results": 1, "results": [{"id": 9}]}
        """
        let response = try JSONDecoder().decode(
            TMDBDiscoverResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.results.first?.match(fallbackKind: nil))
    }

    // MARK: - 排序档位

    func testRatingSortRequiresVoteCount() {
        XCTAssertTrue(TMDBDiscoverSort.rating.requiresVoteCount)
        XCTAssertFalse(TMDBDiscoverSort.popularity.requiresVoteCount)
        XCTAssertFalse(TMDBDiscoverSort.newest.requiresVoteCount)
    }
}
