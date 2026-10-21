import Foundation
import os

/// 每一集上次挂的外挂字幕(**本地**记录,不动任何服务端)。下次播同一集自动挂上。
///
/// - 键:`DanmakuMediaQuery.itemKey`(Emby 是 `emby|<服务器 id>|<Item Id>`,百度是 `baidu|fsid:<fs_id>`)。
///   在线字幕的搜索关键词本来就取自同一个身份,⛔ 不另造一套来源判断。
/// - 值:只记**最后一次**挂的那条(`SubtitleFileStore.Stored.relativePath`),不记一串。
///   同一集挂过两条时,下次只恢复最后那条 —— 那是用户最近一次明确的选择。
/// - 在线字幕同时记 assrt 的 id:缓存被清掉后能按 id 重新取回(`SubtitleService.download(assrtID:)`);
///   本地字幕没有来源可以重取,文件没了就如实提示并删掉这条记录。
///
/// 保留期与缓存同为 `SubtitleFileStore.retention`:超过这么久没播过的集,记录与文件一起清掉
/// (`AppContainer.cleanUpSubtitleCache`)。删除 Emby 服务器时按前缀删掉它的记录(`purge(keyPrefix:)`)。
///
/// ⚠️ 落点与凭据文件同级(`Library/Application Support/LumaPlayer/subtitle-bindings.json`),
/// 写法与 `DanmakuBindingStore` 相同(0600、原子替换、不进备份;读盘失败过就拒绝覆盖)。
actor SubtitleBindingStore {

    struct Binding: Codable, Sendable, Equatable {
        /// 缓存目录里的相对路径(`<组>/<原文件名>`)
        let relativePath: String
        /// 菜单里显示的名字
        let title: String
        /// 在线字幕的 assrt id;本地导入的为 nil
        let assrtID: Int?
        /// 最近一次挂上的时间(手动挂、自动恢复都会刷新)
        let lastUsed: Date
    }

    private struct Contents: Codable {
        var episodes: [String: Binding] = [:]
    }

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "subtitles")

    private let fileURL: URL
    private var loaded: Contents?
    /// 读盘失败的原因。⛔ 不假装「没有记录」:损坏时留下原因,且**不覆盖**原文件(见 `persist`)。
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

    /// 所有记录引用到的缓存组(清理时保留它们)
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

    /// 删掉键以 `keyPrefix` 开头的记录(删除服务器时用)。返回删了几条。
    @discardableResult
    func purge(keyPrefix: String) throws -> Int {
        var current = contents()
        let before = current.episodes.count
        current.episodes = current.episodes.filter { !$0.key.hasPrefix(keyPrefix) }
        let removed = before - current.episodes.count
        if removed > 0 { try persist(current) }
        return removed
    }

    /// 删掉超过保留期没用过的记录。返回删了几条。
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
        // 读盘失败过就不写:写回去等于用空记录覆盖掉一个可能还能修的文件
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
    /// 文件读不出来 / 已损坏,为保护原文件拒绝覆盖
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed: return "字幕记录写入失败"
        case .unreadable(let reason): return "字幕记录文件无法读取,未覆盖:\(reason)"
        }
    }
}
