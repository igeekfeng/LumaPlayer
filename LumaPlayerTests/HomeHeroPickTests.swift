import XCTest
@testable import LumaPlayer

/// 首页 hero 铺哪几项(`HomeViewModel.heroPick`)。纯函数,不走网络。
///
/// 2026-10-15 起 hero 吃**随机推荐**(`Sections.recommended`),
/// 「继续观看 → 各库最新」降级成**退路**。这一组用例守两件事:
/// ① 推荐池怎么筛(必须带背景图、上限 `heroCarouselLimit`);
/// ② 推荐拿不到(空 / 失败 / 一条带背景图的都没有)时必须退回原来的逻辑,
///    而且只给一张 —— ⛔ 不能让 hero 空着,那是首屏最贵的一块。
@MainActor
final class HomeHeroPickTests: XCTestCase {

    // MARK: - 推荐(首选)

    /// 推荐里有带背景图的就用推荐;继续观看不再抢 hero
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

    /// 只有海报、没有背景图的推荐项被筛掉:hero 是整宽铺满,
    /// 竖版海报铺上去会被裁成一条(与 `isHeroCandidate` 同一立场)
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

    /// 推荐池最多给 `heroCarouselLimit` 张
    func testRecommendedIsCappedAtCarouselLimit() throws {
        let pool = try (0..<8).map { try item("M\($0)", backdrop: true) }
        let pick = HomeViewModel.heroPick(
            recommended: .loaded(pool), views: .loading, resume: .loading, latest: { _ in .idle }
        )
        guard case .items(let picked) = pick else { return XCTFail("应为 .items,实际 \(pick)") }
        XCTAssertEqual(picked.map(\.id), ["M0", "M1", "M2", "M3", "M4"])
    }

    /// 截断发生在**筛选之后**:池子里前几条没有背景图,不该占掉 5 张的名额 ——
    /// 先 `prefix(5)` 再筛的话,真实服务器上(多数条目没有 `BackdropImageTags`)
    /// hero 会频繁只剩一两张
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

    /// 推荐行还在加载就等它(先占住 hero 的高度):
    /// 不然后面回来又换掉,首屏会跳
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

    /// 推荐为空 → 退回「继续观看里第一个有背景图的」,而且**只给一张**
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

    /// 推荐**请求失败**也要退路:一条请求打不通不该让整个 hero 空掉
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

    /// 推荐里一条带背景图的都没有(服务器没刮削过元数据)→ 同样走退路
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

    /// 退路里继续观看还在加载就等它:不让后面的「最新」先占了 hero 再被换掉
    func testFallbackWaitsWhileResumeIsLoading() throws {
        let pick = HomeViewModel.heroPick(
            recommended: .loaded([]),
            views: .loaded([try view("V1", "movies")]),
            resume: .loading,
            latest: { _ in .loaded([]) }
        )
        XCTAssertEqual(pick, .pending)
    }

    /// 退路:继续观看没有可用的 → 按媒体库顺序找「最新」;排在前面的库还在加载就等它
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

    /// 退路里失败的行跳过(它自己那一行会报错),不让 hero 跟着空着
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

    /// 分集自己没有背景图、剧有:父级背景图也算(`backdropSource` 的回退)
    func testEpisodeWithParentBackdropQualifies() throws {
        let episode = try decode(
            #"{"Id":"E1","Name":"E1","Type":"Episode","ParentBackdropItemId":"S1","ParentBackdropImageTags":["t"]}"#
        )
        let pick = HomeViewModel.heroPick(
            recommended: .loaded([episode]), views: .loading, resume: .loading, latest: { _ in .idle }
        )
        XCTAssertEqual(pick, .items([episode]))
    }

    /// 退路里都没有能上 hero 的 → `.none`(首页不画 hero,从普通页面顶部开始)
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

    /// 音乐库等不出「最新」行的库不参与退路(与首页行一致,`latestViews`)
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
