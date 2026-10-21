import Foundation
import os

/// 百度网盘条目的**刮削结果落盘缓存**:`fs_id` → TMDB 补回来的那几个字段。
///
/// ## 为什么需要它
///
/// `BaiduPanMetadataScraper` 内部有四张查询缓存,但**全在内存**:重启 App 之后
/// 同一个目录会重新问一遍 TMDB(搜索 + 季详情 + 详情 + 演职员)。结果是
/// 冷启动第一屏的封面总要慢一拍,断网时整片片库退回图标卡。
///
/// 这一层只存**条目级**的补丁(封面 / 简介 / 年份 / 集名 / TMDB id),不存
/// 剧级扩展信息(`seriesProfile`):后者只在详情页发、且随季不变,进程内缓存够用。
///
/// ## 为什么可以按 `fs_id` 认
///
/// `fs_id` 是网盘里这条文件的稳定身份 —— 改名 / 挪目录都不变
/// (`docs/BAIDU_PAN_API.md` §2.2)。文件被替换 = 新上传 = 新 `fs_id`,
/// 所以「同 id 就是同一份内容」成立,不需要再拿 `mtime` 做版本段。
///
/// ⚠️ 失效只有两档:时间(30 天,兜住 TMDB 那边改名 / 改简介的情况)与
/// 显式清(删除来源)。⛔ 不做「每天重刮一遍」—— 那是拿 TMDB 请求换不到的东西。
actor BaiduPanScrapeCache {

    /// 一条刮削补丁。全部可选:哪一项当时没拿到就不存,下次还会再问。
    struct Entry: Codable, Sendable, Equatable {
        /// 封面快照。⚠️ 只可能是**远端图**(TMDB 图床),它的地址不会过期;
        /// 百度同目录封面的 `dlink` 8 小时过期,**不进这里**(那是 `PosterDiskCache` 的事)。
        var poster: ImageDescriptor.Snapshot?
        var overview: String?
        var year: Int?
        var episodeTitle: String?
        var tmdbID: Int?
        var savedAt: Date

        /// 什么都没补到 = 不值得存(存了也只是让下次跳过网络再空一次)
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

    /// 30 天。TMDB 的简介 / 海报极少变,而「重刮一遍」的代价是一串网络请求。
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private let fileURL: URL
    private var snapshot: Snapshot?
    private(set) var lastLoadFailureDescription: String?
    private(set) var lastWriteFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 生产路径:与凭据文件、续播库同在应用支持目录下(测试宿主另用文件名)。
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

    /// 批量写入(一次落盘)。失败只记原因 —— 刮削缓存坏了不该影响浏览。
    func store(sourceID: UUID, entries: [String: Entry]) {
        guard !entries.isEmpty else { return }
        var all = state()
        for (fsID, entry) in entries where !entry.isEmpty {
            all[Self.key(sourceID: sourceID, fsID: fsID)] = entry
        }
        persist(all)
    }

    /// 删除来源时整片清掉。
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
