import Foundation
import os

/// 本地「这一层目录里有几集」的库:`来源 + 目录路径` → 集数。进过一次详情页就记下,
/// 网格上零请求地显示「已看 3 / 共 12 集」(逐层列目录太费配额,`docs/BAIDU_PAN_API.md` §7)。
///
/// 只存数,是展示用的近似值,下次进详情页才覆盖。⛔ 不参与播放、换集队列、续播的判断。
/// 与 `BaiduPanDirectoryCache` 分开,免得刷新目录把集数一起抹掉。
///
/// 落盘方式同 `HiddenItemsStore`(0600 / 不进备份 / 测试宿主另用文件名)。
actor BaiduPanEpisodeCountStore {

    private static let logger = Logger(
        subsystem: NetworkDiagnostics.subsystem, category: "baidu-episode-counts")

    private let fileURL: URL
    private var loaded: [String: Int]?
    /// 读盘失败的原因(诊断用),浏览照常。
    private(set) var lastLoadFailureDescription: String?
    private(set) var lastWriteFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let filename = isTestHost
            ? "baidu-episode-counts-testhost.json"
            : "baidu-episode-counts.json"
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
    }

    // MARK: - 读

    /// 某个来源下全部目录的集数(路径 → 集数)。一次读全量,调用方在计算属性里同步查。
    func counts(sourceID: UUID) -> [String: Int] {
        let prefix = "\(sourceID.uuidString)|"
        var result: [String: Int] = [:]
        for (key, value) in entries() where key.hasPrefix(prefix) {
            result[String(key.dropFirst(prefix.count))] = value
        }
        return result
    }

    // MARK: - 写

    /// `count <= 0` 等于抹掉这一条。
    func store(sourceID: UUID, directory: String, count: Int) {
        guard !directory.isEmpty else { return }
        var current = entries()
        let key = Self.key(sourceID: sourceID, directory: directory)
        if count > 0 {
            guard current[key] != count else { return }
            current[key] = count
        } else {
            guard current.removeValue(forKey: key) != nil else { return }
        }
        persist(current)
    }

    func purge(sourceID: UUID) {
        var current = entries()
        let prefix = "\(sourceID.uuidString)|"
        let stale = current.keys.filter { $0.hasPrefix(prefix) }
        guard !stale.isEmpty else { return }
        for key in stale { current.removeValue(forKey: key) }
        persist(current)
    }

    // MARK: - 内部

    private static func key(sourceID: UUID, directory: String) -> String {
        "\(sourceID.uuidString)|\(directory)"
    }

    private func entries() -> [String: Int] {
        if let loaded { return loaded }
        let result = readFile()
        loaded = result
        return result
    }

    private func readFile() -> [String: Int] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            lastLoadFailureDescription = "读取集数记录失败:\(error)"
            Self.logger.error("集数记录读取失败 \(String(describing: error), privacy: .public)")
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: Int].self, from: data)
        } catch {
            // ⛔ 不就地重置成空文件:记下原因,下次写盘自然覆盖
            lastLoadFailureDescription = "集数记录文件损坏:\(error)"
            Self.logger.error("集数记录文件损坏 \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private func persist(_ entries: [String: Int]) {
        do {
            let data = try JSONEncoder().encode(entries)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).tmp")
            // 0600:目录名是用户的片名,属隐私
            guard FileManager.default.createFile(
                atPath: temporary.path(percentEncoded: false),
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                lastWriteFailureDescription = "集数记录写入失败(创建临时文件)"
                return
            }
            guard rename(
                temporary.path(percentEncoded: false),
                fileURL.path(percentEncoded: false)) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                lastWriteFailureDescription = "集数记录写入失败(替换文件)"
                return
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = fileURL
            try? target.setResourceValues(values)
            loaded = entries
            lastWriteFailureDescription = nil
        } catch {
            lastWriteFailureDescription = "集数记录写入失败:\(error)"
            Self.logger.error("集数记录写入失败 \(String(describing: error), privacy: .public)")
        }
    }
}
