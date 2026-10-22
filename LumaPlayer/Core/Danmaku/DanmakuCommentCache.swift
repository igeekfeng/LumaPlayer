import Foundation
import os

/// 弹幕磁盘缓存,每个弹幕库一个文件。官方要求客户端缓存,弹幕建议 2 - 6 小时(`docs/DANDANPLAY_API.md` §6),取 4 小时。
///
/// 放 `Caches/`,⛔ 不放应用支持目录。存的是已解析的 `DanmakuComment`,解析规则改了要换 `formatVersion`。
///
/// `cleanUp` 启动时调一次,删过期 / 读不出 / 损坏 / 版本不对的文件(过期即重新请求,⛔ 不拿旧弹幕兜底)。
/// 过期按文件里的 `fetchedAt` 判断,与读取同一判据;⛔ 不改看文件修改时间(拷贝 / 恢复会改,也不受注入的 `now` 控制)。
actor DanmakuCommentCache {

    static let freshness: TimeInterval = 4 * 60 * 60
    private static let formatVersion = 1
    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "danmaku")

    private struct Entry: Codable {
        let version: Int
        let fetchedAt: Date
        let comments: [DanmakuComment]
    }

    private let directory: URL
    private let now: @Sendable () -> Date

    init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    static var defaultDirectory: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "LumaPlayer", directoryHint: .isDirectory)
            .appending(path: isTestHost ? "danmaku-testhost" : "danmaku", directoryHint: .isDirectory)
    }

    /// 没有 / 过期 / 读不出都返回 nil(= 重新请求,不是错误)。
    func comments(forEpisode episodeID: Int64) -> [DanmakuComment]? {
        let url = fileURL(episodeID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let entry = try JSONDecoder().decode(Entry.self, from: data)
            guard entry.version == Self.formatVersion,
                  now().timeIntervalSince(entry.fetchedAt) < Self.freshness else { return nil }
            return entry.comments
        } catch {
            Self.logger.error("弹幕缓存损坏,将重新获取 \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 失败只记日志,不影响这一次显示弹幕。
    func store(_ comments: [DanmakuComment], forEpisode episodeID: Int64) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(
                Entry(version: Self.formatVersion, fetchedAt: now(), comments: comments))
            try data.write(to: fileURL(episodeID), options: .atomic)
        } catch {
            Self.logger.error("弹幕缓存写入失败 \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 清理

    struct CleanupReport: Sendable, Equatable {
        var removedFiles = 0
        var removedBytes = 0
    }

    /// 只看目录下一层的普通文件。失败抛错,已删的不回滚,下次启动接着清。
    func cleanUp() throws -> CleanupReport {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path(percentEncoded: false)) else { return CleanupReport() }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let current = now()
        var report = CleanupReport()
        for url in try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, !isFresh(url, now: current) else { continue }
            try manager.removeItem(at: url)
            report.removedFiles += 1
            report.removedBytes += values.fileSize ?? 0
        }
        return report
    }

    /// 与 `comments(forEpisode:)` 同一判据;读不出 / 解不开算不新鲜。
    private func isFresh(_ url: URL, now: Date) -> Bool {
        do {
            let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
            return entry.version == Self.formatVersion && now.timeIntervalSince(entry.fetchedAt) < Self.freshness
        } catch {
            Self.logger.info("弹幕缓存文件无法读取,清理时删除 \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func fileURL(_ episodeID: Int64) -> URL {
        directory.appending(path: "\(episodeID).json", directoryHint: .notDirectory)
    }
}
