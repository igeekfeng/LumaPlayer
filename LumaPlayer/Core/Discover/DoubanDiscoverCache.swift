import Foundation
import os

/// 豆瓣榜单响应的落盘缓存:**同一接口同一天只发一次请求**。
///
/// 为什么按「自然日」而不是 TTL:豆瓣的更新是**按天**的(剧集进度「更新至 N 集」一天最多变一次),
/// 按小时计 TTL 只会在一天里反复打同一个接口 —— 这正是要避免的。换日之后第一个请求重新拉,
/// 之后当天全部命中。榜单里被反爬风控的风险也因此压到最低。
///
/// 存原始响应字节、不存解码值:与 `EmbyResponseCache` 同一立场 —— 命中后走同一条解码路径,
/// 缓存与网络的形状差异不会变成两套代码。key 就是完整请求 URL(collection + start + count)。
///
/// 尽力而为:读写盘失败只记日志,不挡请求。
actor DoubanDiscoverCache {

    private static let logger = Logger(
        subsystem: NetworkDiagnostics.subsystem, category: "douban-discover-cache")

    /// 命中要满足:同一天 + 同一个 URL。
    struct Entry: Codable, Sendable {
        var body: Data
        var storedAt: Date
    }

    private struct Snapshot: Codable, Sendable {
        var entries: [String: Entry]
    }

    /// 只留当天与昨天的条目:跨天后再也不命中,留着只会把文件撑大。
    static let retention: TimeInterval = 2 * 24 * 60 * 60

    /// 上限:一组榜单翻到底也就十几页,七组加起来远到不了这个数;到了就丢最旧的。
    static let entryLimit = 200

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var snapshot: Snapshot?
    private(set) var lastLoadFailureDescription: String?
    private(set) var lastWriteFailureDescription: String?

    init(
        fileURL: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.fileURL = fileURL
        self.now = now
        self.calendar = calendar
    }

    /// 与凭据文件同目录。⚠️ 测试宿主另用文件名:单测跑在宿主 App 进程里,共享真实沙盒容器。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let filename = isTestHost
            ? "douban-discover-cache-testhost.json"
            : "douban-discover-cache.json"
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
    }

    // MARK: - 读

    /// 当天已缓存就返回响应体;跨天 / 没有 / 损坏返回 nil(损坏即当作未命中,重新请求)。
    func body(for url: URL) -> Data? {
        guard let entry = entries()[Self.key(url)] else { return nil }
        guard isSameDay(entry.storedAt, now()) else { return nil }
        return entry.body
    }

    // MARK: - 写

    func store(body: Data, for url: URL) {
        var current = entries()
        current[Self.key(url)] = Entry(body: body, storedAt: now())
        persist(current)
    }

    /// 只保留 `retention` 内的条目,超上限时丢最旧的。
    private func pruned(_ entries: [String: Entry], at reference: Date) -> [String: Entry] {
        var kept = entries.filter { reference.timeIntervalSince($0.value.storedAt) <= Self.retention }
        guard kept.count > Self.entryLimit else { return kept }
        let oldestFirst = kept.sorted { $0.value.storedAt < $1.value.storedAt }
        for (key, _) in oldestFirst.prefix(kept.count - Self.entryLimit) {
            kept.removeValue(forKey: key)
        }
        return kept
    }

    // MARK: - 内部

    private static func key(_ url: URL) -> String { url.absoluteString }

    private func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    private func entries() -> [String: Entry] {
        if let snapshot { return snapshot.entries }
        let loaded = readFile()
        snapshot = loaded
        return loaded.entries
    }

    private func readFile() -> Snapshot {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Snapshot(entries: [:])
        } catch {
            lastLoadFailureDescription = "读取榜单缓存失败:\(error)"
            Self.logger.error("榜单缓存读取失败 \(String(describing: error), privacy: .public)")
            return Snapshot(entries: [:])
        }
        do {
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            // ⛔ 不就地重置成空文件:记下原因,下次写盘自然覆盖
            lastLoadFailureDescription = "榜单缓存文件损坏:\(error)"
            Self.logger.error("榜单缓存文件损坏 \(String(describing: error), privacy: .public)")
            return Snapshot(entries: [:])
        }
    }

    private func persist(_ entries: [String: Entry]) {
        let trimmed = pruned(entries, at: now())
        do {
            let data = try JSONEncoder().encode(Snapshot(entries: trimmed))
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).tmp")
            // 0600:榜单本身不是秘密,但统一按用户数据对待,免得以后往里加字段要重新审一遍
            guard FileManager.default.createFile(
                atPath: temporary.path(percentEncoded: false),
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                lastWriteFailureDescription = "榜单缓存写入失败(创建临时文件)"
                return
            }
            guard rename(
                temporary.path(percentEncoded: false),
                fileURL.path(percentEncoded: false)) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                lastWriteFailureDescription = "榜单缓存写入失败(替换文件)"
                return
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = fileURL
            try? target.setResourceValues(values)
            snapshot = Snapshot(entries: trimmed)
            lastWriteFailureDescription = nil
        } catch {
            lastWriteFailureDescription = "榜单缓存写入失败:\(error)"
            Self.logger.error("榜单缓存写入失败 \(String(describing: error), privacy: .public)")
        }
    }
}
