import Foundation
import os

/// 本地「这一层目录里有几集」的库:`来源 + 目录路径` → 集数。
///
/// ## 为什么需要它
///
/// Emby 的剧卡上有「还有 N 集未看」,而百度侧要算这个数必须**知道总集数** ——
/// 季文件夹存法下那是一季一次列目录(2 次请求 / 层,配额见
/// `docs/BAIDU_PAN_API.md` §7)。网格上不能这么花,所以改成:**进过一次详情页**
/// 就把那一季 / 那一部剧的集数记在本地,之后网格上零请求地显示「已看 3 / 共 12 集」。
///
/// ## 存的是什么、不是什么
///
/// 只存**数**,不存文件名。所以它是**展示用的近似值**:
/// 网盘里增删了集之后这个数会偏,直到下次进详情页重算并覆盖。
/// ⛔ 它不参与播放、换集队列、续播的任何判断 —— 那些一律以当次列目录的结果为准。
///
/// ⚠️ 与 `BaiduPanDirectoryCache` 分开:那个是「目录里有什么」的**事实**副本
/// (24 小时过期,变了就该重取),这个是「这部剧一共几集」的**统计**,只在
/// 进详情页时更新。混在一起会让「刷新目录」把集数也一起抹掉。
///
/// 落点、权限、备份排除与 `HiddenItemsStore` 同一套(0600 / 不进备份 / 测试宿主另用文件名)。
actor BaiduPanEpisodeCountStore {

    private static let logger = Logger(
        subsystem: NetworkDiagnostics.subsystem, category: "baidu-episode-counts")

    private let fileURL: URL
    private var loaded: [String: Int]?
    /// 读盘失败的原因(诊断用)。**不静默吞**:文件损坏时留下原因,
    /// 但浏览照常 —— 少几个「共 N 集」不该让片库打不开。
    private(set) var lastLoadFailureDescription: String?
    private(set) var lastWriteFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 生产路径:与凭据文件、续播库同在应用支持目录下。
    /// ⚠️ 测试宿主用另一个文件名,避免单测把真实记录冲掉(与 `HiddenItemsStore` 同一纪律)。
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

    /// 某个来源下**全部**目录的集数(路径 → 集数)。
    ///
    /// 一次读全量而不是逐条问:调用方要在计算属性里同步查(网格每张卡都要问一次),
    /// 每次 await 一遍库既没必要也让视图层写不顺。
    func counts(sourceID: UUID) -> [String: Int] {
        let prefix = "\(sourceID.uuidString)|"
        var result: [String: Int] = [:]
        for (key, value) in entries() where key.hasPrefix(prefix) {
            result[String(key.dropFirst(prefix.count))] = value
        }
        return result
    }

    // MARK: - 写

    /// 记下「这个目录里有 N 集」。`count <= 0` 等于抹掉这一条(目录空了 / 只剩封面图)。
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

    /// 删除来源时整片清掉(目录名就是片名,留着没有用处只有隐私风险)。
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
            // ⛔ 不就地重置成空文件:先如实记下原因,下次写盘时自然覆盖
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
            // 0600:目录名就是用户在网盘里的片名(与隐藏列表同一处置)
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
