import CryptoKit
import Foundation

/// 海报图片的磁盘缓存(actor:文件 IO 不进 MainActor,
/// CLAUDE.md「并发分层」的 Core 分层)。
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
///
/// ## 上限可调、可查、可清空(设置 → 缓存)
///
/// 上限是**实例状态**而不是常量:设置页改档位时调 `setByteLimit(_:)`,
/// 调低后立刻按新上限淘汰,不等下一次写盘。占用与清空分别是 `usage()` /
/// `removeAll()`。三者的解释权都在这一层 —— 设置页只看数字,不自己扫目录。
actor PosterDiskCache {
    /// 默认磁盘字节上限(256 MB)。用户可在「设置 → 缓存」里改。
    static let defaultByteLimit = 256 * 1024 * 1024

    /// 上限可选的档位(MB)。设置页的 Picker 用它;档位之外的存量值按默认档处理。
    ///
    /// ⛔ 不提供「不限」:海报缓存是纯派生数据,铺满磁盘时受害的是整个 App。
    static let byteLimitOptionsMB = [128, 256, 512, 1024, 2048]

    /// 当前生效的磁盘字节上限,超出按最旧写入时间全局淘汰。
    private(set) var byteLimit: Int

    /// 超限淘汰时回收到的水位(上限的 80%)。只回收到刚好不超限的话,
    /// 之后每次写入都会再超限、每次都全量扫描目录。
    private var evictionTarget: Int { byteLimit / 5 * 4 }

    /// 磁盘根目录(`.../Images`)。目录**首次写入时才创建**,测试注入临时目录。
    private let directory: URL
    /// 已用字节数;首次写盘时扫描一次,之后增量维护。
    private var totalBytes: Int?

    /// 一次磁盘统计。设置页要同时显示「占多大」与「多少张」。
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

    /// 读缓存。无版本标识(不进磁盘缓存,3.3)、未命中、损坏一律返回 nil。
    func data(for descriptor: ImageDescriptor) -> Data? {
        guard descriptor.isDiskCacheable else { return nil }
        let fileURL = Self.fileURL(
            directory: directory, ownerID: descriptor.ownerID, cacheKey: descriptor.cacheKey)
        return try? Data(contentsOf: fileURL)
    }

    /// 写缓存。无版本标识直接拒存(3.3:没有版本标识的图片不进磁盘缓存)。
    func store(_ data: Data, for descriptor: ImageDescriptor) {
        guard descriptor.isDiskCacheable else { return }
        let ownerDir = directory.appendingPathComponent(
            descriptor.ownerID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: ownerDir, withIntermediateDirectories: true)
            let fileURL = Self.fileURL(
                directory: directory, ownerID: descriptor.ownerID, cacheKey: descriptor.cacheKey)
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

    /// `ImageSpec` 便利入口(等价于 `.emby(spec)`)。
    func data(for spec: ImageSpec) -> Data? { data(for: .emby(spec)) }

    func store(_ data: Data, for spec: ImageSpec) { store(data, for: .emby(spec)) }

    /// 删除某个来源的全部图片(删来源时调用)。内存层由 LRU 自行淘汰,不必清。
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

    /// 改磁盘上限。**调低时立刻按新上限淘汰**,不等下一次写盘 —— 否则用户把
    /// 2 GB 改成 128 MB 后回到首页,那 2 GB 还躺在盘上,数字也只涨不降。
    func setByteLimit(_ bytes: Int) {
        let limit = max(0, bytes)
        guard limit != byteLimit else { return }
        byteLimit = limit
        evictIfOverLimit()
    }

    /// 当前占用。真实扫描磁盘而不是信簿记:簿记只在写 / 删 / 清时更新,
    /// 用户手删目录、系统清理缓存之后它会偏大,这一眼正是校准的时机。
    ///
    /// ⚠️ 全目录扫一遍(几千次 `resourceValues`),只给设置页这种一次性动作调,
    /// ⛔ 不要放进图片加载路径。
    func usage() -> Usage {
        let scanned = scanUsage()
        totalBytes = scanned.bytes
        return scanned
    }

    /// 清空磁盘缓存(设置页「清空图片缓存」)。目录整片删掉,下次写入自行重建。
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        totalBytes = 0
    }

    // MARK: - 内部

    private func evictIfOverLimit() {
        // 改上限可能发生在任何一次写入之前(簿记还是 nil),先扫一次再判超限
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

    /// 维护字节簿记。**先完成文件系统变更,再调这里**;
    /// 首次调用只扫描(扫描结果已含刚完成的变更),不叠加 delta —— 否则双计。
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

    /// 文件名 = sha256(cacheKey)。cacheKey 已含来源 id 等,hash 后仍互不碰撞。
    private static func fileURL(directory: URL, ownerID: UUID, cacheKey: String) -> URL {
        let name = SHA256.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory
            .appendingPathComponent(ownerID.uuidString, isDirectory: true)
            .appendingPathComponent(name + ".img")
    }
}
