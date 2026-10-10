import Foundation
import os

/// 本地续播库(`exp/avkit-rust-core` 上**百度源唯一的进度存储**)。
///
/// ## 为什么必须自己造一个
///
/// Emby 的「继续观看」是**服务端**能力:进度写在 Emby 上,换设备也在。
/// 百度网盘**没有播放进度上报接口**(文档 §5.2)——
/// 也就是说百度源上「接着看」这件事在服务端根本不存在,只能记在本地。
/// ⛔ 这不是接线问题,是产品能力缺口,文档 §5.2 已点明。
///
/// ## 为什么是 JSON 文件而不是 SQLite
///
/// 总纲 P4 要把数据层迁 SQLite,但 **P4 还没开工**。在 P4 落地之前引一层
/// 半吊子的 SQLite 只会变成「迁移时要先拆掉的东西」。这里用一个
/// 原子写、0600、不进备份的 JSON 文件 —— 与 `CredentialFileStore` 同一套做法,
/// 体量(自用场景下几千条)也完全不需要数据库。
///
/// ⚠️ 落点与凭据文件同级(`Library/Application Support/LumaPlayer/`)。
actor WatchProgressStore {

    /// 一条进度记录。
    struct Entry: Codable, Sendable, Equatable {
        var positionSeconds: Double
        /// 已知总时长;未知为 nil
        var durationSeconds: Double?
        var updatedAt: Date
    }

    /// 视为「已看完」的比例:超过它就不再续播,从头开始。
    /// 与 Emby 那边的语义对齐(服务端自己按比例判已看),
    /// 这里的阈值只影响本地续播,不影响任何上报。
    static let finishedThreshold: Double = 0.95

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "baidu")

    private let fileURL: URL
    private var loaded: [String: Entry]?
    /// 读盘失败的原因(诊断用)。**不静默吞**:读到损坏的文件时把原因留下来,
    /// 由调用方决定要不要提示;⛔ 不假装「没有记录」然后继续。
    private(set) var lastLoadFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 生产路径:与凭据文件同在应用支持目录下。
    ///
    /// ⚠️ 测试宿主用**另一个文件名**:单元测试跑在宿主 App 进程里、共享真实
    /// 沙盒容器(与 `NetworkDiagnostics.append` 的处置同一个理由),写同一个文件
    /// 会把真实记录冲掉。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let filename = isTestHost ? "watch-progress-testhost.json" : "watch-progress.json"
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
    }

    // MARK: - 读

    /// 该从哪一秒接着看。
    ///
    /// - Returns: 需要续播的位置(已扣掉「已看完」这一档);`nil` = 没有记录
    ///   或已看完,调用方从 0 开始。
    ///   ⚠️ 不在这里做 `Metrics.resumeRewind` 的回退 —— 那是播放层的规则
    ///   (`PlaybackRules.resumePosition`),与 Emby 源走同一个函数。
    func resumeSeconds(forFileID id: String) -> Double? {
        guard let entry = entries()[id], entry.positionSeconds > 0 else { return nil }
        if let duration = entry.durationSeconds, duration > 0,
           entry.positionSeconds / duration >= Self.finishedThreshold {
            return nil
        }
        return entry.positionSeconds
    }

    /// 全部记录(诊断 / 测试观察用)
    func snapshot() -> [String: Entry] { entries() }

    // MARK: - 写

    /// 记一条进度。位置为 0 或负值时**删掉**这条记录 ——
    /// 「从 0 开始看」不是一条进度,留着会让下次续播读到 0。
    func record(fileID id: String, positionSeconds: Double, durationSeconds: Double?) throws {
        guard positionSeconds > 0 else {
            try remove(fileID: id)
            return
        }
        var current = entries()
        current[id] = Entry(
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            updatedAt: Date()
        )
        try persist(current)
    }

    func remove(fileID id: String) throws {
        var current = entries()
        guard current.removeValue(forKey: id) != nil else { return }
        try persist(current)
    }

    // MARK: - 内部(actor 隔离内同步,不产生 await)

    private func entries() -> [String: Entry] {
        if let loaded { return loaded }
        let result = readFile()
        loaded = result
        return result
    }

    private func readFile() -> [String: Entry] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            lastLoadFailureDescription = "读取续播库失败:\(error)"
            Self.logger.error("续播库读取失败 \(String(describing: error), privacy: .public)")
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: Entry].self, from: data)
        } catch {
            // 文件坏了。⛔ 不就地重置成空文件 —— 先如实记下原因,
            // 让用户/我们有一次机会看到它(写操作会覆盖,所以放在写路径之前)。
            lastLoadFailureDescription = "续播库文件损坏:\(error)"
            Self.logger.error("续播库文件损坏 \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private func persist(_ entries: [String: Entry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw WatchProgressStoreError.writeFailed
        }
        // 0600:进度虽非凭据,但「谁看了什么」属于隐私,不该对同机其他用户可读
        guard FileManager.default.createFile(
            atPath: temporary.path(percentEncoded: false),
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw WatchProgressStoreError.writeFailed
        }
        guard rename(temporary.path(percentEncoded: false), fileURL.path(percentEncoded: false)) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw WatchProgressStoreError.writeFailed
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = fileURL
        try target.setResourceValues(values)
        loaded = entries
    }
}

enum WatchProgressStoreError: Error, Equatable {
    case writeFailed
}
