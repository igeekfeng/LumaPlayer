import Foundation
import os

/// 百度网盘目录的落盘缓存(按 来源 + 路径):进目录先出缓存内容,同时后台刷新、回来就地替换。
/// 配额极低(`docs/BAIDU_PAN_API.md` §7),而内存缓存(`FileSourceViewModel.directoryCache`)切来源 / 重启就空。
///
/// ⛔ 不存封面地址(`dlink` 会过期,封面靠 `PosterDiskCache` 兜)与刮削结果(`BaiduPanScrapeCache`,失效条件不同)。
///
/// 不按时间丢:过期的照样先显示,只是要后台刷新(`isFresh`);容量靠 `maxDirectoriesPerSource`。
/// 删 / 改名 / 隐藏后调用方 `remove`;删来源时 `purge`。
/// 缓存只用于显示,不是事实来源:已删的文件播放会如实失败,后台刷新随后抹掉。
actor BaiduPanDirectoryCache {

    struct Entry: Codable, Sendable, Equatable {
        let files: [BaiduPanFile]
        /// `fs_id` → 时长(秒),来自 `filemetas`(列表接口不给)。
        /// 键用 `String`:`UInt64` 键会被编码成数组。
        let durations: [String: Double]
        let fetchedAt: Date
        /// 这一份是不是**整层**。false = 翻页没列完就存了(配额预算用尽或用户没滚到底),
        /// 冷启动显示它时要提示「还有更多」,⛔ 别让用户以为目录就这么大。
        ///
        /// ⛔ 缺这个字段的老缓存一律当**不完整**:宁可多提示一句,也不能把截断当完整。
        let isComplete: Bool

        func duration(for fsID: UInt64) -> Double? {
            durations[String(fsID)]
        }

        init(files: [BaiduPanFile], durations: [String: Double], fetchedAt: Date, isComplete: Bool) {
            self.files = files
            self.durations = durations
            self.fetchedAt = fetchedAt
            self.isComplete = isComplete
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            files = try container.decode([BaiduPanFile].self, forKey: .files)
            durations = try container.decode([String: Double].self, forKey: .durations)
            fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
            // 老缓存没有这一格 → 当不完整
            isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
        }
    }

    /// 磁盘上的整份文件:`来源 id` → `目录路径` → 快照。
    private struct Snapshot: Codable, Sendable {
        var sources: [String: [String: Entry]]
    }

    private static let logger = Logger(
        subsystem: NetworkDiagnostics.subsystem, category: "baidu-directory-cache")

    /// 窗口内的缓存直接用、不后台刷新(配额 / 限速);要更早看到新内容按 ⌘R。与 Emby 响应缓存同一口径。
    static let freshWindow: TimeInterval = 12 * 60 * 60

    static func isFresh(_ entry: Entry, now: Date = Date()) -> Bool {
        now.timeIntervalSince(entry.fetchedAt) <= freshWindow
    }

    /// 超出时按 `fetchedAt` 丢最旧的。
    static let maxDirectoriesPerSource = 300

    private let fileURL: URL
    private var snapshot: Snapshot?
    /// 读盘失败的原因(诊断用)。缓存坏了浏览照常走网络。
    private(set) var lastLoadFailureDescription: String?
    /// 最近一次写盘失败的原因(nil = 没失败),不影响浏览。
    private(set) var lastWriteFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 与凭据文件同目录。测试宿主用另一个文件名,避免单测冲掉真实缓存。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let filename = isTestHost
            ? "baidu-directory-cache-testhost.json"
            : "baidu-directory-cache.json"
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
    }

    // MARK: - 读

    /// 不论新旧,有就给;要不要后台刷新由调用方看 `isFresh`。
    func content(sourceID: UUID, directory: String) -> Entry? {
        state()[sourceID.uuidString]?[directory]
    }

    // MARK: - 写

    /// 整层替换。失败只记原因,⛔ 不抛给浏览链路。
    ///
    /// - Parameter isComplete: 这一份是不是整层。false = 翻页没列完就存了,
    ///   冷启动时要提示「还有更多」(见 `Entry.isComplete`)。
    func store(
        sourceID: UUID,
        directory: String,
        files: [BaiduPanFile],
        durations: [UInt64: Double],
        isComplete: Bool = true,
        now: Date = Date()
    ) {
        var all = state()
        var perSource = all[sourceID.uuidString] ?? [:]
        perSource[directory] = Entry(
            files: files,
            durations: Dictionary(
                durations.map { (String($0.key), $0.value) },
                uniquingKeysWith: { first, _ in first }),
            fetchedAt: now,
            isComplete: isComplete
        )
        if perSource.count > Self.maxDirectoriesPerSource {
            let overflow = perSource.count - Self.maxDirectoriesPerSource
            let oldest = perSource
                .sorted { $0.value.fetchedAt < $1.value.fetchedAt }
                .prefix(overflow)
                .map(\.key)
            for key in oldest { perSource.removeValue(forKey: key) }
        }
        all[sourceID.uuidString] = perSource
        persist(all)
    }

    /// 删 / 改名 / 隐藏之后调用。`includeDescendants` 为真时连子层一起丢。
    func remove(sourceID: UUID, directory: String, includeDescendants: Bool = true) {
        var all = state()
        guard var perSource = all[sourceID.uuidString] else { return }
        let removed = perSource.keys.filter { key in
            key == directory
                || (includeDescendants && BaiduPanPath.isInside(key, applicationRoot: directory))
        }
        guard !removed.isEmpty else { return }
        for key in removed { perSource.removeValue(forKey: key) }
        all[sourceID.uuidString] = perSource
        persist(all)
    }

    func purge(sourceID: UUID) {
        var all = state()
        guard all.removeValue(forKey: sourceID.uuidString) != nil else { return }
        persist(all)
    }

    // MARK: - 内部

    private func state() -> [String: [String: Entry]] {
        if let snapshot { return snapshot.sources }
        let loaded = readFile()
        snapshot = Snapshot(sources: loaded)
        return loaded
    }

    private func readFile() -> [String: [String: Entry]] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            lastLoadFailureDescription = "读取百度目录缓存失败:\(error)"
            Self.logger.error("目录缓存读取失败 \(String(describing: error), privacy: .public)")
            return [:]
        }
        do {
            let decoder = JSONDecoder()
            // ⚠️ 必须与写入同一策略,否则整份文件被判损坏(docs/PITFALLS.md)
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Snapshot.self, from: data).sources
        } catch {
            // ⛔ 不就地重置成空文件:记下原因,下次写盘自然覆盖
            lastLoadFailureDescription = "百度目录缓存文件损坏:\(error)"
            Self.logger.error("目录缓存文件损坏 \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private func persist(_ sources: [String: [String: Entry]]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(Snapshot(sources: sources))
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).tmp")
            // 0600:目录名是用户的片名,属隐私
            guard FileManager.default.createFile(
                atPath: temporary.path(percentEncoded: false),
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                lastWriteFailureDescription = "目录缓存写入失败(创建临时文件)"
                return
            }
            guard rename(
                temporary.path(percentEncoded: false),
                fileURL.path(percentEncoded: false)) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                lastWriteFailureDescription = "目录缓存写入失败(替换文件)"
                return
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = fileURL
            try? target.setResourceValues(values)
            snapshot = Snapshot(sources: sources)
            lastWriteFailureDescription = nil
        } catch {
            lastWriteFailureDescription = "目录缓存写入失败:\(error)"
            Self.logger.error("目录缓存写入失败 \(String(describing: error), privacy: .public)")
        }
    }
}
