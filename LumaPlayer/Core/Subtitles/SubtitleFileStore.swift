import CryptoKit
import Foundation
import os

/// 外挂字幕的落盘管理(本地导入与在线下载共用)。
///
/// 选中的文件当场复制进 `Caches/`:沙箱下 `fileImporter` 只给一次性权限,长期持 bookmark 易失效。
/// 放 `Caches/` 是因为字幕可以从源头重取。落盘前转成 UTF-8(`SubtitleTextDecoder`)。
///
/// 目录布局 `<组>/<原文件名>`(文件名就是菜单标题,能看出 `zh-Hans` / `zh-Hant`):
/// - 在线:`assrt-<字幕 id>/`(`SubtitleService.cacheGroup`),命中就不请求 assrt;
/// - 本地:`local-<内容 SHA-256 前 16 位>/`,同一文件只存一份。
///
/// 清理(`cleanUp`)以组为单位,「最近使用」= 组内最新修改时间(`markUsed` 刷新)。
/// `SubtitleBindingStore` 记住的组不删;其余超过 `retention` 的删,仍超 `byteLimit` 再按最久未用删。
actor SubtitleFileStore {

    struct Stored: Sendable, Equatable {
        /// 可直接交给 `MPVPlayer.addSubtitle`
        let url: URL
        /// `<组>/<原文件名>`。持久化存它,不存绝对路径
        let relativePath: String
        /// 原文件名去扩展名
        let title: String
        /// `nil` = 命中缓存,这次没做编码判断
        let encodingOutcome: SubtitleTextDecoder.Outcome?
    }

    enum ImportError: LocalizedError, Equatable {
        case notSubtitle(String)
        case empty
        /// 字节
        case tooLarge(Int)
        case unreadable(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSubtitle(let name):
                return "「\(name)」不是认得的字幕格式(支持 .srt / .ass / .ssa / .vtt / .sub)"
            case .empty:
                return "这个文件是空的"
            case .tooLarge(let bytes):
                let limit = SubtitleFileStore.maximumBytes / (1024 * 1024)
                return "文件太大(\(bytes / (1024 * 1024)) MB),字幕不该有这么大,上限 \(limit) MB"
            case .unreadable(let reason):
                return "读不出这个文件:\(reason)"
            case .writeFailed(let reason):
                return "字幕保存失败:\(reason)"
            }
        }
    }

    /// 挡住「把视频当字幕选中」:文件会被整份读进内存。
    static let maximumBytes = 8 * 1024 * 1024

    /// 也是 `SubtitleBindingStore` 记录的保留期
    static let retention: TimeInterval = 90 * 24 * 60 * 60

    /// 总量上限,只防越攒越多
    static let byteLimit = 50 * 1024 * 1024

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "subtitles")

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// `Caches/LumaPlayer/subtitles`。测试宿主用另一个子目录(同 `DanmakuCommentCache.defaultDirectory`)。
    static var defaultDirectory: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "LumaPlayer", directoryHint: .isDirectory)
            .appending(path: isTestHost ? "subtitles-testhost" : "subtitles", directoryHint: .isDirectory)
    }

    /// 失败一律抛错,⛔ 不返回不可用的路径。
    func importLocalFile(at url: URL) throws -> Stored {
        let fileName = url.lastPathComponent
        guard SubtitleFormats.isSubtitle(fileName: fileName) else {
            throw ImportError.notSubtitle(fileName)
        }

        // ⚠️ 返回 false 不代表读不了(容器内文件本来就有权限),只用来决定要不要配对释放
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return try store(data: data, fileName: fileName, group: "local-\(digest)")
    }

    /// `group` 必须稳定(`SubtitleService.cacheGroup`),再取同一条才能命中缓存、不耗站点配额。
    func storeDownloaded(data: Data, fileName: String, group: String) throws -> Stored {
        guard SubtitleFormats.isSubtitle(fileName: fileName) else {
            throw ImportError.notSubtitle(fileName)
        }
        return try store(data: data, fileName: fileName, group: group)
    }

    /// 组里有多个时按格式优先级挑。
    func cachedFile(group: String) throws -> Stored? {
        let groupURL = directory.appending(path: group, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: groupURL.path) else { return nil }
        let names = try FileManager.default.contentsOfDirectory(atPath: groupURL.path)
        let best = names.filter(SubtitleFormats.isSubtitle(fileName:)).sorted().min {
            Self.rank($0) < Self.rank($1)
        }
        return best.flatMap { existingFile(relativePath: "\(group)/\($0)") }
    }

    func existingFile(relativePath: String) -> Stored? {
        let components = relativePath.split(separator: "/").map(String.init)
        // ⛔ 只认两段,不让记录里的路径跳出缓存目录
        guard components.count == 2, !components.contains(where: { $0 == "." || $0 == ".." }),
              SubtitleFormats.isSubtitle(fileName: components[1]) else { return nil }
        let url = directory.appending(path: components[0], directoryHint: .isDirectory)
            .appending(path: components[1], directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Stored(
            url: url,
            relativePath: relativePath,
            title: SubtitleFormats.displayName(forFileName: components[1]),
            encodingOutcome: nil)
    }

    /// 刷新修改时间,清理据此判断多久没用。
    func markUsed(relativePath: String) throws {
        guard let stored = existingFile(relativePath: relativePath) else { return }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: stored.url.path)
    }

    // MARK: - 清理

    struct CleanupReport: Sendable, Equatable {
        var removedGroups = 0
        var removedBytes = 0
        var remainingBytes = 0
    }

    /// 规则见类型注释。
    ///
    /// - Parameter keeping: 不管多旧都不删的组。
    func cleanUp(
        now: Date = Date(),
        retention: TimeInterval = SubtitleFileStore.retention,
        byteLimit: Int = SubtitleFileStore.byteLimit,
        keeping: Set<String>
    ) throws -> CleanupReport {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return CleanupReport() }
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]

        struct Group { let url: URL; let name: String; let lastUsed: Date; let bytes: Int }
        var groups: [Group] = []
        for url in try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            let values = try url.resourceValues(forKeys: Set(keys))
            // 顶层散落的单个文件(旧布局,⛔ 不迁移)也当一个组,按时间淘汰
            let files = values.isDirectory == true
                ? try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
                : [url]
            var lastUsed = values.contentModificationDate ?? .distantPast
            var bytes = 0
            for file in files {
                let fileValues = try file.resourceValues(forKeys: Set(keys))
                lastUsed = max(lastUsed, fileValues.contentModificationDate ?? .distantPast)
                bytes += fileValues.fileSize ?? 0
            }
            groups.append(Group(url: url, name: url.lastPathComponent, lastUsed: lastUsed, bytes: bytes))
        }

        var report = CleanupReport()
        var remaining: [Group] = []
        for group in groups {
            if !keeping.contains(group.name), now.timeIntervalSince(group.lastUsed) > retention {
                try manager.removeItem(at: group.url)
                report.removedGroups += 1
                report.removedBytes += group.bytes
            } else {
                remaining.append(group)
            }
        }
        var total = remaining.reduce(0) { $0 + $1.bytes }
        for group in remaining.sorted(by: { $0.lastUsed < $1.lastUsed })
        where total > byteLimit && !keeping.contains(group.name) {
            try manager.removeItem(at: group.url)
            report.removedGroups += 1
            report.removedBytes += group.bytes
            total -= group.bytes
        }
        report.remainingBytes = total
        return report
    }

    // MARK: - 内部

    private func store(data: Data, fileName: String, group: String) throws -> Stored {
        guard !data.isEmpty else { throw ImportError.empty }
        guard data.count <= Self.maximumBytes else { throw ImportError.tooLarge(data.count) }

        let safeName = Self.safeFileName(fileName)
        let normalized = SubtitleTextDecoder.normalize(data)
        let groupURL = directory.appending(path: group, directoryHint: .isDirectory)
        let destination = groupURL.appending(path: safeName, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
            try normalized.data.write(to: destination, options: .atomic)
        } catch {
            throw ImportError.writeFailed(error.localizedDescription)
        }

        switch normalized.outcome {
        case .converted(let encoding):
            Self.logger.info("外挂字幕已转 UTF-8(原编码 \(encoding, privacy: .public)):\(fileName, privacy: .public)")
        case .unrecognized:
            // 不拦,mpv 还能试一次;留日志方便排查乱码
            Self.logger.error("外挂字幕编码未识别,按原样加载:\(fileName, privacy: .public)")
        case .alreadyUTF8:
            break
        }

        return Stored(
            url: destination,
            relativePath: "\(group)/\(safeName)",
            title: SubtitleFormats.displayName(forFileName: safeName),
            encodingOutcome: normalized.outcome)
    }

    /// 文件名不可信:只取最后一段、去掉路径分隔符,过长截断基名(APFS 单段 255 字节),保留扩展名。
    static func safeFileName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let ext = (last as NSString).pathExtension
        var base = (last as NSString).deletingPathExtension
        if base.isEmpty || base == "." || base == ".." { base = "subtitle" }
        while base.utf8.count + ext.utf8.count + 1 > 240 { base.removeLast() }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private static func rank(_ fileName: String) -> Int {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return SubtitleFormats.preferredOrder.firstIndex(of: ext) ?? SubtitleFormats.preferredOrder.count
    }
}
