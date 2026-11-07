import CryptoKit
import Foundation

/// Emby 接口响应缓存:fresh 窗口内零网络请求;过期 / 作废的条目不删,留给「先显示旧数据」。
///
/// 两种读法:
/// - `freshData`:只给窗口内且没被作废的,常规请求路径用(命中就不发请求);
/// - `staleData`:不论新旧都给,只用来先把界面填上,之后照常走 `freshData` / 网络,回来原地替换
///   (首页的 SWR,`HomeViewModel`)。旧的 `UserData` 只会显示到新数据回来为止。
///
/// 1. 存原始响应字节、不存解码值(DTO 只有 `Decodable`),命中后经 `EmbyAPIClient.decode` 重解。
/// 2. key 不含 scheme/host(内外网切换 / http 回退复用),含 serverID(镜像库的两台不串台)。
/// 3. per-server epoch 防失效竞态:作废前发出的读请求回来时会带旧数据写缓存;`store` 只接受
///    取数时读到的 epoch,不符就丢弃(同 `PlaybackProgressReporter` 的 generation,5.4)。
///
/// 失效规则(触发点在 `ServerConnection` / `AppContainer`):
///
/// | 触发 | 行为 |
/// |---|---|
/// | 标记已看 / 收藏 / 移出继续观看 | 整台作废(写操作改了散布在多个列表里的 UserData) |
/// | 播放上报 Playing / Stopped | 整台作废 |
/// | 播放上报 Progress | **不失效**:每 10 秒一次,失效会让播放期间的浏览永远打不到缓存 |
/// | 手动刷新(⌘R) | 整台作废再重载 |
/// | 登录成功 / 登出 / 换成另一台 Emby | 整台清除(`purge`:换了用户,旧数据连「先显示」都不能给) |
/// | 删除服务器 | 整台清除 |
///
/// 「作废」= 条目时间戳归零:之后 `freshData` 不给、`staleData` 照给。
///
/// ⛔ 登录时的访问验证(`verifyAccessWithFreshViews`)必须绕过缓存,否则失效 token / 被禁用户会假装登录成功。
/// 可缓存端点是 allowlist(`EmbyEndpoint.isResponseCacheable`),图片 / 播放上报 / PlaybackInfo / 认证类不在内。
/// 上限:内存 200 条(FIFO)、磁盘 64 MB(按最旧写入淘汰到 80%)。
/// 图片缓存另见 `PosterImageStore`(内存 LRU 300 条,磁盘默认 256 MB 可调;无版本标识的图不进磁盘)。
///
/// 尽力而为:磁盘 IO 失败静默降级为不缓存。这不是吞错 —— 命中与否不改变语义。
actor EmbyResponseCache {
    /// 服务端数据更新很慢,窗口给长:窗口内回到页面零请求,要更早看到新数据按 ⌘R。
    /// resume / nextUp / UserData 的时效靠「写操作与播放上报后作废」,不靠窗口。
    static let freshWindow: TimeInterval = 12 * 3600

    static let memoryEntryLimit = 200

    static let diskByteLimit = 64 * 1024 * 1024

    /// 回收到 80%,否则贴着上限时每次写入都再超限、全量扫目录。
    static let diskEvictionTarget = diskByteLimit / 5 * 4

    private struct Entry: Sendable {
        let data: Data
        let storedAt: Date
    }

    /// 注入以单测 TTL
    private let now: @Sendable () -> Date
    /// 首次写入时才创建
    private let directory: URL

    private var memory: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    /// `invalidate` 时 +1
    private var epochs: [UUID: Int] = [:]
    /// nil = 还没扫过
    private var diskBytes: Int?

    init(
        directory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory ?? Self.defaultDirectory()
        self.now = now
    }

    private static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "LumaPlayer"
        return caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Responses", isDirectory: true)
    }

    // MARK: - 读

    /// 未命中 / 过期 / 已作废 / 损坏返回 nil。过期条目留着给 `staleData`。
    func freshData(serverID: UUID, endpoint: EmbyEndpoint) -> Data? {
        guard let entry = entry(serverID: serverID, endpoint: endpoint),
              now().timeIntervalSince(entry.storedAt) <= Self.freshWindow else { return nil }
        return entry.data
    }

    /// 不论新旧,有就给。只用来先填界面,调用方之后必须照常取一次新的。
    func staleData(serverID: UUID, endpoint: EmbyEndpoint) -> Data? {
        entry(serverID: serverID, endpoint: endpoint)?.data
    }

    private func entry(serverID: UUID, endpoint: EmbyEndpoint) -> Entry? {
        let key = Self.key(serverID: serverID, endpoint: endpoint)
        if let entry = memory[key] { return entry }
        let fileURL = Self.fileURL(directory: directory, serverID: serverID, key: key)
        guard let raw = try? Data(contentsOf: fileURL), raw.count > 8 else {
            return nil
        }
        let storedSeconds = raw.prefix(8).reduce(into: Int64(0)) { $0 = ($0 << 8) | Int64($1) }
        return Entry(
            data: Data(raw.suffix(from: 8)),
            storedAt: Date(timeIntervalSince1970: TimeInterval(storedSeconds))
        )
    }

    // MARK: - 写

    /// 网络请求开始前取一次,成功后原样传给 `store`。
    func currentEpoch(serverID: UUID) -> Int {
        epochs[serverID] ?? 0
    }

    /// `epoch` 与现值不符 = 请求在途期间发生了失效,丢弃。
    func store(_ data: Data, serverID: UUID, endpoint: EmbyEndpoint, epoch: Int) {
        guard epoch == (epochs[serverID] ?? 0) else { return }
        let key = Self.key(serverID: serverID, endpoint: endpoint)
        memory[key] = Entry(data: data, storedAt: now())
        // 同 key 可能 store 两次:先去重,否则淘汰旧那份时会连带删掉新条目
        insertionOrder.removeAll { $0 == key }
        insertionOrder.append(key)
        if insertionOrder.count > Self.memoryEntryLimit {
            let evicted = insertionOrder.removeFirst()
            memory.removeValue(forKey: evicted)
        }
        writeToDisk(data, serverID: serverID, key: key)
    }

    /// 缓存字节解不出模型时删掉坏条目。
    func discard(serverID: UUID, endpoint: EmbyEndpoint) {
        let key = Self.key(serverID: serverID, endpoint: endpoint)
        removeMemoryEntry(key)
        let fileURL = Self.fileURL(directory: directory, serverID: serverID, key: key)
        var removed = 0
        if let raw = try? Data(contentsOf: fileURL) {
            removed = raw.count
        }
        try? FileManager.default.removeItem(at: fileURL)
        trackDiskBytes(-removed)
    }

    /// 整台作废:条目留着(`staleData` 照给),但不再算 fresh。触发点见类型注释。
    func invalidate(serverID: UUID) {
        epochs[serverID, default: 0] += 1
        let prefix = serverID.uuidString + "|"
        for key in insertionOrder where key.hasPrefix(prefix) {
            if let entry = memory[key] {
                memory[key] = Entry(data: entry.data, storedAt: .distantPast)
            }
        }
        let serverDir = directory.appendingPathComponent(serverID.uuidString, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: serverDir, includingPropertiesForKeys: nil
        ) else { return }
        // 时间头归零 = 1970 年写入,必然过期;大小不变,不动簿记
        let zeroHeader = Data(count: 8)
        for file in files {
            guard let handle = try? FileHandle(forWritingTo: file) else { continue }
            try? handle.write(contentsOf: zeroHeader)
            try? handle.close()
        }
    }

    /// 整台清除(内存 + 磁盘),旧数据连「先显示」也不能再给。触发点见类型注释。
    func purge(serverID: UUID) {
        epochs[serverID, default: 0] += 1
        let prefix = serverID.uuidString + "|"
        for key in insertionOrder where key.hasPrefix(prefix) {
            memory.removeValue(forKey: key)
        }
        insertionOrder.removeAll { $0.hasPrefix(prefix) }
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
        trackDiskBytes(-removed)
    }

    // MARK: - 内部

    private func removeMemoryEntry(_ key: String) {
        memory.removeValue(forKey: key)
        insertionOrder.removeAll { $0 == key }
    }

    private func writeToDisk(_ data: Data, serverID: UUID, key: String) {
        let serverDir = directory.appendingPathComponent(serverID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
            var payload = Data()
            // 8 字节大端时间头
            var seconds = Int64(now().timeIntervalSince1970).bigEndian
            withUnsafeBytes(of: &seconds) { payload.append(contentsOf: $0) }
            payload.append(data)
            let fileURL = Self.fileURL(directory: directory, serverID: serverID, key: key)
            // 同 key 重写时旧文件字节要从簿记里扣掉
            let oldSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: fileURL)
            try payload.write(to: fileURL, options: .atomic)
            trackDiskBytes(payload.count - oldSize)
            evictDiskIfOverLimit()
        } catch {
            // 降级为仅内存缓存
        }
    }

    private func evictDiskIfOverLimit() {
        guard (diskBytes ?? 0) > Self.diskByteLimit else { return }
        var candidates: [(url: URL, modified: Date, size: Int)] = []
        guard let servers = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
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
        let oversize = (diskBytes ?? 0) - Self.diskEvictionTarget
        var reclaimed = 0
        for file in candidates.sorted(by: { $0.modified < $1.modified }) {
            guard reclaimed < oversize else { break }
            try? FileManager.default.removeItem(at: file.url)
            reclaimed += file.size
        }
        diskBytes = (diskBytes ?? 0) - reclaimed
    }

    /// 须在文件系统变更完成后调。首次调用只扫描、不叠加 delta(扫描已含该变更,否则双计)。
    private func trackDiskBytes(_ delta: Int) {
        if diskBytes == nil {
            diskBytes = scanDiskBytes()
            return
        }
        diskBytes = max(0, (diskBytes ?? 0) + delta)
    }

    private func scanDiskBytes() -> Int {
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

    // MARK: - key 与文件名

    /// 依赖 `EmbyEndpoint.queryItems` 顺序固定,跨启动稳定。
    static func key(serverID: UUID, endpoint: EmbyEndpoint) -> String {
        let query = endpoint.queryItems
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "&")
        return "\(serverID.uuidString)|\(endpoint.method)|\(endpoint.path)|\(query)"
    }

    private static func fileURL(directory: URL, serverID: UUID, key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory
            .appendingPathComponent(serverID.uuidString, isDirectory: true)
            .appendingPathComponent(name + ".bin")
    }
}
