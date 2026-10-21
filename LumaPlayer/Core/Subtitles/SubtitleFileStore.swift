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
actor SubtitleFileStore {

    struct Stored: Sendable, Equatable {
        /// 容器内的字幕文件(可直接交给 `MPVPlayer.addSubtitle`)
        let url: URL
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
        let extensionName = (fileName as NSString).pathExtension.lowercased()
        return try store(
            data: data,
            fileName: fileName,
            destinationName: "\(UUID().uuidString).\(extensionName)")
    }

    /// 落一份**下载来的**字幕(在线搜索那一路)。
    ///
    /// `cacheName` 由调用方给且要稳定:同一个 id 的同一份文件用同一个名字,
    /// 再点一次就能命中 `existingFile(named:)`,不重复消耗站点的下载配额。
    func storeDownloaded(data: Data, fileName: String, cacheName: String) throws -> Stored {
        guard SubtitleFormats.isSubtitle(fileName: fileName) else {
            throw ImportError.notSubtitle(fileName)
        }
        return try store(data: data, fileName: fileName, destinationName: cacheName)
    }

    /// 已经落过盘的同一份字幕(缓存命中就不用再下载)。没有则 nil。
    func existingFile(named name: String) -> Stored? {
        guard SubtitleFormats.isSubtitle(fileName: name) else { return nil }
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Stored(
            url: url,
            title: SubtitleFormats.displayName(forFileName: name),
            // 文件是上次写入时的结果:这次没有做编码判断,如实给 nil
            encodingOutcome: nil)
    }

    /// 校验 + 转码 + 写入。两条通路(本地导入 / 在线下载)共用。
    private func store(data: Data, fileName: String, destinationName: String) throws -> Stored {
        guard !data.isEmpty else { throw ImportError.empty }
        guard data.count <= Self.maximumBytes else { throw ImportError.tooLarge(data.count) }

        let normalized = SubtitleTextDecoder.normalize(data)
        let destination = directory.appending(path: destinationName, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
            title: SubtitleFormats.displayName(forFileName: fileName),
            encodingOutcome: normalized.outcome)
    }
}
