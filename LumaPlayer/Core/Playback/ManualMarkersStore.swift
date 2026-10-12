import Foundation
import os

/// 本地「手动片头 / 片尾」库:用户自己标的片头片尾(**不动服务端**)。
///
/// ## 为什么不是服务端能力
///
/// Emby 的章节标记(`Chapters` 里的 `IntroStart` / `CreditsStart`)由服务端生成,需要
/// Premiere / 插件,而且客户端**没有写回它们的接口**(`API_CONTRACT.md` 4.3.1 只读)。
/// 所以「服务端检测不出来时自己标一个」只能记在本地 —— 与 `HiddenItemsStore`
/// 同一个理由、同一套做法。
///
/// ## 键与作用范围
///
/// 键是 `ManualMarkersScope.key(for:)` 算出的**剧**范围键:同一部剧的每一集共用一份。
///
/// ⚠️ 落点与凭据文件同级(`Library/Application Support/LumaPlayer/`)。
actor ManualMarkersStore {

    private static let logger = Logger(
        subsystem: NetworkDiagnostics.subsystem, category: "manual-markers")

    private let fileURL: URL
    private var loaded: [String: ManualMarkers]?
    /// 读盘失败的原因(诊断用)。**不静默吞**:读到损坏的文件时把原因留下来,
    /// 由调用方决定要不要提示;⛔ 不假装「没有记录」然后继续。
    private(set) var lastLoadFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 生产路径:与凭据文件、续播库、隐藏列表同在应用支持目录下。
    ///
    /// ⚠️ 测试宿主用**另一个文件名**:单元测试跑在宿主 App 进程里、共享真实沙盒容器,
    /// 写同一个文件会把真实记录冲掉。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let filename = isTestHost ? "manual-markers-testhost.json" : "manual-markers.json"
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
    }

    // MARK: - 读

    /// 某个范围键的标注;没设过时为 nil。
    func record(for scopeKey: String) -> ManualMarkers? {
        entries()[scopeKey]
    }

    /// 全部标注(范围键 → 记录)。
    func all() -> [String: ManualMarkers] {
        entries()
    }

    // MARK: - 写

    /// 记下 / 覆盖某个范围键的标注。`isEmpty` 的记录直接删条目(等价于清除)。
    func set(_ markers: ManualMarkers, for scopeKey: String) throws {
        var current = entries()
        if markers.isEmpty {
            guard current.removeValue(forKey: scopeKey) != nil else { return }
        } else {
            current[scopeKey] = markers
        }
        try persist(current)
    }

    /// 清除某个范围键的标注。
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
        // 0600:「哪一部剧怎么标」属于个人使用记录,不该对同机其他用户可读
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

/// 手动片头片尾写不进去。
///
/// ⚠️ 与 `HiddenItemsStoreError` 分开:写入失败要能说清是**哪个**本地库出的事。
enum ManualMarkersStoreError: LocalizedError, Sendable, Equatable {
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .writeFailed: return "手动片头片尾写入失败"
        }
    }
}
