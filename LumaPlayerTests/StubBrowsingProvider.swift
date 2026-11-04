import Foundation
@testable import LumaPlayer

/// 让指定的那一次调用挂住的闸门。
///
/// ⚠️ 独立 actor:挂起发生在 provider 的 actor 上下文里,
/// 放行也要能并发进来 —— 放在同一个 actor 里会互相等待(死锁)。
actor StubPageGate {
    private var continuation: CheckedContinuation<Void, Never>?

    /// 只挂住第 `stallAtCall` 次调用;其它次直接放行。
    func waitIfNeeded(call: Int, stallAtCall: Int) async {
        guard call == stallAtCall else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// `FileSourceBrowsing` 的测试替身:按预设的页返回内容,不发任何请求。
///
/// 用来测浏览页的翻页状态机(首屏 / 追加 / 失败保留),⛔ 不测协议本身。
actor StubBrowsingProvider: FileSourceBrowsing {
    struct Page: Sendable {
        let files: [BaiduPanFile]
        let hasMore: Bool
        let nextOffset: Int
        let totalCount: Int?
    }

    nonisolated let sourceID: UUID
    private let pages: [Page]
    /// 第二页起抛错(测「翻页失败保留已加载内容」)
    private let failOnSecondPage: Bool
    /// `fs_id` → 时长(秒)
    private let durations: [UInt64: Double]
    /// 第二页起先挂住(测「翻页在飞时切目录」)
    nonisolated let gate: StubPageGate?
    /// 已经发了几次 `page`
    private(set) var pageCallCount = 0
    /// 每次 `page` 收到的 `limit`(守浏览页的一页条数,⛔ 别跟接口上限 1000 混为一谈)
    private(set) var requestedLimits: [Int] = []

    init(
        sourceID: UUID = UUID(),
        pages: [Page],
        failOnSecondPage: Bool = false,
        durations: [UInt64: Double] = [:],
        stallOnSecondPage: Bool = false
    ) {
        self.sourceID = sourceID
        self.pages = pages
        self.failOnSecondPage = failOnSecondPage
        self.durations = durations
        self.gate = stallOnSecondPage ? StubPageGate() : nil
    }

    // MARK: - FileSourceBrowsing

    func content(directory: String) async throws -> FileSourceDirectoryContent {
        let all = pages.flatMap(\.files)
        let composed = compose(files: all)
        let enriched = await enrich(composed, newFiles: all, known: nil)
        return FileSourceDirectoryContent(
            items: enriched.items,
            filesByID: composed.filesByID,
            durations: enriched.durations
        )
    }

    func page(directory: String, offset: Int, limit: Int) async throws -> FileSourcePage {
        pageCallCount += 1
        requestedLimits.append(limit)
        if failOnSecondPage, pageCallCount > 1 {
            throw StubBrowsingError.failed
        }
        if let gate, pageCallCount > 1 {
            await gate.waitIfNeeded(call: pageCallCount, stallAtCall: 2)
        }
        let index = min(pageCallCount - 1, max(pages.count - 1, 0))
        let page = pages.isEmpty
            ? Page(files: [], hasMore: false, nextOffset: offset, totalCount: 0)
            : pages[index]
        return FileSourcePage(
            files: page.files,
            hasMore: page.hasMore,
            nextOffset: page.nextOffset,
            totalCount: page.totalCount
        )
    }

    nonisolated func compose(files: [BaiduPanFile]) -> FileSourceComposedContent {
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(files: files, sourceID: sourceID)
        return FileSourceComposedContent(
            items: synthesized.map(\.item),
            filesByID: Dictionary(
                files.map { ($0.fsID, $0) },
                uniquingKeysWith: { first, _ in first }),
            coverFileIDs: [:]
        )
    }

    func enrich(
        _ composed: FileSourceComposedContent,
        newFiles: [BaiduPanFile],
        known: FileSourceDirectoryContent?
    ) async -> FileSourceEnrichedContent {
        var items = composed.items
        var allDurations = known?.durations ?? [:]
        for (offset, item) in items.enumerated() {
            guard let fsID = UInt64(item.ref.itemID), let duration = durations[fsID] else { continue }
            items[offset] = item.withDuration(duration)
            allDurations[fsID] = duration
        }
        return FileSourceEnrichedContent(items: items, durations: allDurations)
    }

    func scrape(items: [SourceItem]) async -> [SourceItem] { items }

    func lastScrapeFailureDescription() async -> String? { nil }

    // MARK: - SourceProvider

    func libraries() async throws -> [SourceLibrary] { [] }

    func items(in library: SourceLibraryRef) async throws -> [SourceItem] { [] }
}

enum StubBrowsingError: Error {
    case failed
}
