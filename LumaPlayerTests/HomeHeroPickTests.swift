import XCTest
@testable import LumaPlayer

/// 首页 hero 铺哪几项(`HomeViewModel.heroPick`,纯函数)。首选随机推荐(`Sections.recommended`),
/// 推荐拿不到(空 / 失败 / 没有带背景图的)时退回「继续观看 → 各库最新」且只给一张;⛔ hero 不能空着。
@MainActor
final class HomeHeroPickTests: XCTestCase {

    // MARK: - 推荐(首选)

    func testRecommendedWinsOverResume() throws {
        let a = try item("A", backdrop: true)
        let b = try item("B", backdrop: true)
        let pick = HomeViewModel.heroPick(
            recommended: .loaded([a, b]),
            views: .loaded([try view("V1", "movies")]),
            resume: .loaded([try item("R1", backdrop: true)]),
            latest: { _ in .idle }
        )
        XCTAssertEqual(pick, .items([a, b]))
    }

    /// hero 整宽铺满,竖版海报会被裁成一条(与 `isHeroCandidate` 同一立场)。
    func testRecommendedFiltersItemsWithoutBackdrop() throws {
        let withBackdrop = try item("A", backdrop: true)
        let pick = HomeViewModel.heroPick(
            recommended: .loaded([
                try item("B", backdrop: false), withBackdrop, try item("C", backdrop: false),
            ]),
            views: .loading,
            resume: .loading,
            latest: { _ in .idle }
        )
        XCTAssertEqual(pick, .items([withBackdrop]))
    }

    func testRecommendedIsCappedAtCarouselLimit() throws {
        let pool = try (0..<8).map { try item("M\($0)", backdrop: true) }
        let pick = HomeViewModel.heroPick(
            recommended: .loaded(pool), views: .loading, resume: .loading, latest: { _ in .idle }
        )
        guard case .items(let picked) = pick else { return XCTFail("应为 .items,实际 \(pick)") }
        XCTAssertEqual(picked.map(\.id), ["M0", "M1", "M2", "M3", "M4"])
    }

    /// 先 `prefix` 再筛的话,真实服务器上多数条目没有 `BackdropImageTags`,hero 会常常只剩一两张。
    func testRecommendedLimitAppliesAfterFiltering() throws {
        let withoutBackdrop = try (0..<2).map { try item("P\($0)", backdrop: false) }
        let withBackdrop = try (0..<6).map { try item("M\($0)", backdrop: true) }
        let pick = HomeViewModel.heroPick(
            recommended: .loaded(withoutBackdrop + withBackdrop),
            views: .loading,
            resume: .loading,
            latest: { _ in .idle }
        )
        guard case .items(let picked) = pick else { return XCTFail("应为 .items,实际 \(pick)") }
        XCTAssertEqual(picked.count, HomeViewModel.heroCarouselLimit)
        XCTAssertTrue(picked.allSatisfy { $0.backdropSource != nil })
    }

    /// 先占住 hero 高度,否则推荐回来又换掉,首屏会跳。
    func testWaitsWhileRecommendedIsLoading() throws {
        let pick = HomeViewModel.heroPick(
            recommended: .loading,
            views: .loaded([try view("V1", "movies")]),
            resume: .loaded([try item("R1", backdrop: true)]),
            latest: { _ in .idle }
        )
        XCTAssertEqual(pick, .pending)
    }

    // MARK: - 退路(推荐拿不到时)

    /// 退路只给一张。
    func testEmptyRecommendationsFallBackToResume() throws {
        let resumeItem = try item("R1", backdrop: true)
        let pick = HomeViewModel.heroPick(
            recommended: .loaded([]),
            views: .loading,
            resume: .loaded([try item("R0", backdrop: false), resumeItem]),
            latest: { _ in .idle }
        )
        XCTAssertEqual(pick, .items([resumeItem]))
    }

    func testFailedRecommendationsFallBackToResume() throws {
        let resumeItem = try item("R1", backdrop: true)
        let pick = HomeViewModel.heroPick(
            recommended: .failed(LoadFailure(message: "x")),
            views: .loading,
            resume: .loaded([resumeItem]),
            latest: { _ in .idle }
        )
        XCTAssertEqual(pick, .items([resumeItem]))
    }

    /// 服务器没刮削过元数据时会这样。
    func testRecommendedWithoutAnyBackdropFallsBack() throws {
        let show = try item("T1", backdrop: true)
        let pick = HomeViewModel.heroPick(
            recommended: .loaded([try item("M1", backdrop: false)]),
            views: .loaded([try view("V1", "tvshows")]),
            resume: .loaded([]),
            latest: { _ in .loaded([show]) }
        )
        XCTAssertEqual(pick, .items([show]))
    }

    /// 不让后面的「最新」先占了 hero 再被换掉。
    func testFallbackWaitsWhileResumeIsLoading() throws {
        let pick = HomeViewModel.heroPick(
            recommended: .loaded([]),
            views: .loaded([try view("V1", "movies")]),
            resume: .loading,
            latest: { _ in .loaded([]) }
        )
        XCTAssertEqual(pick, .pending)
    }

    /// 排在前面的库还在加载就等它。
    func testFallbackWalksLatestInLibraryOrder() throws {
        let views = [try view("V1", "movies"), try view("V2", "tvshows")]
        let movie = try item("M1", backdrop: true)
        let show = try item("T1", backdrop: true)
        let loading: [String: LoadState<[EmbyItem]>] = ["V1": .loading, "V2": .loaded([show])]

        let waiting = HomeViewModel.heroPick(
            recommended: .loaded([]), views: .loaded(views), resume: .loaded([]),
            latest: { loading[$0.id] ?? .idle })
        XCTAssertEqual(waiting, .pending)

        let loaded: [String: LoadState<[EmbyItem]>] = ["V1": .loaded([movie]), "V2": .loaded([show])]
        let pick = HomeViewModel.heroPick(
            recommended: .loaded([]), views: .loaded(views), resume: .loaded([]),
            latest: { loaded[$0.id] ?? .idle })
        XCTAssertEqual(pick, .items([movie]))
    }

    /// 失败的行自己会报错,hero 不跟着空。
    func testFallbackSkipsFailedRows() throws {
        let views = [try view("V1", "movies"), try view("V2", "tvshows")]
        let show = try item("T1", backdrop: true)
        let rows: [String: LoadState<[EmbyItem]>] = [
            "V1": .failed(LoadFailure(message: "x")), "V2": .loaded([show]),
        ]
        let pick = HomeViewModel.heroPick(
            recommended: .failed(LoadFailure(message: "x")),
            views: .loaded(views),
            resume: .failed(LoadFailure(message: "x")),
            latest: { rows[$0.id] ?? .idle }
        )
        XCTAssertEqual(pick, .items([show]))
    }

    /// 分集没有背景图、剧有:父级背景图也算(`backdropSource` 的回退)。
    func testEpisodeWithParentBackdropQualifies() throws {
        let episode = try decode(
            #"{"Id":"E1","Name":"E1","Type":"Episode","ParentBackdropItemId":"S1","ParentBackdropImageTags":["t"]}"#
        )
        let pick = HomeViewModel.heroPick(
            recommended: .loaded([episode]), views: .loading, resume: .loading, latest: { _ in .idle }
        )
        XCTAssertEqual(pick, .items([episode]))
    }

    /// 首页不画 hero,从普通页面顶部开始。
    func testNoneWhenNothingHasBackdrop() throws {
        let posterOnly = try item("M1", backdrop: false)
        let pick = HomeViewModel.heroPick(
            recommended: .loaded([]),
            views: .loaded([try view("V1", "movies")]),
            resume: .loaded([try item("R1", backdrop: false)]),
            latest: { _ in .loaded([posterOnly]) }
        )
        XCTAssertEqual(pick, .none)
    }

    func testMediaLibraryListFailureMeansNone() throws {
        let pick = HomeViewModel.heroPick(
            recommended: .failed(LoadFailure(message: "x")),
            views: .failed(LoadFailure(message: "x")),
            resume: .loaded([]),
            latest: { _ in .idle }
        )
        XCTAssertEqual(pick, .none)
    }

    /// 出不了「最新」行的库(音乐等)不参与退路(`latestViews`)。
    func testFallbackIgnoresNonVideoLibraries() throws {
        let pick = HomeViewModel.heroPick(
            recommended: .loaded([]),
            views: .loaded([try view("V1", "music")]),
            resume: .loaded([]),
            latest: { _ in .loading }
        )
        XCTAssertEqual(pick, .none)
    }

    // MARK: - 辅助

    private func item(_ id: String, backdrop: Bool) throws -> EmbyItem {
        let tags = backdrop ? #","BackdropImageTags":["b-\#(id)"]"# : #","BackdropImageTags":[]"#
        return try decode(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie","ImageTags":{"Primary":"p-\#(id)"}\#(tags)}"#)
    }

    private func decode(_ json: String) throws -> EmbyItem {
        try JSONDecoder().decode(EmbyItem.self, from: Data(json.utf8))
    }

    private func view(_ id: String, _ type: String?) throws -> EmbyView {
        let typeJSON = type.map { #","CollectionType":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(
            EmbyView.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)"\#(typeJSON)}"#.utf8)
        )
    }
}
