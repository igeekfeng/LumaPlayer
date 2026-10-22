import CryptoKit
import Foundation

/// 海报图片的磁盘缓存,按 `ownerID` 分目录。
///
/// 规则(API_CONTRACT.md 3.3):没有版本标识的图不进磁盘缓存(`ImageDescriptor.isDiskCacheable`);
/// key 不含 scheme/host,同一台服务器内外网切换复用同一份文件。
/// 不设 TTL:内容变 = 版本变 = key 变,旧文件只靠容量淘汰。
/// 尽力而为:磁盘 IO 失败静默降级为无缓存,不影响正确性。
actor PosterDiskCache {
    static let defaultByteLimit = 256 * 1024 * 1024

    /// 设置页可选档位(MB);档位外的存量值按默认档。⛔ 不提供「不限」(见 `ImageCachePreferences`)。
    static let byteLimitOptionsMB = [128, 256, 512, 1024, 2048]

    /// 超出按最旧写入时间全局淘汰
    private(set) var byteLimit: Int

    /// 淘汰回收到上限的 80%,否则之后每次写入都再超限、全量扫目录。
    private var evictionTarget: Int { byteLimit / 5 * 4 }

    /// 首次写入时才创建
    private let directory: URL
    /// 已用字节簿记;nil = 还没扫描过
    private var totalBytes: Int?

    struct Usage: Sendable, Equatable {
        let bytes: Int
        let fileCount: Int

        static let zero = Usage(bytes: 0, fileCount: 0)
    }

    init(directory: URL? = nil, byteLimit: Int = PosterDiskCache.defaultByteLimit) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "LumaPlayer"
        self.directory = directory ?? caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Images", isDirectory: true)
        self.byteLimit = byteLimit
    }

    /// 无版本标识、未命中、损坏一律 nil。
    func data(for descriptor: ImageDescriptor) -> Data? {
        guard descriptor.isDiskCacheable else { return nil }
        let fileURL = Self.fileURL(
            directory: directory, ownerID: descriptor.ownerID, cacheKey: descriptor.cacheKey)
        return try? Data(contentsOf: fileURL)
    }

    /// 无版本标识直接拒存。
    func store(_ data: Data, for descriptor: ImageDescriptor) {
        guard descriptor.isDiskCacheable else { return }
        let ownerDir = directory.appendingPathComponent(
            descriptor.ownerID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: ownerDir, withIntermediateDirectories: true)
            let fileURL = Self.fileURL(
                directory: directory, ownerID: descriptor.ownerID, cacheKey: descriptor.cacheKey)
            // 同 key 重写时旧文件字节要从簿记里扣掉
            let oldSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: fileURL)
            try data.write(to: fileURL, options: .atomic)
            trackBytes(data.count - oldSize)
            evictIfOverLimit()
        } catch {
            // 盘满 / 权限:降级为无磁盘缓存
        }
    }

    func data(for spec: ImageSpec) -> Data? { data(for: .emby(spec)) }

    func store(_ data: Data, for spec: ImageSpec) { store(data, for: .emby(spec)) }

    /// 删来源时调用。内存层由 LRU 自行淘汰,不必清。
    func purge(ownerID: UUID) {
        let ownerDir = directory.appendingPathComponent(ownerID.uuidString, isDirectory: true)
        var removed = 0
        if let files = try? FileManager.default.contentsOfDirectory(
            at: ownerDir, includingPropertiesForKeys: [.fileSizeKey]
        ) {
            for file in files {
                removed += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        try? FileManager.default.removeItem(at: ownerDir)
        trackBytes(-removed)
    }

    // MARK: - 设置 → 缓存

    /// 调低时立刻淘汰,不等下次写盘。
    func setByteLimit(_ bytes: Int) {
        let limit = max(0, bytes)
        guard limit != byteLimit else { return }
        byteLimit = limit
        evictIfOverLimit()
    }

    /// 真实扫描并校准簿记(手删目录 / 系统清缓存后簿记会偏大)。
    /// ⛔ 全目录扫描,只给设置页这种一次性动作调,不要放进图片加载路径。
    func usage() -> Usage {
        let scanned = scanUsage()
        totalBytes = scanned.bytes
        return scanned
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        totalBytes = 0
    }

    // MARK: - 内部

    private func evictIfOverLimit() {
        // 改上限可能早于任何写入(簿记还是 nil)
        if totalBytes == nil { totalBytes = scanUsage().bytes }
        guard (totalBytes ?? 0) > byteLimit else { return }
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
        let oversize = (totalBytes ?? 0) - evictionTarget
        var reclaimed = 0
        for file in candidates.sorted(by: { $0.modified < $1.modified }) {
            guard reclaimed < oversize else { break }
            try? FileManager.default.removeItem(at: file.url)
            reclaimed += file.size
        }
        totalBytes = max(0, (totalBytes ?? 0) - reclaimed)
    }

    /// 须在文件系统变更完成后调。首次调用只扫描、不叠加 delta(扫描已含该变更,否则双计)。
    private func trackBytes(_ delta: Int) {
        if totalBytes == nil {
            totalBytes = scanUsage().bytes
            return
        }
        totalBytes = max(0, (totalBytes ?? 0) + delta)
    }

    private func scanUsage() -> Usage {
        guard let servers = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return .zero }
        var bytes = 0
        var count = 0
        for serverDir in servers {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: serverDir, includingPropertiesForKeys: [.fileSizeKey]
            ) else { continue }
            for file in files {
                bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                count += 1
            }
        }
        return Usage(bytes: bytes, fileCount: count)
    }

    /// 文件名 = sha256(cacheKey)
    private static func fileURL(directory: URL, ownerID: UUID, cacheKey: String) -> URL {
        let name = SHA256.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory
            .appendingPathComponent(ownerID.uuidString, isDirectory: true)
            .appendingPathComponent(name + ".img")
    }
}
