import XCTest
@testable import LumaPlayer

/// 夸克来源的生命周期与只读边界:
/// 建来源 → 分页浏览 → 隐藏(而不是删除)→ 删来源时清凭据。
///
/// ⚠️ 这个来源**只读**(`docs/QUARK_API.md` §9):TV 端没有删除接口,所以「删除」必须降级成
/// 「隐藏」,⛔ 不能发出任何写请求。
@MainActor
final class QuarkSourceLifecycleTests: XCTestCase {
    private var storage: CredentialFileStore!
    private var workspace: URL!
    private var container: AppContainer!
    private var source: QuarkSource!

    override func setUp() async throws {
        try await super.setUp()
        MockEmbyURLProtocol.reset()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "quark-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let credentials = CredentialStore(storage: storage)
        let file = { (name: String) in self.workspace.appending(path: "\(name).json") }
        container = AppContainer(
            registry: try ServerRegistry(
                defaults: UserDefaults(suiteName: "test.LumaPlayer.quark.\(UUID().uuidString)")!,
                credentials: credentials),
            credentials: credentials,
            // 夸克的连接走这个 session,不接桩就会真打出去
            session: MockEmbyURLProtocol.makeSession(),
            preferences: UserDefaults(
                suiteName: "test.LumaPlayer.quark.prefs.\(UUID().uuidString)")!,
            watchProgress: WatchProgressStore(fileURL: file("progress")),
            hiddenItems: HiddenItemsStore(fileURL: file("hidden")),
            subtitleBindings: SubtitleBindingStore(fileURL: file("subtitle-bindings")),
            baiduDirectoryCache: BaiduPanDirectoryCache(fileURL: file("dir-cache")),
            baiduScrapeCache: BaiduPanScrapeCache(fileURL: file("scrape-cache")),
            baiduEpisodeCounts: BaiduPanEpisodeCountStore(fileURL: file("episode-counts")),
            localFolderAccess: LocalFolderAccess(bookmarks: FakeBookmarks()))
        try await credentials.saveQuarkCredential(
            QuarkCredential(accessToken: "a", refreshToken: "r", deviceID: "d"))
        source = try await container.registerQuarkSource()
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        storage = nil
        workspace = nil
        container = nil
        source = nil
        MockEmbyURLProtocol.reset()
        try await super.tearDown()
    }

    private func stubList(_ body: String) {
        MockEmbyURLProtocol.stub(
            .json(body), host: QuarkEndpoint.apiHost, path: "/file")
    }

    /// 注册来源要落库并切过去。
    func testRegisteringQuarkSourceAddsAndSelectsIt() async throws {
        let sources = await container.quarkSources()
        XCTAssertEqual(sources.map(\.id), [source.id])
        XCTAssertEqual(container.state.currentSource?.id, source.id)
        XCTAssertEqual(container.state.route, .browse)
    }

    /// 同名时往后编号。
    func testSecondQuarkSourceGetsNumberedName() async throws {
        let second = try await container.registerQuarkSource()
        XCTAssertEqual(second.displayName, "夸克网盘 2")
    }

    /// 浏览:一页 100 条,`hasMore` 由 `total_count` 精确判定,`nextOffset` 按整页推进。
    func testBrowsingUsesPageArithmetic() async throws {
        let files = (0..<3).map { index in
            #"{"fid":"f\#(index)","filename":"电影\#(index).mp4","size":10,"isdir":0,"category":1}"#
        }
        .joined(separator: ",")
        stubList(#"{"status":0,"errno":0,"data":{"total_count":250,"files":[\#(files)]}}"#)

        let viewModel = FileSourceViewModel(container: container, source: .quark(source))
        await viewModel.reload()

        XCTAssertEqual(viewModel.currentDirectory, QuarkPath.root)
        XCTAssertEqual(viewModel.items.count, 3)
        // 夸克有总数,但条目只有 3 条,这一页不满 → 按服务端口径仍有下一页
        XCTAssertTrue(viewModel.hasMoreItems)
        XCTAssertEqual(viewModel.sortedItems.count, 3)
    }

    /// 只读来源不给「真删」入口:能力位决定 UI,⛔ 不靠调用点自己判。
    func testQuarkSourceIsReadOnly() {
        let fileSource = FileSource.quark(source)
        XCTAssertFalse(fileSource.supportsDeletingFiles)
        XCTAssertFalse(fileSource.remoteDeletionIsRecoverable)
        XCTAssertFalse(fileSource.supportsRenamingSeries)
        XCTAssertEqual(fileSource.storageNoun, "网盘")
    }

    /// 即使有人绕过 UI 直接调 `delete(alsoDeleteRemotely: true)`,也要如实拒绝且**不发请求**。
    func testRemoteDeleteIsRejectedWithoutAnyRequest() async throws {
        stubList(#"{"status":0,"errno":0,"data":{"total_count":1,"files":[{"fid":"f0","filename":"电影.mp4","size":10,"isdir":0,"category":1}]}}"#)
        let viewModel = FileSourceViewModel(container: container, source: .quark(source))
        await viewModel.reload()
        let item = try XCTUnwrap(viewModel.sortedItems.first)
        MockEmbyURLProtocol.reset()

        do {
            try await viewModel.delete(item, alsoDeleteRemotely: true)
            XCTFail("应当抛错")
        } catch let error as QuarkError {
            // ⛔ 不能报「本地文件夹只读」:用户删的是网盘里的文件
            if case .invalidRequest = error { } else {
                XCTFail("错误的错误档:\(error)")
            }
        }
        // 一个写请求都不该发出去
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
        // 一个写请求都不该发出去
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    /// 隐藏照常工作(它只写本地库)。
    func testHidingIsTheSupportedRemoval() async throws {
        stubList(#"{"status":0,"errno":0,"data":{"total_count":1,"files":[{"fid":"f0","filename":"电影.mp4","size":10,"isdir":0,"category":1}]}}"#)
        let viewModel = FileSourceViewModel(container: container, source: .quark(source))
        await viewModel.reload()
        let item = try XCTUnwrap(viewModel.sortedItems.first)

        try await viewModel.delete(item, alsoDeleteRemotely: false)

        XCTAssertTrue(viewModel.sortedItems.isEmpty)
        let hidden = await container.hiddenItems.hiddenRefs(sourceID: source.id)
        XCTAssertTrue(hidden.contains(item.ref))
    }

    /// 删最后一个夸克来源时清凭据;还有别的来源就留着。
    func testCredentialIsClearedOnlyWhenLastSourceRemoved() async throws {
        let second = try await container.registerQuarkSource()
        try await container.removeSource(id: second.id)
        let stillThere = try await storage.value(forAccount: "quark-credential")
        XCTAssertNotNil(stillThere)

        try await container.removeSource(id: source.id)
        let gone = try await storage.value(forAccount: "quark-credential")
        XCTAssertNil(gone)
    }

    /// 片库根按来源独立(两个夸克来源互不影响)。
    func testLibraryRootsArePerSource() async throws {
        let second = try await container.registerQuarkSource()
        try await container.setQuarkLibraryRoot(
            QuarkLibraryRoot(path: "/电影", name: "电影"), for: source)

        let first = try await container.quarkLibraryRoot(for: source)
        let other = try await container.quarkLibraryRoot(for: second)
        XCTAssertEqual(first?.path, "/电影")
        XCTAssertNil(other)
    }
}
