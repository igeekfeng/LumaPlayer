import Foundation
import os

/// 本地手动片头 / 片尾库(服务端章节标记只读,`API_CONTRACT.md` 4.3.1;做法同 `HiddenItemsStore`)。
///
/// 键是 `ManualMarkersScope.key(for:)` 的剧范围键。文件与凭据文件同目录。
actor ManualMarkersStore {

    private static let logger = Logger(
        subsystem: NetworkDiagnostics.subsystem, category: "manual-markers")

    private let fileURL: URL
    private var loaded: [String: ManualMarkers]?
    /// 读盘失败的原因,由调用方决定是否提示;⛔ 不假装「没有记录」。
    private(set) var lastLoadFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 测试宿主用另一个文件名:单测跑在宿主 App 里、共享真实沙盒容器,同名会冲掉真实记录。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let filename = isTestHost ? "manual-markers-testhost.json" : "manual-markers.json"
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
    }

    // MARK: - 读

    func record(for scopeKey: String) -> ManualMarkers? {
        entries()[scopeKey]
    }

    func all() -> [String: ManualMarkers] {
        entries()
    }

    // MARK: - 写

    /// `isEmpty` 的记录直接删条目。
    func set(_ markers: ManualMarkers, for scopeKey: String) throws {
        var current = entries()
        if markers.isEmpty {
            guard current.removeValue(forKey: scopeKey) != nil else { return }
        } else {
            current[scopeKey] = markers
        }
        try persist(current)
    }

    func remove(for scopeKey: String) throws {
        var current = entries()
        guard current.removeValue(forKey: scopeKey) != nil else { return }
        try persist(current)
    }

    // MARK: - 内部

    private func entries() -> [String: ManualMarkers] {
        if let loaded { return loaded }
        let result = readFile()
        loaded = result
        return result
    }

    private func readFile() -> [String: ManualMarkers] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            lastLoadFailureDescription = "读取手动片头片尾失败:\(error)"
            Self.logger.error("手动片头片尾读取失败 \(String(describing: error), privacy: .public)")
            return [:]
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([String: ManualMarkers].self, from: data)
        } catch {
            // ⛔ 不就地重置成空文件 —— 先如实记下原因
            lastLoadFailureDescription = "手动片头片尾文件损坏:\(error)"
            Self.logger.error("手动片头片尾文件损坏 \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private func persist(_ entries: [String: ManualMarkers]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ManualMarkersStoreError.writeFailed
        }
        // 0600:个人使用记录
        guard FileManager.default.createFile(
            atPath: temporary.path(percentEncoded: false),
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ManualMarkersStoreError.writeFailed
        }
        guard rename(temporary.path(percentEncoded: false), fileURL.path(percentEncoded: false)) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ManualMarkersStoreError.writeFailed
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = fileURL
        try target.setResourceValues(values)
        loaded = entries
    }
}

/// 与 `HiddenItemsStoreError` 分开,写失败时能说清是哪个本地库。
enum ManualMarkersStoreError: LocalizedError, Sendable, Equatable {
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .writeFailed: return "手动片头片尾写入失败"
        }
    }
}
