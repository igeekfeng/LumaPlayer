import CryptoKit
import Foundation

/// 海报图片的磁盘缓存(actor:文件 IO 不进 MainActor,
/// ARCHITECTURE.md 3.1.2 的 Core 分层)。
///
/// 只有内存缓存时重启即失、超限全清 —— 切回服务器图片全部重拉。
/// 加这一层后,重启 App 与来回切服务器都能秒出已看过的海报。
///
/// 两条硬规则(API_CONTRACT.md 3.3):
/// 1. **没有 `Tag` 的图片不进磁盘缓存**。Tag 是图片内容的版本标识,
///    key 不含 Tag 就可能把旧图当新图端出来;
/// 2. 缓存 key 从 hostname 之后开始取 → 这里沿用 `ImageSpec.cacheKey`
///    (含 serverID + itemID + type + tag + maxWidth,不含 scheme/host),
///    同一台服务器内外网切换时复用同一份文件。
///
/// 文件不设 TTL:图片内容变 = 服务端换 Tag = key 变,旧文件只靠容量淘汰。
/// 缓存是尽力而为:磁盘 IO 失败静默降级为无缓存,不影响正确性。
actor PosterDiskCache {
    /// 磁盘字节上限,超出按最旧写入时间全局淘汰。
    static let byteLimit = 256 * 1024 * 1024

    /// 超限淘汰时回收到的水位(上限的 80%)。只回收到刚好不超限的话,
    /// 之后每次写入都会再超限、每次都全量扫描目录。
    static let evictionTarget = byteLimit / 5 * 4

    /// 磁盘根目录(`.../Images`)。目录**首次写入时才创建**,测试注入临时目录。
    private let directory: URL
    /// 已用字节数;首次写盘时扫描一次,之后增量维护。
    private var totalBytes: Int?

    init(directory: URL? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "LumaPlayer"
        self.directory = directory ?? caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Images", isDirectory: true)
    }

    /// 读缓存。无 Tag(不进磁盘缓存,3.3)、未命中、损坏一律返回 nil。
    func data(for spec: ImageSpec) -> Data? {
        guard spec.tag != nil else { return nil }
        let fileURL = Self.fileURL(directory: directory, serverID: spec.serverID, cacheKey: spec.cacheKey)
        return try? Data(contentsOf: fileURL)
    }

    /// 写缓存。无 Tag 直接拒存(3.3:没有 Tag 的图片不进磁盘缓存)。
    func store(_ data: Data, for spec: ImageSpec) {
        guard spec.tag != nil else { return }
        let serverDir = directory.appendingPathComponent(spec.serverID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
            let fileURL = Self.fileURL(directory: directory, serverID: spec.serverID, cacheKey: spec.cacheKey)
            // 同 key 重写(内存淘汰后重新走网络):旧文件的字节必须从簿记里扣掉
            let oldSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: fileURL)
            try data.write(to: fileURL, options: .atomic)
            trackBytes(data.count - oldSize)
            evictIfOverLimit()
        } catch {
            // 写不进去(盘满 / 权限):降级为无磁盘缓存,不影响正确性(见类注释)
        }
    }

    /// 删除这台服务器的全部图片(删服务器时调用)。内存层由 LRU 自行淘汰,不必清。
    func purge(serverID: UUID) {
        let serverDir = directory.appendingPathComponent(serverID.uuidString, isDirectory: true)
        var removed = 0
        if let files = try? FileManager.default.contentsOfDirectory(
            at: serverDir, includingPropertiesForKeys: [.fileSizeKey]
        ) {
            for file in files {
                removed += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        try? FileManager.default.removeItem(at: serverDir)
        trackBytes(-removed)
    }

    // MARK: - 内部

    private func evictIfOverLimit() {
        guard (totalBytes ?? 0) > Self.byteLimit else { return }
        guard let servers = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        var candidates: [(url: URL, modified: Date, size: Int)] = []
        for serverDir in servers {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: serverDir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files {
                guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil,
                      let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                          .contentModificationDate) ?? nil else { continue }
                candidates.append((file, modified, size))
            }
        }
        let oversize = (totalBytes ?? 0) - Self.evictionTarget
        var reclaimed = 0
        for file in candidates.sorted(by: { $0.modified < $1.modified }) {
            guard reclaimed < oversize else { break }
            try? FileManager.default.removeItem(at: file.url)
            reclaimed += file.size
        }
        totalBytes = max(0, (totalBytes ?? 0) - reclaimed)
    }

    /// 维护字节簿记。**先完成文件系统变更,再调这里**;
    /// 首次调用只扫描(扫描结果已含刚完成的变更),不叠加 delta —— 否则双计。
    private func trackBytes(_ delta: Int) {
        if totalBytes == nil {
            totalBytes = scanBytes()
            return
        }
        totalBytes = max(0, (totalBytes ?? 0) + delta)
    }

    private func scanBytes() -> Int {
        guard let servers = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return 0 }
        var total = 0
        for serverDir in servers {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: serverDir, includingPropertiesForKeys: [.fileSizeKey]
            ) else { continue }
            for file in files {
                total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return total
    }

    /// 文件名 = sha256(cacheKey)。cacheKey 已含 serverID 等,hash 后仍互不碰撞。
    private static func fileURL(directory: URL, serverID: UUID, cacheKey: String) -> URL {
        let name = SHA256.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory
            .appendingPathComponent(serverID.uuidString, isDirectory: true)
            .appendingPathComponent(name + ".img")
    }
}
