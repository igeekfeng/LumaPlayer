import XCTest
@testable import LumaPlayer

/// `EmbyItem` → `SourceItem` 的映射。暂无消费者(Emby 浏览仍直接用 `EmbyItem`);
/// 先固定下来,免得将来聚合两个来源时有人就地写一份 `if isEmby`。
final class EmbySourceItemMappingTests: XCTestCase {

    private let sourceID = UUID()

    func testMapsMovieFields() throws {
        let item = try decode(#"""
        {
          "Id": "M1",
          "Name": "The Matrix",
          "Type": "Movie",
          "Overview": "A hacker learns the truth.",
          "ProductionYear": 1999,
          "RunTimeTicks": 81600000000,
          "ImageTags": {"Primary": "TAG-1"}
        }
        """#)

        let source = item.asSourceItem(sourceID: sourceID)

        XCTAssertEqual(source.ref, SourceItemRef(sourceID: sourceID, itemID: "M1"))
        XCTAssertEqual(source.title, "The Matrix")
        XCTAssertEqual(source.kind, .movie)
        XCTAssertEqual(source.overview, "A hacker learns the truth.")
        XCTAssertEqual(source.year, 1999)
        // 1 秒 = 10,000,000 ticks(`TickConverter`)
        XCTAssertEqual(source.durationSeconds, 8160)
        XCTAssertEqual(source.metadataOrigin, .server, "Emby 的元数据全部来自服务端")
    }

    /// Emby 里不可直接播 → 映射成「能进去的容器」。
    func testSeriesAndSeasonBecomeContainers() throws {
        let series = try decode(#"{"Id":"S1","Name":"Show","Type":"Series"}"#)
        let season = try decode(#"{"Id":"S1E0","Name":"Season 1","Type":"Season"}"#)

        XCTAssertEqual(series.asSourceItem(sourceID: sourceID).kind, .folder)
        XCTAssertEqual(season.asSourceItem(sourceID: sourceID).kind, .folder)
    }

    func testEpisodeStaysPlayable() throws {
        let episode = try decode(#"{"Id":"E1","Name":"Pilot","Type":"Episode"}"#)

        let source = episode.asSourceItem(sourceID: sourceID)

        XCTAssertEqual(source.kind, .episode)
        XCTAssertTrue(source.kind.isPlayable, "单集是可播的(剧/季才是容器)")
    }

    /// ⛔ 不猜成电影。
    func testUnknownTypeStaysUnknown() throws {
        let item = try decode(#"{"Id":"X1","Name":"?","Type":"SomethingNew"}"#)

        XCTAssertEqual(item.asSourceItem(sourceID: sourceID).kind, .unknown)
    }

    /// ⛔ 不留「有图」的假象:没 tag 去请求只会 404(`API_CONTRACT.md` 3.3)。
    func testNoImageTagMeansNoPoster() throws {
        let item = try decode(#"{"Id":"M1","Name":"No Art","Type":"Movie"}"#)

        XCTAssertNil(item.asSourceItem(sourceID: sourceID).poster)
    }

    func testPosterCarriesEmbyImageSpec() throws {
        let item = try decode(#"""
        {"Id":"M1","Name":"With Art","Type":"Movie","ImageTags":{"Primary":"TAG-9"}}
        """#)

        let poster = try XCTUnwrap(item.asSourceItem(sourceID: sourceID).poster)

        guard case .emby(let spec) = poster.origin else {
            return XCTFail("Emby 的图应该是 .emby origin,实际:\(poster.origin)")
        }
        XCTAssertEqual(spec.serverID, sourceID)
        XCTAssertEqual(spec.itemID, "M1")
        XCTAssertEqual(spec.type, .primary)
        XCTAssertEqual(spec.tag, "TAG-9")
        XCTAssertEqual(poster.ownerID, sourceID)
    }

    private func decode(_ json: String) throws -> EmbyItem {
        try JSONDecoder().decode(EmbyItem.self, from: Data(json.utf8))
    }
}
