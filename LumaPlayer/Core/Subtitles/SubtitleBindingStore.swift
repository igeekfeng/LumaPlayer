import Foundation
import os

/// 每一集上次挂的外挂字幕(本地记录),下次播同一集自动挂上。
///
/// - 键:`DanmakuMediaQuery.itemKey`(Emby `emby|<服务器 id>|<Item Id>`,百度 `baidu|fsid:<fs_id>`),⛔ 不另造身份。
/// - 值:只记最后一次挂的那条。
/// - 在线字幕同时记 assrt id,缓存被清后可重新取回;本地字幕文件没了就如实提示并删记录。
///
/// 保留期同 `SubtitleFileStore.retention`,过期记录与文件一起清(`AppContainer.cleanUpSubtitleCache`);
/// 删服务器时按前缀删(`purge(keyPrefix:)`)。
///
/// 文件与凭据文件同目录,写法同 `DanmakuBindingStore`(0600、原子替换、不进备份;读盘失败过就拒绝覆盖)。
actor SubtitleBindingStore {

    struct Binding: Codable, Sendable, Equatable {
        /// `<组>/<原文件名>`
        let relativePath: String
        let title: String
        /// 本地导入的为 nil
        let assrtID: Int?
        /// 手动挂、自动恢复都会刷新
        let lastUsed: Date
    }

    private struct Contents: Codable {
        var episodes: [String: Binding] = [:]
    }

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "subtitles")

    private let fileURL: URL
    private var loaded: Contents?
    /// 读盘失败的原因;非 nil 时拒绝覆盖原文件(见 `persist`)。
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
                path: isTestHost ? "subtitle-bindings-testhost.json" : "subtitle-bindings.json",
                directoryHint: .notDirectory)
    }

    // MARK: - 读

    func binding(for itemKey: String) -> Binding? { contents().episodes[itemKey] }

    /// 清理缓存时要保留的组
    func referencedGroups() -> Set<String> {
        Set(contents().episodes.values.compactMap { $0.relativePath.split(separator: "/").first.map(String.init) })
    }

    // MARK: - 写

    func bind(_ binding: Binding, for itemKey: String) throws {
        var current = contents()
        current.episodes[itemKey] = binding
        try persist(current)
    }

    func unbind(itemKey: String) throws {
        var current = contents()
        guard current.episodes.removeValue(forKey: itemKey) != nil else { return }
        try persist(current)
    }

    /// 返回删了几条。
    @discardableResult
    func purge(keyPrefix: String) throws -> Int {
        var current = contents()
        let before = current.episodes.count
        current.episodes = current.episodes.filter { !$0.key.hasPrefix(keyPrefix) }
        let removed = before - current.episodes.count
        if removed > 0 { try persist(current) }
        return removed
    }

    /// 返回删了几条。
    @discardableResult
    func prune(now: Date = Date(), retention: TimeInterval = SubtitleFileStore.retention) throws -> Int {
        var current = contents()
        let before = current.episodes.count
        current.episodes = current.episodes.filter { now.timeIntervalSince($0.value.lastUsed) <= retention }
        let removed = before - current.episodes.count
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
            lastLoadFailureDescription = "读取字幕记录失败:\(error)"
            Self.logger.error("字幕记录读取失败 \(String(describing: error), privacy: .public)")
            return Contents()
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Contents.self, from: data)
        } catch {
            lastLoadFailureDescription = "字幕记录文件损坏:\(error)"
            Self.logger.error("字幕记录文件损坏 \(String(describing: error), privacy: .public)")
            return Contents()
        }
    }

    private func persist(_ contents: Contents) throws {
        // 读盘失败过就不写,免得用空记录覆盖可能还能修的文件
        if let lastLoadFailureDescription {
            throw SubtitleBindingStoreError.unreadable(lastLoadFailureDescription)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(contents)
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SubtitleBindingStoreError.writeFailed
        }
        guard FileManager.default.createFile(
            atPath: temporary.path(percentEncoded: false),
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SubtitleBindingStoreError.writeFailed
        }
        guard rename(temporary.path(percentEncoded: false), fileURL.path(percentEncoded: false)) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw SubtitleBindingStoreError.writeFailed
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = fileURL
        try target.setResourceValues(values)
        loaded = contents
    }
}

enum SubtitleBindingStoreError: LocalizedError, Sendable, Equatable {
    case writeFailed
    /// 为保护原文件拒绝覆盖
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed: return "字幕记录写入失败"
        case .unreadable(let reason): return "字幕记录文件无法读取,未覆盖:\(reason)"
        }
    }
}
