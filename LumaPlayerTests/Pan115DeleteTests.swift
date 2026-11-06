import XCTest
@testable import LumaPlayer

/// 115 删除的链路:浏览页 → `FileSourceViewModel.delete` → `Pan115Connection.deleteFile`
/// → `POST /rb/delete`。全部用 `MockEmbyURLProtocol` 造响应。
/// 请求形状取自 `115driver` / `p115client`(`docs/PAN115_API.md` §9)。
@MainActor
final class Pan115DeleteTests: XCTestCase {
    private var storage: CredentialFileStore!
    private var workspace: URL!
    private var container: AppContainer!
    private var source: Pan115Source!

    override func setUp() async throws {
        try await super.setUp()
        MockEmbyURLProtocol.reset()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "pan115-delete-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let credentials = CredentialStore(storage: storage)
        let file = { (name: String) in self.workspace.appending(path: "\(name).json") }
        container = AppContainer(
            registry: try ServerRegistry(
                defaults: UserDefaults(suiteName: "test.LumaPlayer.pan115delete.\(UUID().uuidString)")!,
                credentials: credentials),
            credentials: credentials,
            // 115 的连接走这个 session,不接桩就会真打出去
            session: MockEmbyURLProtocol.makeSession(),
            preferences: UserDefaults(
                suiteName: "test.LumaPlayer.pan115delete.prefs.\(UUID().uuidString)")!,
            watchProgress: WatchProgressStore(fileURL: file("progress")),
            hiddenItems: HiddenItemsStore(fileURL: file("hidden")),
            subtitleBindings: SubtitleBindingStore(fileURL: file("subtitle-bindings")),
            baiduDirectoryCache: BaiduPanDirectoryCache(fileURL: file("dir-cache")),
            baiduScrapeCache: BaiduPanScrapeCache(fileURL: file("scrape-cache")),
            baiduEpisodeCounts: BaiduPanEpisodeCountStore(fileURL: file("episode-counts")),
            localFolderAccess: LocalFolderAccess(bookmarks: FakeBookmarks()))
        try await credentials.savePan115Credential(
            Pan115Credential(uid: "u", cid: "c", seid: "s", kid: nil))
        source = try await container.registerPan115Source()
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

    /// 真删:按 `fs_id` 发一次 `/rb/delete`,条目立刻从列表消失、本地观看记录一起清掉,
    /// 而且**删完不再列一次目录**(§6:多一次请求就多一次风控面)。
    func testDeletingA115ItemSendsRbDeleteAndClearsLocalState() async throws {
        let viewModel = FileSourceViewModel(container: container, source: .pan115(source))
        // 115 的文件条目:fsID 就是删除要用的 fid
        let file = BaiduPanFile(
            fsID: 4242,
            path: "/电影/测试.2019.mp4",
            name: "测试.2019.mp4",
            sizeBytes: 1024,
            isDirectory: false,
            category: BaiduPanCategory.video,
            modifiedAt: nil,
            thumbnailURL: nil)
        let provider = StubBrowsingProvider(
            sourceID: source.id,
            pages: [
                StubBrowsingProvider.Page(
                    files: [file], hasMore: false, nextOffset: 0, totalCount: 1)
            ])
        viewModel.setBrowsingProviderOverride(provider)
        await viewModel.reload()
        let item = try XCTUnwrap(viewModel.sortedItems.first)
        try await container.watchProgress.record(
            fileID: item.ref.itemID, positionSeconds: 120, durationSeconds: 3600)

        MockEmbyURLProtocol.stub(
            .json(#"{"state":1}"#), host: "webapi.115.com", path: "/rb/delete")

        try await viewModel.delete(item, alsoDeleteRemotely: true)

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/rb/delete"))
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(request.body), as: UTF8.self),
            "fid%5B0%5D=4242")
        XCTAssertFalse(viewModel.sortedItems.contains(item), "删掉的条目要立刻从列表消失")
        let records = await container.watchProgress.storedRecords(sourceID: source.id)
        XCTAssertTrue(records.isEmpty, "真删要连本地观看记录一起清掉")
        XCTAssertEqual(
            MockEmbyURLProtocol.recordedRequests().count, 1,
            "删完⛔ 不为刷新再列一次目录")
    }

    /// 115 来源必须已经打开「连网盘一起删」(`FileSource.supportsDeletingFiles`),
    /// 否则确认面板的门槛形同虚设 —— 用户勾了「同时删除」却只能隐藏。
    func testPan115AllowsRemoteDeletion() {
        XCTAssertTrue(FileSource.pan115(source).supportsDeletingFiles)
    }
}
