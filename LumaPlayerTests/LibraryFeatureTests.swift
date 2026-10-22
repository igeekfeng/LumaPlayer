import XCTest
@testable import LumaPlayer

/// 媒体库:排序 / 筛选的查询参数、已看角标字段、写入后就地更新(API_CONTRACT.md 3.2、3.4)。
final class LibraryFeatureTests: XCTestCase {

    // MARK: - 查询构造

    func testDefaultQueryKeepsOriginalNameSort() {
        let query = LibraryViewModel.makeQuery(
            parentID: "VIEW-1", collectionType: "movies",
            sort: .name, ascending: true, filter: .all,
            startIndex: 0, limit: 60
        )
        XCTAssertEqual(query.sortBy, ["SortName"])
        XCTAssertEqual(query.sortOrder, ["Ascending"])
        XCTAssertEqual(query.filters, [], "「全部」不能拼出空的 Filters 参数")
        XCTAssertEqual(query.includeItemTypes, ["Movie"])
        XCTAssertEqual(query.parentID, "VIEW-1")
    }

    /// 次级键 SortName 恒为升序,否则「加入日期降序」时同一天加入的片子会按名称倒排(3.2)。
    func testSecondaryNameKeyStaysAscending() {
        let query = LibraryViewModel.makeQuery(
            parentID: nil, collectionType: "tvshows",
            sort: .dateAdded, ascending: false, filter: .unplayed,
            startIndex: 60, limit: 60
        )
        XCTAssertEqual(query.sortBy, ["DateCreated", "SortName"])
        XCTAssertEqual(query.sortOrder, ["Descending", "Ascending"])
        XCTAssertEqual(query.filters, ["IsUnplayed"])
        XCTAssertEqual(query.includeItemTypes, ["Series"])
        XCTAssertEqual(query.startIndex, 60)
    }

    func testEverySortUsesContractValuesAndMatchingOrderCount() {
        let allowed: Set<String> = [
            "SortName", "DateCreated", "PremiereDate", "ProductionYear",
            "CommunityRating", "DatePlayed", "Runtime",
        ]
        for sort in LibrarySort.allCases {
            XCTAssertTrue(Set(sort.sortBy).isSubset(of: allowed), "\(sort) 用了契约之外的 SortBy")
            let query = LibraryViewModel.makeQuery(
                parentID: nil, collectionType: nil, sort: sort, ascending: sort.defaultAscending,
                filter: .all, startIndex: 0, limit: 1
            )
            XCTAssertEqual(query.sortBy.count, query.sortOrder.count, "\(sort):SortOrder 与 SortBy 数量不一致")
        }
    }

    func testFiltersUseContractValues() {
        XCTAssertEqual(LibraryFilter.played.filters, ["IsPlayed"])
        XCTAssertEqual(LibraryFilter.unplayed.filters, ["IsUnplayed"])
        XCTAssertEqual(LibraryFilter.favorite.filters, ["IsFavorite"])
        XCTAssertFalse(LibraryFilter.allCases.contains { $0.filters.contains("IsResumable") },
                       "IsResumable 在 4.7.11.0 上未核实(Q28),媒体库不提供")
    }

    func testDatesAndRatingsDefaultToNewestFirst() {
        XCTAssertTrue(LibrarySort.name.defaultAscending)
        XCTAssertFalse(LibrarySort.dateAdded.defaultAscending)
        XCTAssertFalse(LibrarySort.rating.defaultAscending)
    }

    // MARK: - 字段与就地更新

    func testUnplayedItemCountDecodes() throws {
        let item = try JSONDecoder().decode(
            EmbyItem.self,
            from: Data(#"{"Id":"S","Name":"S","Type":"Series","UserData":{"UnplayedItemCount":5,"Played":false}}"#.utf8)
        )
        XCTAssertEqual(item.userData?.unplayedItemCount, 5)
    }

    @MainActor
    func testUpdateUserDataReplacesOnlyThatItem() async throws {
        let items = try [
            JSONDecoder().decode(EmbyItem.self, from: Data(#"{"Id":"A","Name":"A"}"#.utf8)),
            JSONDecoder().decode(EmbyItem.self, from: Data(#"{"Id":"B","Name":"B"}"#.utf8)),
        ]
        let list = PagedItemList { _, _ in PagedFetchResult(items: items, totalRecordCount: 2) }
        list.reload()
        let deadline = Date().addingTimeInterval(2)
        while list.items.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(list.totalCount, 2)

        let played = try JSONDecoder().decode(EmbyUserData.self, from: Data(#"{"Played":true,"PlayCount":1}"#.utf8))
        list.updateUserData(played, forItemID: "B")

        XCTAssertEqual(list.items.map(\.isPlayed), [false, true])
        guard case .loaded(let loaded) = list.state else { return XCTFail("状态应保持 loaded") }
        XCTAssertTrue(loaded[1].isPlayed, "state 里的副本也要同步,否则依赖 state 的视图看不到变化")
    }

    // MARK: - 搜索

    @MainActor
    func testSearchOnlyAsksForVideoTypes() {
        XCTAssertEqual(SearchViewModel.searchItemTypes, ["Movie", "Series", "Episode"])
    }
}
