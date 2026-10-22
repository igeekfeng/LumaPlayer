import Foundation
import os

/// 用户选定的弹幕库(仅本地记录)。两层:
/// - 集(键 `DanmakuMediaQuery.itemKey`):手选 / 精确匹配后写入,下次同一集直接用,不再请求 `/match`。
/// - 剧(键 `DanmakuMediaQuery.seriesKey`):对应的弹弹play 作品,其余集按集号在作品剧集列表里对上
///   (`DanmakuService.resolve`)。
///
/// 文件与凭据文件同目录,写法同 `ManualMarkersStore`(0600、原子替换、不进备份)。
actor DanmakuBindingStore {

    struct EpisodeBinding: Codable, Sendable, Equatable {
        let episodeID: Int64
        let animeID: Int64
        let animeTitle: String?
        let episodeTitle: String?
        /// 秒,正数 = 弹幕延后,来自 `/match` 的 `shift`;手选的为 nil
        let shift: Double?
    }

    struct SeriesBinding: Codable, Sendable, Equatable {
        let animeID: Int64
        let animeTitle: String?
    }

    private struct Contents: Codable {
        var episodes: [String: EpisodeBinding] = [:]
        var series: [String: SeriesBinding] = [:]
    }

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "danmaku")

    private let fileURL: URL
    private var loaded: Contents?
    /// 读盘失败的原因;非 nil 时 `persist` 拒绝覆盖原文件。
    private(set) var lastLoadFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 测试宿主用另一个文件名(理由见 `ManualMarkersStore.defaultFileURL`)。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(
                path: isTestHost ? "danmaku-bindings-testhost.json" : "danmaku-bindings.json",
                directoryHint: .notDirectory)
    }

    // MARK: - 读

    func episode(for key: String) -> EpisodeBinding? { contents().episodes[key] }

    func series(for key: String) -> SeriesBinding? { contents().series[key] }

    // MARK: - 写

    /// 记下这一集的弹幕库;`seriesKey` 非 nil 时同时记下整部剧对应的作品。
    func bind(_ binding: EpisodeBinding, itemKey: String, seriesKey: String?) throws {
        var current = contents()
        current.episodes[itemKey] = binding
        if let seriesKey {
            current.series[seriesKey] = SeriesBinding(animeID: binding.animeID, animeTitle: binding.animeTitle)
        }
        try persist(current)
    }

    /// 解除这一集及其所在剧的绑定。
    func unbind(itemKey: String, seriesKey: String?) throws {
        var current = contents()
        var changed = current.episodes.removeValue(forKey: itemKey) != nil
        if let seriesKey { changed = current.series.removeValue(forKey: seriesKey) != nil || changed }
        guard changed else { return }
        try persist(current)
    }

    /// 删除服务器时用。返回删了几条。
    @discardableResult
    func purge(keyPrefix: String) throws -> Int {
        var current = contents()
        let before = current.episodes.count + current.series.count
        current.episodes = current.episodes.filter { !$0.key.hasPrefix(keyPrefix) }
        current.series = current.series.filter { !$0.key.hasPrefix(keyPrefix) }
        let removed = before - current.episodes.count - current.series.count
        if removed > 0 { try persist(current) }
        return removed
    }

    // MARK: - 内部

    private func contents() -> Contents {
        if let loaded { return loaded }
        let result = readFile()
        loaded = result
        return result
    }

    private func readFile() -> Contents {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Contents()
        } catch {
            lastLoadFailureDescription = "读取弹幕绑定失败:\(error)"
            Self.logger.error("弹幕绑定读取失败 \(String(describing: error), privacy: .public)")
            return Contents()
        }
        do {
            return try JSONDecoder().decode(Contents.self, from: data)
        } catch {
            lastLoadFailureDescription = "弹幕绑定文件损坏:\(error)"
            Self.logger.error("弹幕绑定文件损坏 \(String(describing: error), privacy: .public)")
            return Contents()
        }
    }

    private func persist(_ contents: Contents) throws {
        // 读盘失败过就不写:写回去等于用空记录覆盖掉一个可能还能修的文件
        if let lastLoadFailureDescription {
            throw DanmakuBindingStoreError.unreadable(lastLoadFailureDescription)
        }
        let data = try JSONEncoder().encode(contents)
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DanmakuBindingStoreError.writeFailed
        }
        guard FileManager.default.createFile(
            atPath: temporary.path(percentEncoded: false),
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw DanmakuBindingStoreError.writeFailed
        }
        guard rename(temporary.path(percentEncoded: false), fileURL.path(percentEncoded: false)) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw DanmakuBindingStoreError.writeFailed
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = fileURL
        try target.setResourceValues(values)
        loaded = contents
    }
}

enum DanmakuBindingStoreError: LocalizedError, Sendable, Equatable {
    case writeFailed
    /// 为保护读不出 / 已损坏的原文件拒绝覆盖
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed: return "弹幕绑定写入失败"
        case .unreadable(let reason): return "弹幕绑定文件无法读取,未覆盖:\(reason)"
        }
    }
}
