import CryptoKit
import Foundation

/// 本地文件夹 ↔ 文件树条目的映射(读盘,但不碰书签 / 访问权 —— 那是 `LocalFolderAccess` 的事)。
///
/// ## 路径:App 内的「虚拟路径」
///
/// 条目路径一律是 `/{rootName}/相对路径`(`LocalFolderSource.rootPath`),不是绝对路径。
/// 理由见 `LocalFolderSource.rootName`:续播 / 隐藏 / 集数这些本地记录按路径圈定,
/// 绝对路径会随挂载点变。浏览页与百度共用的路径工具(`BaiduPanPath`)只要求「`/` 开头的
/// 一棵树」,这个形状正好满足。
///
/// ## `fsID`:来源内稳定 id
///
/// 文件树条目用 `BaiduPanFile` 装(浏览页与百度共用,见 `FileSourceDirectoryContent`),
/// 它要一个 `UInt64` 的稳定 id —— 续播库、刮削缓存、隐藏库都按它记。
///
/// 取「来源 id + 虚拟路径」的 SHA-256 前 8 字节:
/// - ⛔ 不用 inode(`fileIdentifierKey`):exFAT / FAT 盘没有真 inode,系统现编的号
///   **重新挂载就变**,外接盘恰恰是放片子最常见的地方;
/// - 来源 id 进哈希:两个来源里同名同路径的文件(都有 `/电影/a.mkv`)不能撞成一条进度
///   (续播库按 id 全局存,见 `WatchProgressStore`);
/// - 代价:文件**改名 / 挪目录**后 id 变,那一条的进度与刮削缓存跟不过去。
///   本来源只读、改名发生在 App 外,这是能接受的边界(记在 `KNOWN_ISSUES.md`)。
enum LocalFolderListing {

    /// 列一层目录。隐藏文件(`.` 开头、系统标了隐藏的)不列 —— `.DS_Store` 这类不是片子。
    ///
    /// - Parameters:
    ///   - directory: 虚拟路径(`/{rootName}/…`)
    ///   - root: 来源根目录的真实 URL(访问权已打开)
    static func files(
        inDirectory directory: String,
        root: URL,
        source: LocalFolderSource,
        fileManager: FileManager = .default
    ) throws -> [BaiduPanFile] {
        let url = try fileURL(forPath: directory, root: root, rootPath: source.rootPath)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            throw LocalFolderError.directoryUnreadable(
                path: url.path, reason: error.localizedDescription)
        }
        return children.compactMap { child -> BaiduPanFile? in
            // 单个条目读不出属性(权限 / 刚被删):这一条不列,⛔ 不让整层读失败 ——
            // 但也不编一个假条目
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { return nil }
            let name = child.lastPathComponent
            let path = directory + "/" + name
            // 包(`.app` / `.photoslibrary`)在 Finder 里是一个文件:当文件看,合成器不认就不成卡
            let isDirectory = values.isDirectory == true && values.isPackage != true
            return BaiduPanFile(
                fsID: fileID(sourceID: source.id, path: path),
                path: path,
                name: name,
                sizeBytes: isDirectory ? nil : values.fileSize.map { UInt64(max(0, $0)) },
                isDirectory: isDirectory,
                // 百度的 `category` 是服务端分类;本地没有这一说,归类走扩展名(`BaiduPanFile.kind`)
                category: nil,
                modifiedAt: values.contentModificationDate,
                thumbnailURL: nil
            )
        }
    }

    /// 虚拟路径 → 真实 URL。
    ///
    /// ⛔ 不接受越出根的路径:必须是 `rootPath` 本身或落在它下面,且任何一段都不能是
    /// `.` / `..`(否则 `/{root}/../别处` 会读到书签范围之外 —— 沙盒会拒,但错误会
    /// 变成一句莫名其妙的「没有权限」)。
    static func fileURL(forPath path: String, root: URL, rootPath: String) throws -> URL {
        guard BaiduPanPath.isInside(path, applicationRoot: rootPath) else {
            throw LocalFolderError.outsideRoot(path: path)
        }
        let relative = path.dropFirst(rootPath.count)
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw LocalFolderError.outsideRoot(path: path)
        }
        return components.reduce(root) { url, component in
            url.appending(path: String(component), directoryHint: .inferFromPath)
        }
    }

    /// 来源内稳定 id(理由见类型注释)。
    static func fileID(sourceID: UUID, path: String) -> UInt64 {
        let digest = SHA256.hash(data: Data("\(sourceID.uuidString)|\(path)".utf8))
        return digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
