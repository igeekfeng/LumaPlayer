import Foundation
import os

/// 用户选定的弹幕库(仅本地记录)。两层:
/// - 集(键 `DanmakuMediaQuery.itemKey`):手选 / 精确匹配后写入,下次同一集直接用,不再请求 `/match`。
/// - 剧(键 `DanmakuMediaQuery.seriesKey`):对应的弹幕作品,其余集按集号在作品剧集列表里对上
///   (`DanmakuService.resolve`)。
///
/// 每个弹幕来源一套(`DanmakuSource.id`):各来源的 episodeId / animeId 各自编号,混用会拿别人的 ID
/// 去问另一个服务。官方的放在文件顶层 `episodes` / `series`,自建来源的放 `sources[id]`。
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

    private struct Bindings: Codable {
        var episodes: [String: EpisodeBinding] = [:]
        var series: [String: SeriesBinding] = [:]

        var count: Int { episodes.count + series.count }

        mutating func purge(keyPrefix: String) {
            episodes = episodes.filter { !$0.key.hasPrefix(keyPrefix) }
            series = series.filter { !$0.key.hasPrefix(keyPrefix) }
        }
    }

    private struct Contents: Codable {
        var episodes: [String: EpisodeBinding] = [:]
        var series: [String: SeriesBinding] = [:]
        /// 自建来源,键 = `DanmakuSource.id`
        var sources: [String: Bindings] = [:]

        init() {}

        /// 只有官方绑定的文件没有 `sources` 键。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            episodes = try container.decode([String: EpisodeBinding].self, forKey: .episodes)
            series = try container.decode([String: SeriesBinding].self, forKey: .series)
            sources = try container.decodeIfPresent([String: Bindings].self, forKey: .sources) ?? [:]
        }

        subscript(source: String) -> Bindings {
            get {
                source == DanmakuSource.officialID
                    ? Bindings(episodes: episodes, series: series)
                    : sources[source] ?? Bindings()
            }
            set {
                if source == DanmakuSource.officialID {
                    episodes = newValue.episodes
                    series = newValue.series
                } else if newValue.count == 0 {
                    sources.removeValue(forKey: source)
                } else {
                    sources[source] = newValue
                }
            }
        }

        var count: Int { episodes.count + series.count + sources.values.reduce(0) { $0 + $1.count } }
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

    func episode(for key: String, source: String) -> EpisodeBinding? { contents()[source].episodes[key] }

    func series(for key: String, source: String) -> SeriesBinding? { contents()[source].series[key] }

    // MARK: - 写

    /// 记下这一集的弹幕库;`seriesKey` 非 nil 时同时记下整部剧对应的作品。
    func bind(_ binding: EpisodeBinding, itemKey: String, seriesKey: String?, source: String) throws {
        var current = contents()
        current[source].episodes[itemKey] = binding
        if let seriesKey {
            current[source].series[seriesKey] = SeriesBinding(
                animeID: binding.animeID, animeTitle: binding.animeTitle)
        }
        try persist(current)
    }

    /// 解除这一集 / 所在剧的绑定(传 nil 的那层不动)。
    func unbind(itemKey: String?, seriesKey: String?, source: String) throws {
        var current = contents()
        var changed = false
        if let itemKey { changed = current[source].episodes.removeValue(forKey: itemKey) != nil }
        if let seriesKey { changed = current[source].series.removeValue(forKey: seriesKey) != nil || changed }
        guard changed else { return }
        try persist(current)
    }

    /// 删除媒体服务器时用,所有弹幕来源一起清。返回删了几条。
    @discardableResult
    func purge(keyPrefix: String) throws -> Int {
        var current = contents()
        let before = current.count
        var official = current[DanmakuSource.officialID]
        official.purge(keyPrefix: keyPrefix)
        current[DanmakuSource.officialID] = official
        for id in Array(current.sources.keys) {
            var bindings = current[id]
            bindings.purge(keyPrefix: keyPrefix)
            current[id] = bindings
        }
        let removed = before - current.count
        if removed > 0 { try persist(current) }
        return removed
    }

    /// 删除自建弹幕来源时用。
    @discardableResult
    func purge(source: String) throws -> Int {
        var current = contents()
        let removed = current[source].count
        guard removed > 0 else { return 0 }
        current[source] = Bindings()
        try persist(current)
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
