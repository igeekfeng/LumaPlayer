import CryptoKit
import Foundation
import os

/// 外挂字幕文件的**落盘管理**(手动加载那一路)。
///
/// ## 为什么要复制进容器
///
/// App 开了沙箱(`LumaPlayer.entitlements`),用户在 `fileImporter` 里选中的文件只有
/// 一次性的 security-scoped 权限。字幕是几十 KB 的文本,与其长期持 bookmark
/// (重启 / 换窗口后容易失效,还要在每次 `sub-add` 前配一对 start/stop),
/// 不如**当场复制进 `Caches/`**:播放器只读容器内路径,零权限问题。
///
/// 放 `Caches/` 而不是 `Application Support`:字幕可以从源头再取一次,
/// 系统清掉只影响「这一条要不要重新选」,不影响任何用户数据。
///
/// ## 编码在落盘前统一
///
/// 见 `SubtitleTextDecoder`:中文字幕大量是 GBK / BIG5,转成 UTF-8 之后再交给 mpv。
/// 认不出编码时**原样保留**(mpv 编了 uchardet 可以兜底),⛔ 不因此拒绝加载。
///
/// ## 目录布局:`<组>/<原文件名>`
///
/// - 在线:`assrt-<字幕 id>/`(`SubtitleService.cacheGroup`)。先按组查缓存,命中就**不请求 assrt**。
/// - 本地:`local-<内容 SHA-256 前 16 位>/`。同一个文件导入几次只存一份。
///
/// 保留原文件名是为了菜单里能看出 `zh-Hans` / `zh-Hant` 这类区别 —— 文件名就是标题,不另存一份。
/// 2026-10-21 之前是平铺的 `assrt-<id>-<序号>.<ext>` / `<UUID>.<ext>`,⛔ 不迁移,交给 `cleanUp` 按时间淘汰。
///
/// ## 清理(`cleanUp`)
///
/// 以**组**为单位:组的「最近使用」= 组内文件最新的修改时间,每次挂载都会 `markUsed` 刷新。
/// 被记住的字幕(`SubtitleBindingStore`)所在的组不删;其余超过 `retention` 没用过的删掉,
/// 删完仍超过 `byteLimit` 再按最久未用继续删。
actor SubtitleFileStore {

    struct Stored: Sendable, Equatable {
        /// 容器内的字幕文件(可直接交给 `MPVPlayer.addSubtitle`)
        let url: URL
        /// 相对缓存目录的路径(`<组>/<原文件名>`):记住「这一集用了哪条」时存它,不存绝对路径
        let relativePath: String
        /// 菜单里显示的名字(原文件名去扩展名)
        let title: String
        /// 编码处理结论。`nil` = 这次没有做编码判断(命中缓存 —— 文件是上次写入时的结果)
        let encodingOutcome: SubtitleTextDecoder.Outcome?
    }

    enum ImportError: LocalizedError, Equatable {
        /// 扩展名不是认得的字幕格式
        case notSubtitle(String)
        case empty
        /// 超过大小上限(字节)
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

    /// 字幕文件的大小上限。
    ///
    /// 纯文本字幕极少超过几百 KB(最长的 ASS 特效字幕也就几 MB)。设上限是为了挡住
    /// 「把视频当字幕选中」这类误操作 —— 那个文件会被整份读进内存再交给 mpv。
    static let maximumBytes = 8 * 1024 * 1024

    /// 多久没用过的字幕会被清理(也是 `SubtitleBindingStore` 记录的保留期,两边用同一个值)。
    static let retention: TimeInterval = 90 * 24 * 60 * 60

    /// 缓存总量上限。字幕一般几十 KB,正常用不到;这条只防「一直不过期却越攒越多」。
    static let byteLimit = 50 * 1024 * 1024

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "subtitles")

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// `Caches/LumaPlayer/subtitles`。测试宿主用另一个子目录,免得和真实缓存互相污染
    /// (理由同 `DanmakuCommentCache.defaultDirectory`)。
    static var defaultDirectory: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "LumaPlayer", directoryHint: .isDirectory)
            .appending(path: isTestHost ? "subtitles-testhost" : "subtitles", directoryHint: .isDirectory)
    }

    /// 把用户选中的字幕复制进容器并转成 UTF-8。
    ///
    /// 失败一律抛错(由播放页如实提示),⛔ 不静默返回一个不可用的路径。
    func importLocalFile(at url: URL) throws -> Stored {
        let fileName = url.lastPathComponent
        guard SubtitleFormats.isSubtitle(fileName: fileName) else {
            throw ImportError.notSubtitle(fileName)
        }

        // 沙箱:选择器给的 URL 要显式取一次权限。
        // ⚠️ 返回 false 不代表读不了(容器内文件本来就有权限),所以不据此报错,
        // 只按返回值决定要不要配对释放 —— 这是该 API 的唯一正确用法。
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

    /// 落一份**下载来的**字幕(在线搜索那一路)。
    ///
    /// `group` 由调用方给且要稳定(`SubtitleService.cacheGroup`):同一条字幕落进同一个组,
    /// 再点一次就能命中 `cachedFile(group:)`,不重复消耗站点的配额。
    func storeDownloaded(data: Data, fileName: String, group: String) throws -> Stored {
        guard SubtitleFormats.isSubtitle(fileName: fileName) else {
            throw ImportError.notSubtitle(fileName)
        }
        return try store(data: data, fileName: fileName, group: group)
    }

    /// 这个组里已经落过盘的字幕(缓存命中就不用再请求)。组里有多个时按格式优先级挑。没有则 nil。
    func cachedFile(group: String) throws -> Stored? {
        let groupURL = directory.appending(path: group, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: groupURL.path) else { return nil }
        let names = try FileManager.default.contentsOfDirectory(atPath: groupURL.path)
        let best = names.filter(SubtitleFormats.isSubtitle(fileName:)).sorted().min {
            Self.rank($0) < Self.rank($1)
        }
        return best.flatMap { existingFile(relativePath: "\(group)/\($0)") }
    }

    /// 已经落过盘的某个文件(按 `Stored.relativePath` 找)。没有则 nil。
    func existingFile(relativePath: String) -> Stored? {
        let components = relativePath.split(separator: "/").map(String.init)
        // 只认 `<组>/<文件名>` 两段,⛔ 不让记录里的路径跳出缓存目录
        guard components.count == 2, !components.contains(where: { $0 == "." || $0 == ".." }),
              SubtitleFormats.isSubtitle(fileName: components[1]) else { return nil }
        let url = directory.appending(path: components[0], directoryHint: .isDirectory)
            .appending(path: components[1], directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Stored(
            url: url,
            relativePath: relativePath,
            title: SubtitleFormats.displayName(forFileName: components[1]),
            // 文件是上次写入时的结果:这次没有做编码判断,如实给 nil
            encodingOutcome: nil)
    }

    /// 记一次使用(刷新修改时间),清理按它判断「多久没用」。
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

    /// 删掉过期或超量的缓存组(规则见类型注释)。
    ///
    /// - Parameter keeping: 要保留的组(被记住的字幕所在的组),不管多旧都不删。
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
            // 旧版平铺的单个文件也当一个组(它自己)
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

    /// 校验 + 转码 + 写入。两条通路(本地导入 / 在线下载)共用。
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
            // 不拦:mpv 的 uchardet 还能试一次。但留下原因,排查乱码时不用猜。
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

    /// 文件名来自字幕站 JSON / 压缩包 / 用户磁盘,不可信:只取最后一段、去掉路径分隔符,
    /// 过长的截断基名(APFS 单段上限 255 字节),保留扩展名。
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

    /// 格式优先级(`downloadableOrder` 在前,其余认得的格式垫后)
    private static func rank(_ fileName: String) -> Int {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return SubtitleFormats.preferredOrder.firstIndex(of: ext) ?? SubtitleFormats.preferredOrder.count
    }
}
