import Foundation
import os

/// 百度网盘条目的刮削结果落盘缓存:`fs_id` → TMDB 补回来的字段(`BaiduPanMetadataScraper` 的查询缓存只在内存)。
/// 只存条目级补丁,不存剧级 `seriesProfile`(只在详情页用,进程内缓存够)。
///
/// 按 `fs_id` 认即可:改名 / 挪目录不变,替换文件就是新 `fs_id`(`docs/BAIDU_PAN_API.md` §2.2)。
/// 失效只有 `maxAge` 与删除来源两档。
actor BaiduPanScrapeCache {

    /// 全部可选:当时没拿到的不存,下次再问。
    struct Entry: Codable, Sendable, Equatable {
        /// 只可能是 TMDB 图床的远端图。⛔ 百度 `dlink` 封面会过期,不进这里。
        var poster: ImageDescriptor.Snapshot?
        var overview: String?
        var year: Int?
        var episodeTitle: String?
        var tmdbID: Int?
        var savedAt: Date

        /// 什么都没补到就不存
        var isEmpty: Bool {
            poster == nil && overview == nil && year == nil
                && episodeTitle == nil && tmdbID == nil
        }
    }

    private struct Snapshot: Codable, Sendable {
        var entries: [String: Entry]
    }

    private static let logger = Logger(
        subsystem: NetworkDiagnostics.subsystem, category: "baidu-scrape-cache")

    /// TMDB 的简介 / 海报极少变,重刮代价是一串网络请求。
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private let fileURL: URL
    private var snapshot: Snapshot?
    private(set) var lastLoadFailureDescription: String?
    private(set) var lastWriteFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 与凭据文件同目录(测试宿主另用文件名)。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let filename = isTestHost
            ? "baidu-scrape-cache-testhost.json"
            : "baidu-scrape-cache.json"
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
    }

    // MARK: - 读

    func entry(sourceID: UUID, fsID: String, now: Date = Date()) -> Entry? {
        guard let entry = state()[Self.key(sourceID: sourceID, fsID: fsID)] else { return nil }
        guard now.timeIntervalSince(entry.savedAt) <= Self.maxAge else { return nil }
        return entry
    }

    // MARK: - 写

    /// 一次落盘。失败只记原因,不影响浏览。
    func store(sourceID: UUID, entries: [String: Entry]) {
        guard !entries.isEmpty else { return }
        var all = state()
        for (fsID, entry) in entries where !entry.isEmpty {
            all[Self.key(sourceID: sourceID, fsID: fsID)] = entry
        }
        persist(all)
    }

    func purge(sourceID: UUID) {
        var all = state()
        let prefix = "\(sourceID.uuidString)|"
        let stale = all.keys.filter { $0.hasPrefix(prefix) }
        guard !stale.isEmpty else { return }
        for key in stale { all.removeValue(forKey: key) }
        persist(all)
    }

    // MARK: - 内部

    private static func key(sourceID: UUID, fsID: String) -> String {
        "\(sourceID.uuidString)|\(fsID)"
    }

    private func state() -> [String: Entry] {
        if let snapshot { return snapshot.entries }
        let loaded = readFile()
        snapshot = Snapshot(entries: loaded)
        return loaded
    }

    private func readFile() -> [String: Entry] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            lastLoadFailureDescription = "读取刮削缓存失败:\(error)"
            Self.logger.error("刮削缓存读取失败 \(String(describing: error), privacy: .public)")
            return [:]
        }
        do {
            let decoder = JSONDecoder()
            // ⚠️ 与写入对称,理由见 `BaiduPanDirectoryCache.readFile`
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Snapshot.self, from: data).entries
        } catch {
            lastLoadFailureDescription = "刮削缓存文件损坏:\(error)"
            Self.logger.error("刮削缓存文件损坏 \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private func persist(_ entries: [String: Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(Snapshot(entries: entries))
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).tmp")
            guard FileManager.default.createFile(
                atPath: temporary.path(percentEncoded: false),
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                lastWriteFailureDescription = "刮削缓存写入失败(创建临时文件)"
                return
            }
            guard rename(
                temporary.path(percentEncoded: false),
                fileURL.path(percentEncoded: false)) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                lastWriteFailureDescription = "刮削缓存写入失败(替换文件)"
                return
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = fileURL
            try? target.setResourceValues(values)
            snapshot = Snapshot(entries: entries)
            lastWriteFailureDescription = nil
        } catch {
            lastWriteFailureDescription = "刮削缓存写入失败:\(error)"
            Self.logger.error("刮削缓存写入失败 \(String(describing: error), privacy: .public)")
        }
    }
}
