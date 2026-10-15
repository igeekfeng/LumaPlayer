import Foundation
import os

/// 弹幕的磁盘缓存(按弹幕库 id 一个文件)。
///
/// 弹弹play 官方要求客户端缓存返回的数据,弹幕这类变动少的数据建议缓存 **2 - 6 小时**
/// (`docs/DANDANPLAY_API.md` §6)。本缓存取 4 小时:同一集重播、换集回看、
/// 重试播放都不会再请求一次。
///
/// 放 `Caches/`(系统可清,丢了只是重新请求一次),⛔ 不放应用支持目录。
/// 缓存的是**已解析**的 `DanmakuComment`,不是原始响应 —— 解析规则改了要换 `formatVersion`。
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

    /// 未过期的缓存;没有 / 过期 / 读不出都返回 nil(缓存读不出 = 重新请求,不是错误)。
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

    /// 写缓存。失败只记日志:缓存写不进去不影响这一次显示弹幕。
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

    private func fileURL(_ episodeID: Int64) -> URL {
        directory.appending(path: "\(episodeID).json", directoryHint: .notDirectory)
    }
}
