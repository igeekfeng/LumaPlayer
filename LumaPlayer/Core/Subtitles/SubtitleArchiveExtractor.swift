import Foundation
import os

/// 从字幕压缩包(rar / zip / 7z …)里取出**文本字幕**。
///
/// ## 为什么要自己解压
///
/// assrt 详情里有两种地址:`filelist` 的单文件直链(`/onthefly/…`,服务端临时解压)
/// 和整包地址(`/download/…`)。单文件那条会坏 —— 2026-10-21 实测一条
/// `[CHS&CHT]` 命名的字幕稳定 302 到 `assrt.net/download/error/…`(HTTP 493,
/// 页面文案「服务器抽风啦」),同一次详情里的整包却能正常下下来(RAR)。
/// 所以整包是兜底(`SubtitleService.download`)。
///
/// ## 为什么用 `/usr/bin/bsdtar`
///
/// 系统自带(libarchive 3.7.4,读得了 rar / rar5 / zip / 7z),SDK 里却没有 libarchive
/// 的头文件;为几十 KB 的字幕包再编一个解压库不值得。沙箱里起的子进程继承 App 的沙箱,
/// 只能读写容器 —— 正好就是工作目录所在的地方。
///
/// ## 安全
///
/// - bsdtar 默认拒绝带 `..` 的条目、去掉开头的 `/`(本机实测),不会写出工作目录;
/// - 只解压 `SubtitleFormats.downloadableOrder` 里的扩展名(`--include`),
///   视频、可执行文件之类不落盘;解出来的符号链接跳过,只认普通文件;
/// - 单个文件超过 `SubtitleFileStore.maximumBytes` 不读进内存(记日志后跳过)。
///
/// ⚠️ bsdtar 在「一个都没匹配上」或「有条目被拒」时退出码都是 1,⛔ 不能只凭退出码判成败:
/// 先列目录(`-t`)确认包读得开、里面有没有文本字幕,再解压。
enum SubtitleArchiveExtractor {

    /// 包里的一个文本字幕。
    struct Entry: Sendable, Equatable {
        /// 文件名(不含包内目录)
        let fileName: String
        let data: Data
    }

    enum ExtractError: LocalizedError, Equatable {
        /// 起不了解压进程
        case launchFailed(String)
        /// 包读不开(格式不认、损坏、加密)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let reason):
                return "无法解压字幕包:\(reason)"
            case .unreadable(let reason):
                return "字幕包读不开(可能损坏或加密)" + (reason.isEmpty ? "" : ":\(reason)")
            }
        }
    }

    static let bsdtarURL = URL(filePath: "/usr/bin/bsdtar")

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "subtitles")

    /// 解出包里全部文本字幕,按包内路径排序(结果稳定,挑选可复现)。
    /// 包读得开但里面没有文本字幕时返回空数组,由调用方决定怎么报。
    static func textSubtitles(in archive: Data) async throws -> [Entry] {
        let work = FileManager.default.temporaryDirectory
            .appending(path: "subtitle-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        let output = work.appending(path: "out", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // 扩展名无所谓:bsdtar 按内容认格式
            try archive.write(to: work.appending(path: "archive"))
        } catch {
            throw ExtractError.launchFailed(error.localizedDescription)
        }
        let archivePath = work.appending(path: "archive").path

        let listing = try await run(["-t", "-f", archivePath], in: work)
        guard listing.status == 0 else {
            throw ExtractError.unreadable(listing.firstErrorLine)
        }
        let hasText = listing.stdout.split(separator: "\n").contains {
            SubtitleFormats.downloadableOrder.contains(
                (String($0) as NSString).pathExtension.lowercased())
        }
        guard hasText else { return [] }

        let extraction = try await run(
            ["-x", "-f", archivePath, "-C", output.path] + includePatterns, in: work)
        if extraction.status != 0 {
            // 部分条目被拒(如带 `..`)也会是非 0:先看解出来的,真一个没有再算失败
            logger.error("字幕包解压有报错:\(extraction.firstErrorLine, privacy: .public)")
        }
        let entries = try collect(in: output)
        if entries.isEmpty, extraction.status != 0 {
            throw ExtractError.unreadable(extraction.firstErrorLine)
        }
        return entries
    }

    /// `*.[sS][rR][tT]` 这类大小写无关的模式;bsdtar 的 `*` 会跨目录匹配(本机实测)。
    private static var includePatterns: [String] {
        SubtitleFormats.downloadableOrder.flatMap { ext -> [String] in
            let pattern = ext.map { "[\($0.lowercased())\($0.uppercased())]" }.joined()
            return ["--include", "*.\(pattern)"]
        }
    }

    private static func collect(in directory: URL) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys) else { return [] }
        var found: [(path: String, entry: Entry)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  SubtitleFormats.downloadableOrder.contains(url.pathExtension.lowercased())
            else { continue }
            if let size = values.fileSize, size > SubtitleFileStore.maximumBytes {
                logger.error("字幕包里的文件过大,跳过:\(url.lastPathComponent, privacy: .public)(\(size) 字节)")
                continue
            }
            let data = try Data(contentsOf: url)
            found.append((url.path, Entry(fileName: url.lastPathComponent, data: data)))
        }
        return found.sorted { $0.path < $1.path }.map(\.entry)
    }

    // MARK: - 子进程

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String

        var firstErrorLine: String {
            stderr.split(separator: "\n").first.map(String.init) ?? ""
        }
    }

    /// 跑一次 bsdtar。输出写到工作目录下的文件而不是管道 —— 管道满了(包里文件很多时
    /// 列目录输出超过 64 KB)子进程会阻塞,等终止的这边就永远等不到。
    private static func run(_ arguments: [String], in work: URL) async throws -> RunResult {
        let stdoutURL = work.appending(path: "stdout-\(UUID().uuidString)")
        let stderrURL = work.appending(path: "stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let status: Int32
        do {
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }
            let process = Process()
            process.executableURL = bsdtarURL
            process.arguments = arguments
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            // 包内文件名按 UTF-8 输出与落盘;默认的 C locale 会把中文名换成 `?`
            process.environment = ["LC_ALL": "en_US.UTF-8"]
            status = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            throw ExtractError.launchFailed(error.localizedDescription)
        }

        // 读不到输出就抛:列目录的输出被当成空串,会把「读失败」误报成「包里没有字幕」
        do {
            return RunResult(
                status: status,
                stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
                stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self))
        } catch {
            throw ExtractError.launchFailed(error.localizedDescription)
        }
    }
}
