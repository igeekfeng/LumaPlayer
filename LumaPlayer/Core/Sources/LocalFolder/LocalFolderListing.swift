import CryptoKit
import Foundation

/// 本地文件夹 ↔ 文件树条目的映射(读盘,不碰书签 / 访问权)。
///
/// 条目路径是虚拟路径 `/{rootName}/相对路径`(`LocalFolderSource.rootPath`),不是绝对路径
/// (理由见 `LocalFolderSource.rootName`),正好满足 `BaiduPanPath` 要的「`/` 开头的一棵树」。
///
/// `fsID` = SHA-256(来源 id + 虚拟路径) 前 8 字节,续播库、刮削缓存、隐藏库都按它记:
/// - ⛔ 不用 inode:exFAT / FAT 盘重新挂载就变;
/// - 来源 id 进哈希:续播库按 id 全局存,两个来源的同路径文件不能撞;
/// - 代价:改名 / 挪目录后 id 变,进度与刮削缓存跟不过去(见 `KNOWN_ISSUES.md`)。
enum LocalFolderListing {

    /// 隐藏文件不列。
    ///
    /// - Parameters:
    ///   - directory: 虚拟路径
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
            // 单条读不出属性就不列,⛔ 不让整层失败,也不编假条目
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { return nil }
            let name = child.lastPathComponent
            let path = directory + "/" + name
            // 包(`.app` 等)当文件看
            let isDirectory = values.isDirectory == true && values.isPackage != true
            return BaiduPanFile(
                fsID: fileID(sourceID: source.id, path: path),
                path: path,
                name: name,
                sizeBytes: isDirectory ? nil : values.fileSize.map { UInt64(max(0, $0)) },
                isDirectory: isDirectory,
                // 本地归类走扩展名(`BaiduPanFile.kind`)
                category: nil,
                modifiedAt: values.contentModificationDate,
                thumbnailURL: nil
            )
        }
    }

    /// 虚拟路径 → 真实 URL。⛔ 不接受越出根的路径(任何一段都不能是 `.` / `..`),
    /// 否则沙盒拒绝时只会报一句含糊的「没有权限」。
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

    /// 见类型注释。
    static func fileID(sourceID: UUID, path: String) -> UInt64 {
        let digest = SHA256.hash(data: Data("\(sourceID.uuidString)|\(path)".utf8))
        return digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
