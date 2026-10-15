import XCTest
@testable import LumaPlayer

/// 首页 hero 选哪一项(`HomeViewModel.heroPick`)。纯函数,不走网络。
@MainActor
final class HomeHeroPickTests: XCTestCase {

    func testResumeItemWithBackdropWins() throws {
        let resumeItem = try item("R1", backdrop: true)
        let pick = HomeViewModel.heroPick(
            views: .loading,
            resume: .loaded([try item("R0", backdrop: false), resumeItem]),
            latest: { _ in .loading }
        )
        // 继续观看里第一个**有背景图**的;媒体库还没回来也不用等
        XCTAssertEqual(pick, .item(resumeItem))
    }

    /// 分集自己没有背景图、剧有:父级背景图也算(`backdropSource` 的回退)
    func testEpisodeWithParentBackdropQualifies() throws {
        let episode = try decode(#"{"Id":"E1","Name":"E1","Type":"Episode","ParentBackdropItemId":"S1","ParentBackdropImageTags":["t"]}"#)
        let pick = HomeViewModel.heroPick(views: .loading, resume: .loaded([episode]), latest: { _ in .idle })
        XCTAssertEqual(pick, .item(episode))
    }

    func testWaitsWhileResumeIsLoading() throws {
        let pick = HomeViewModel.heroPick(
            views: .loaded([try view("V1", "movies")]),
            resume: .loading,
            latest: { _ in .loaded([]) }
        )
        XCTAssertEqual(pick, .pending)
    }

    /// 继续观看没有可用的 → 按媒体库顺序找「最新」;排在前面的库还在加载就等它,
    /// 不让后面的库先占了 hero 再被换掉
    func testFallsBackToLatestInLibraryOrder() throws {
        let views = [try view("V1", "movies"), try view("V2", "tvshows")]
        let movie = try item("M1", backdrop: true)
        let show = try item("T1", backdrop: true)
        let rows: [String: LoadState<[EmbyItem]>] = ["V1": .loading, "V2": .loaded([show])]

        let waiting = HomeViewModel.heroPick(
            views: .loaded(views), resume: .loaded([]), latest: { rows[$0.id] ?? .idle })
        XCTAssertEqual(waiting, .pending)

        let loaded: [String: LoadState<[EmbyItem]>] = ["V1": .loaded([movie]), "V2": .loaded([show])]
        let pick = HomeViewModel.heroPick(
            views: .loaded(views), resume: .loaded([]), latest: { loaded[$0.id] ?? .idle })
        XCTAssertEqual(pick, .item(movie))
    }

    /// 失败的行跳过(它自己那一行会报错),不让 hero 跟着空着
    func testFailedRowsAreSkipped() throws {
        let views = [try view("V1", "movies"), try view("V2", "tvshows")]
        let show = try item("T1", backdrop: true)
        let rows: [String: LoadState<[EmbyItem]>] = [
            "V1": .failed(LoadFailure(message: "x")), "V2": .loaded([show]),
        ]
        let pick = HomeViewModel.heroPick(
            views: .loaded(views),
            resume: .failed(LoadFailure(message: "x")),
            latest: { rows[$0.id] ?? .idle }
        )
        XCTAssertEqual(pick, .item(show))
    }

    /// 只有海报、没有背景图的条目不上 hero;全都没有就是 `.none`(首页不画 hero)
    func testNoneWhenNothingHasBackdrop() throws {
        let views = [try view("V1", "movies")]
        let posterOnly = try item("M1", backdrop: false)
        let pick = HomeViewModel.heroPick(
            views: .loaded(views),
            resume: .loaded([try item("R1", backdrop: false)]),
            latest: { _ in .loaded([posterOnly]) }
        )
        XCTAssertEqual(pick, .none)
    }

    /// 音乐库等不出「最新」行的库不参与(与首页行一致,`latestViews`)
    func testIgnoresNonVideoLibraries() throws {
        let views = [try view("V1", "music")]
        let pick = HomeViewModel.heroPick(
            views: .loaded(views),
            resume: .loaded([]),
            latest: { _ in .loading }
        )
        XCTAssertEqual(pick, .none)
    }

    func testMediaLibraryListFailureMeansNone() {
        let pick = HomeViewModel.heroPick(
            views: .failed(LoadFailure(message: "x")),
            resume: .loaded([]),
            latest: { _ in .idle }
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
