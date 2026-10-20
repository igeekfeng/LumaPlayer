import XCTest
@testable import LumaPlayer

/// 本地续播库(百度来源唯一的进度存储 —— 百度没有上报接口,`docs/BAIDU_PAN_API.md`)。
final class WatchProgressStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "watch-progress-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func makeStore() -> WatchProgressStore {
        WatchProgressStore(fileURL: fileURL)
    }

    // MARK: - 续播

    func testNoRecordMeansNoResumePosition() async throws {
        let store = makeStore()
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertNil(position, "没有记录就是 nil,⛔ 不是 0")
    }

    func testRecordsAndReadsBackPosition() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 123.5, durationSeconds: 600)
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertEqual(position, 123.5)
    }

    /// 看完(≥90%)就不再续播,从头开始。
    func testFinishedPlaybackResetsToBeginning() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 590, durationSeconds: 600)
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertNil(position, "已看完的不该再提示续播")
    }

    func testBelowThresholdStillResumes() async throws {
        let store = makeStore()
        // 480/600 = 80%,没到 90% 那一档
        try await store.record(fileID: "42", positionSeconds: 480, durationSeconds: 600)
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertEqual(position, 480)
    }

    /// 时长未知时照样续播(只是判不了「已看完」)。
    func testResumeWorksWithoutDuration() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 88, durationSeconds: nil)
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertEqual(position, 88)
    }

    /// 位置回到 0 时**删掉**这条记录:「从 0 开始看」不是一条进度。
    func testPositionZeroRemovesRecord() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 123, durationSeconds: 600)
        try await store.record(fileID: "42", positionSeconds: 0, durationSeconds: 600)
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertNil(position)
    }

    func testRemoveDeletesOnlyThatEntry() async throws {
        let store = makeStore()
        try await store.record(fileID: "a", positionSeconds: 10, durationSeconds: nil)
        try await store.record(fileID: "b", positionSeconds: 20, durationSeconds: nil)
        try await store.remove(fileID: "a")
        let removed = await store.resumeSeconds(forFileID: "a")
        let kept = await store.resumeSeconds(forFileID: "b")
        XCTAssertNil(removed)
        XCTAssertEqual(kept, 20)
    }

    // MARK: - 批量清(删除网盘条目时用)

    func testForgetRemovesEveryListedRecordInOneWrite() async throws {
        let store = makeStore()
        try await store.record(fileID: "1", positionSeconds: 10, durationSeconds: 600)
        try await store.record(fileID: "2", positionSeconds: 20, durationSeconds: 600)
        try await store.record(fileID: "3", positionSeconds: 30, durationSeconds: 600)

        let removed = try await store.forget(fileIDs: ["1", "2"])

        XCTAssertEqual(removed, 2)
        let left = await store.snapshot().keys.sorted()
        XCTAssertEqual(left, ["3"], "只删列出来的那几条")
    }

    /// 不在库里的 id 不算删掉(调用方要据实报数),也不抛错。
    func testForgetIgnoresUnknownIDs() async throws {
        let store = makeStore()
        try await store.record(fileID: "1", positionSeconds: 10, durationSeconds: nil)

        let removed = try await store.forget(fileIDs: ["1", "ghost"])

        XCTAssertEqual(removed, 1)
        let empty = await store.snapshot().isEmpty
        XCTAssertTrue(empty)
    }

    func testForgetWithEmptyListIsNoOp() async throws {
        let store = makeStore()
        try await store.record(fileID: "1", positionSeconds: 10, durationSeconds: nil)

        let removed = try await store.forget(fileIDs: [])

        XCTAssertEqual(removed, 0)
        let position = await store.resumeSeconds(forFileID: "1")
        XCTAssertEqual(position, 10)
    }

    /// ⚠️ 删掉的若是**正在播**的那一条,上报器每 10 秒还会写一次进度 ——
    /// 不能让它把记录写回来(否则「继续观看」又冒出一张点开就播不了的卡)。
    func testForgottenRecordIsNotResurrectedByLateProgressReports() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.rememberDisplay(fileID: "42", display: display(sourceID: sourceID))
        try await store.record(fileID: "42", positionSeconds: 300, durationSeconds: 600)
        try await store.forget(fileIDs: ["42"])

        // 在途的两次写入:进度上报 + 起播那一刻补记的展示快照
        try await store.record(fileID: "42", positionSeconds: 310, durationSeconds: 600)
        try await store.rememberDisplay(fileID: "42", display: display(sourceID: sourceID))

        let remaining = await store.snapshot()
        XCTAssertNil(remaining["42"], "删掉的记录不该被在途的写入复活")
        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertTrue(entries.isEmpty, "「继续观看」里也不该再有它")
    }

    /// 批量清之后,盘上也没有了(换个实例重开验证)。
    func testForgetIsPersisted() async throws {
        try await makeStore().record(fileID: "1", positionSeconds: 10, durationSeconds: nil)
        try await makeStore().forget(fileIDs: ["1"])

        let reopened = makeStore()
        let remaining = await reopened.snapshot()
        XCTAssertTrue(remaining.isEmpty)
    }

    /// 「移出继续观看」走 `remove(fileIDs:)`:那是用户主动弃掉进度,文件还在网盘,
    /// 之后再点开这一集必须还能记下来 —— ⛔ 不能落进「已忘」那道门。
    func testRemovedRecordsCanBeWrittenAgain() async throws {
        let store = makeStore()
        try await store.record(fileID: "1", positionSeconds: 10, durationSeconds: nil)
        try await store.remove(fileIDs: ["1"])

        try await store.record(fileID: "1", positionSeconds: 40, durationSeconds: 600)

        let position = await store.resumeSeconds(forFileID: "1")
        XCTAssertEqual(position, 40)
    }

    // MARK: - 存档记录(删除时圈范围用)

    /// `storedRecords` 不过滤:位置 0 的、已看完的都要在 —— 删条目时要清的是「全部」。
    func testStoredRecordsIncludeUnfinishedFinishedAndZeroPosition() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.rememberDisplay(fileID: "1", display: display(sourceID: sourceID, title: "A"))
        try await store.record(fileID: "1", positionSeconds: 100, durationSeconds: 600)
        try await store.rememberDisplay(fileID: "2", display: display(sourceID: sourceID, title: "B"))
        try await store.record(fileID: "2", positionSeconds: 590, durationSeconds: 600)
        // 位置 0:起播那一刻写过展示快照,进度还没落
        try await store.rememberDisplay(fileID: "3", display: display(sourceID: sourceID, title: "C"))

        let stored = await store.storedRecords(sourceID: sourceID)

        XCTAssertEqual(Set(stored.map(\.fileID)), ["1", "2", "3"])
        XCTAssertEqual(stored.map(\.display.locator).count, 3)
    }

    /// 没有展示快照的记录不出现在 `storedRecords` 里:它没有 `locator`,界不出删除范围。
    func testStoredRecordsSkipEntriesWithoutDisplay() async throws {
        let store = makeStore()
        try await store.record(fileID: "1", positionSeconds: 100, durationSeconds: 600)

        let stored = await store.storedRecords(sourceID: UUID())

        XCTAssertTrue(stored.isEmpty)
    }

    /// 只给本来源的记录(多来源不串台)。
    func testStoredRecordsFilterBySource() async throws {
        let store = makeStore()
        let mine = UUID()
        try await store.rememberDisplay(fileID: "1", display: display(sourceID: mine, title: "A"))
        try await store.rememberDisplay(fileID: "2", display: display(sourceID: UUID(), title: "B"))

        let stored = await store.storedRecords(sourceID: mine)

        XCTAssertEqual(stored.map(\.fileID), ["1"])
    }

    // MARK: - 落盘

    func testSnapshotSurvivesANewStoreInstance() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 321, durationSeconds: 900)
        // 换一个实例(= 模拟 App 重启):进度必须在盘上
        let reopened = makeStore()
        let position = await reopened.resumeSeconds(forFileID: "42")
        XCTAssertEqual(position, 321)
    }

    /// 文件坏了不能静默「当作没有记录」:原因要留下来。
    func testCorruptedFileIsReportedNotSwallowed() async throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore()
        _ = await store.resumeSeconds(forFileID: "42")
        let failure = await store.lastLoadFailureDescription
        XCTAssertNotNil(failure, "读盘失败必须留下原因,⛔ 不能假装没记录")
    }

    func testWritesWithRestrictivePermissions() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 1, durationSeconds: nil)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)
        // 0o600:「谁看了什么」属于隐私,不该对同机其他用户可读
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    // MARK: - 展示快照(「继续观看」区用)

    private func display(
        sourceID: UUID,
        title: String = "电影",
        cover: ImageDescriptor.Snapshot? = nil
    ) -> WatchProgressStore.Display {
        WatchProgressStore.Display(
            sourceID: sourceID,
            title: title,
            locator: "/apps/LumaPlayer/\(title).mp4",
            fileName: "\(title).mp4",
            cover: cover
        )
    }

    /// 起播时先记展示(此刻位置还是 0),上报器随后才写位置 —— 两者不能互相抹掉。
    func testRememberDisplayThenRecordKeepsBoth() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.rememberDisplay(fileID: "42", display: display(sourceID: sourceID))
        try await store.record(fileID: "42", positionSeconds: 300, durationSeconds: 600)

        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.positionSeconds, 300)
        XCTAssertEqual(entries.first?.display.title, "电影")
    }

    /// 反过来:先有进度、再补展示,位置不能被抹掉。
    func testRecordThenRememberDisplayKeepsPosition() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.record(fileID: "42", positionSeconds: 300, durationSeconds: 600)
        try await store.rememberDisplay(fileID: "42", display: display(sourceID: sourceID))

        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertEqual(position, 300)
    }

    /// 只有位置(老记录 / 别的来源)或只有展示(还没看)的条目都不进「继续观看」。
    func testResumeEntriesSkipsEntriesWithoutDisplayOrProgress() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.record(fileID: "1", positionSeconds: 100, durationSeconds: nil)
        try await store.rememberDisplay(fileID: "2", display: display(sourceID: sourceID))
        try await store.rememberDisplay(fileID: "3", display: display(sourceID: sourceID))
        try await store.record(fileID: "3", positionSeconds: 50, durationSeconds: nil)

        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.map(\.fileID), ["3"])
    }

    /// 看完(≥90%)的集不该再占一张「继续观看」卡 —— 与 `resumeSeconds` 同一把尺子。
    func testResumeEntriesSkipsFinishedEntries() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.rememberDisplay(fileID: "a", display: display(sourceID: sourceID, title: "A"))
        try await store.record(fileID: "a", positionSeconds: 590, durationSeconds: 600)
        try await store.rememberDisplay(fileID: "b", display: display(sourceID: sourceID, title: "B"))
        try await store.record(fileID: "b", positionSeconds: 60, durationSeconds: 600)

        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.map(\.fileID), ["b"])
    }

    /// 时长未知时判不了「看完」,按未看完留在列表里(⛔ 不猜)。
    func testResumeEntriesKeepsUnfinishedWhenDurationUnknown() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.rememberDisplay(fileID: "a", display: display(sourceID: sourceID))
        try await store.record(fileID: "a", positionSeconds: 590, durationSeconds: nil)

        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.map(\.fileID), ["a"])
    }

    func testResumeEntriesFiltersBySourceAndSortsByRecency() async throws {
        let store = makeStore()
        let mine = UUID()
        let other = UUID()
        try await store.rememberDisplay(fileID: "a", display: display(sourceID: mine, title: "A"))
        try await store.record(fileID: "a", positionSeconds: 10, durationSeconds: nil)
        try await Task.sleep(for: .milliseconds(5))
        try await store.rememberDisplay(fileID: "b", display: display(sourceID: mine, title: "B"))
        try await store.record(fileID: "b", positionSeconds: 20, durationSeconds: nil)
        try await store.rememberDisplay(fileID: "c", display: display(sourceID: other, title: "C"))
        try await store.record(fileID: "c", positionSeconds: 30, durationSeconds: nil)

        let entries = await store.resumeEntries(sourceID: mine)
        XCTAssertEqual(entries.map(\.fileID), ["b", "a"], "只出本来源,且最近看的在前")
    }

    /// 封面快照随进度一起持久化,重启后「继续观看」还端得出封面。
    func testCoverSnapshotSurvivesRestart() async throws {
        let sourceID = UUID()
        let cover = ImageDescriptor.Snapshot(
            ownerID: sourceID,
            url: URL(string: "https://d.pcs.baidu.com/file/abc?access_token=T")!,
            headers: ["User-Agent": "netdisk"],
            cacheKey: "baidu|\(sourceID.uuidString)|7|1700000000|cover|400"
        )
        let store = makeStore()
        try await store.rememberDisplay(fileID: "7", display: display(sourceID: sourceID, cover: cover))
        try await store.record(fileID: "7", positionSeconds: 42, durationSeconds: 100)

        let reopened = makeStore()
        let entries = await reopened.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.first?.display.cover, cover)
    }

    /// 旧文件(没有 `display` 字段)必须照常解码 —— 升级不该把已有进度判成损坏。
    func testLegacyFileWithoutDisplayDecodes() async throws {
        let legacy = #"{"42":{"positionSeconds":123,"durationSeconds":600,"updatedAt":"2026-01-01T00:00:00Z"}}"#
        try Data(legacy.utf8).write(to: fileURL)

        let store = makeStore()
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertEqual(position, 123)
        let failure = await store.lastLoadFailureDescription
        XCTAssertNil(failure, "旧文件不是损坏文件")
    }

    // MARK: - 观看状态(已看 / 未看)

    /// 越过 90% 的上报就地落成「已看」:位置归 0,状态置 true。
    func testProgressCrossingThresholdBecomesWatched() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 590, durationSeconds: 600)

        let state = await store.watchState(forFileID: "42")
        XCTAssertEqual(state, .watched)
        let entries = await store.snapshot()
        XCTAssertEqual(entries["42"]?.played, true)
        XCTAssertEqual(entries["42"]?.positionSeconds, 0)
    }

    /// 手动标已看:不再续播,也不再占「继续观看」的卡。
    func testMarkPlayedClearsProgressAndResumeEntry() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.rememberDisplay(fileID: "42", display: display(sourceID: sourceID))
        try await store.record(fileID: "42", positionSeconds: 300, durationSeconds: 600)

        try await store.setPlayed(
            [WatchProgressStore.PlayedMark(fileID: "42", display: nil)], played: true)

        let state = await store.watchState(forFileID: "42")
        XCTAssertEqual(state, .watched)
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertNil(position, "标了已看就不该再续播")
        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertTrue(entries.isEmpty, "标了已看的不该再占一张续播卡")
    }

    /// 没播过的条目也能标已看:没有记录就新建一条。
    ///
    /// ⚠️ 标记时顺手带的展示快照要落下来 —— 否则删网盘文件时按路径圈不到这条记录。
    func testMarkPlayedCreatesRecordAndKeepsDisplay() async throws {
        let store = makeStore()
        let sourceID = UUID()

        let changed = try await store.setPlayed(
            [WatchProgressStore.PlayedMark(
                fileID: "42", display: display(sourceID: sourceID, title: "第一集"))],
            played: true)

        XCTAssertEqual(changed, 1)
        let state = await store.watchState(forFileID: "42")
        XCTAssertEqual(state, .watched)
        let stored = await store.storedRecords(sourceID: sourceID)
        XCTAssertEqual(stored.map(\.fileID), ["42"])
        XCTAssertEqual(stored.first?.display.title, "第一集")
    }

    /// 标未看要压过「比例上已经看完」这个自动判定。
    func testMarkUnplayedOverridesThreshold() async throws {
        let store = makeStore()
        try await store.record(fileID: "42", positionSeconds: 590, durationSeconds: 600)
        let before = await store.watchState(forFileID: "42")
        XCTAssertEqual(before, .watched)

        try await store.setPlayed(
            [WatchProgressStore.PlayedMark(fileID: "42", display: nil)], played: false)

        let state = await store.watchState(forFileID: "42")
        XCTAssertEqual(state, .unwatched)
        let position = await store.resumeSeconds(forFileID: "42")
        XCTAssertNil(position, "未看不该带一个续播位置")
    }

    /// 已经是未看的、以及压根没有记录的,标未看不算改动。
    func testMarkUnplayedOnUnknownOrUnwatchedIsNoOp() async throws {
        let store = makeStore()
        let unknown = try await store.setPlayed(
            [WatchProgressStore.PlayedMark(fileID: "ghost", display: nil)], played: false)
        XCTAssertEqual(unknown, 0)

        try await store.record(fileID: "42", positionSeconds: 300, durationSeconds: 600)
        try await store.setPlayed(
            [WatchProgressStore.PlayedMark(fileID: "42", display: nil)], played: false)
        let again = try await store.setPlayed(
            [WatchProgressStore.PlayedMark(fileID: "42", display: nil)], played: false)
        XCTAssertEqual(again, 0, "已经是未看了,再标一次不算改动")
    }

    /// 标完已看又重新播起来:进度上报会把显式标记清掉,回到「进行中」。
    ///
    /// ⚠️ 这是刻意的(见 `record` 的注释):用户确实还在看,状态就该如实跟着走。
    func testProgressAfterMarkPlayedTurnsBackToInProgress() async throws {
        let store = makeStore()
        try await store.setPlayed(
            [WatchProgressStore.PlayedMark(fileID: "42", display: nil)], played: true)

        try await store.record(fileID: "42", positionSeconds: 30, durationSeconds: 600)

        let state = await store.watchState(forFileID: "42")
        XCTAssertEqual(state, .inProgress(seconds: 30))
    }

    /// 0 秒的起播上报会删记录,但**不能**抹掉显式标过的已看。
    func testZeroPositionReportKeepsExplicitPlayed() async throws {
        let store = makeStore()
        try await store.setPlayed(
            [WatchProgressStore.PlayedMark(fileID: "42", display: nil)], played: true)

        try await store.record(fileID: "42", positionSeconds: 0, durationSeconds: 600)

        let state = await store.watchState(forFileID: "42")
        XCTAssertEqual(state, .watched)
    }

    /// 批量读状态时**未看的不占一格**(调用方按「查不到 = 未看」处理)。
    func testWatchStatesSkipsUnwatched() async throws {
        let store = makeStore()
        try await store.record(fileID: "a", positionSeconds: 100, durationSeconds: 600)
        try await store.record(fileID: "b", positionSeconds: 590, durationSeconds: 600)

        let states = await store.watchStates(forFileIDs: ["a", "b", "ghost"])

        XCTAssertEqual(states, ["a": .inProgress(seconds: 100), "b": .watched])
    }

    /// 老文件(没有 `played` 字段)按比例现算 —— 90% 以上算已看,其余算进行中。
    func testLegacyEntryWithoutPlayedDerivesStateFromThreshold() async throws {
        let legacy = #"""
        {"done":{"positionSeconds":590,"durationSeconds":600,"updatedAt":"2026-01-01T00:00:00Z"},
         "half":{"positionSeconds":300,"durationSeconds":600,"updatedAt":"2026-01-01T00:00:00Z"}}
        """#
        try Data(legacy.utf8).write(to: fileURL)

        let store = makeStore()
        let done = await store.watchState(forFileID: "done")
        let half = await store.watchState(forFileID: "half")
        XCTAssertEqual(done, .watched)
        XCTAssertEqual(half, .inProgress(seconds: 300))
    }

    // MARK: - 「下一集」占位(Emby 的 NextUp 对位物)

    /// 看完一集之后,下一集靠占位进续播区:位置 0、`isUpNext`,但**不算看过**。
    func testUpNextPlaceholderShowsInResumeShelfWithoutCountingAsWatched() async throws {
        let store = makeStore()
        let sourceID = UUID()

        try await store.setUpNext([
            WatchProgressStore.PlayedMark(
                fileID: "2", display: display(sourceID: sourceID, title: "琅琊榜"))
        ])

        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.map(\.fileID), ["2"])
        XCTAssertEqual(entries.first?.positionSeconds, 0)
        XCTAssertEqual(entries.first?.isUpNext, true)
        let state = await store.watchState(forFileID: "2")
        XCTAssertEqual(state, .unwatched, "占位不算看过:卡片上没有 ✓")
        let resume = await store.resumeSeconds(forFileID: "2")
        XCTAssertNil(resume, "占位不续播,从 0 开始")
    }

    /// 占位那一集真的播起来之后,占位就该让位给普通进度记录。
    func testProgressReplacesUpNextPlaceholder() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.setUpNext([
            WatchProgressStore.PlayedMark(
                fileID: "2", display: display(sourceID: sourceID, title: "琅琊榜"))
        ])

        try await store.record(fileID: "2", positionSeconds: 30, durationSeconds: 600)

        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.first?.isUpNext, false)
        XCTAssertEqual(entries.first?.positionSeconds, 30)
    }

    /// 已经看过的集不能被占位盖掉(否则 ✓ 会凭空消失)。
    func testUpNextSkipsWatchedEpisode() async throws {
        let store = makeStore()
        try await store.setPlayed(
            [WatchProgressStore.PlayedMark(fileID: "2", display: nil)], played: true)

        let changed = try await store.setUpNext([
            WatchProgressStore.PlayedMark(fileID: "2", display: nil)
        ])

        XCTAssertEqual(changed, 0)
        let state = await store.watchState(forFileID: "2")
        XCTAssertEqual(state, .watched)
    }

    /// 还有进度的集也不能被占位抹成 0 秒(用户看起来像进度丢了)。
    func testUpNextSkipsEpisodeWithProgress() async throws {
        let store = makeStore()
        try await store.record(fileID: "2", positionSeconds: 300, durationSeconds: 600)

        let changed = try await store.setUpNext([
            WatchProgressStore.PlayedMark(fileID: "2", display: nil)
        ])

        XCTAssertEqual(changed, 0)
        let position = await store.resumeSeconds(forFileID: "2")
        XCTAssertEqual(position, 300)
    }

    /// 起播那一集(还没走过 10 秒)的一次 0 秒上报,不能把「下一集」占位删掉。
    func testZeroSecondReportKeepsUpNextPlaceholder() async throws {
        let store = makeStore()
        let sourceID = UUID()
        try await store.setUpNext([
            WatchProgressStore.PlayedMark(
                fileID: "2", display: display(sourceID: sourceID, title: "琅琊榜"))
        ])

        try await store.record(fileID: "2", positionSeconds: 0, durationSeconds: nil)

        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.map(\.fileID), ["2"], "占位不该被一次 0 秒起播抹掉")
        XCTAssertEqual(entries.first?.isUpNext, true)
    }

    // MARK: - 自然播完(`markFinished`)

    /// 用户报的那条:播完一集但**时长未知**时,续播卡必须让给下一集。
    ///
    /// 之前只靠「位置 / 时长 ≥ 90%」推「看完」,时长未知就判不出来 —— 那集停在
    /// 「看到 99%」,继续占着这部唯一的一张卡,下一集的占位永远出不来。
    func testMarkFinishedWithoutDurationFreesTheCardForNextEpisode() async throws {
        let store = makeStore()
        let sourceID = UUID()
        // 播到结尾了,但 mpv 从没报过时长
        try await store.record(fileID: "1", positionSeconds: 2690, durationSeconds: nil)
        let before = await store.watchState(forFileID: "1")
        XCTAssertEqual(before, .inProgress(seconds: 2690), "时长未知时比例判不出看完")

        try await store.markFinished(
            fileID: "1",
            display: display(sourceID: sourceID, title: "琅琊榜"),
            endedAt: 2690,
            durationSeconds: nil)
        let after = await store.watchState(forFileID: "1")
        XCTAssertEqual(after, .watched)

        // 关窗时那一次收尾上报(位置≈终点、时长仍未知)不能把已看翻回进行中
        try await store.record(fileID: "1", positionSeconds: 2690, durationSeconds: nil)
        let settled = await store.watchState(forFileID: "1")
        XCTAssertEqual(settled, .watched, "终点兜底成时长,后一次上报的比例是 100%")

        try await store.setUpNext([
            WatchProgressStore.PlayedMark(
                fileID: "2", display: display(sourceID: sourceID, title: "琅琊榜"))
        ])
        let entries = await store.resumeEntries(sourceID: sourceID)
        XCTAssertEqual(entries.map(\.fileID), ["2"])
        XCTAssertEqual(entries.first?.isUpNext, true)
    }

    /// 已知时长时不能被「终点」覆盖:记录里的时长仍是那一次真实值。
    func testMarkFinishedKeepsKnownDuration() async throws {
        let store = makeStore()
        try await store.markFinished(
            fileID: "1", display: nil, endedAt: 600, durationSeconds: 3600)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot["1"]?.durationSeconds, 3600)
        XCTAssertEqual(snapshot["1"]?.played, true)
        XCTAssertEqual(snapshot["1"]?.positionSeconds, 0)
    }
}
