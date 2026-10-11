import CryptoKit
import Foundation

/// 接口响应的本地缓存(actor,CLAUDE.md「并发分层」的 Core 有状态类型分层)。
///
/// 目标:TTL 内零网络请求,
/// 切换服务器 / 重进页面 / 重启 App 都秒出内容;过期或未命中时走原有网络路径,无回归。
///
/// 选型是**透明 TTL**,不是 SWR(先给旧数据、后台刷新):SWR 会把错的 `UserData`
/// (已看 / 收藏 / 进度)端给用户。过期后的行为与无缓存完全一致。
///
/// 三个关键决定:
///
/// 1. **存原始响应字节,不存解码值**。`Models/` 的 DTO 只有 `Decodable`
///    (不是 `Encodable`),把解码值重编码进缓存既要求全量加协议又可能丢字段。
///    命中后由调用方经 `EmbyAPIClient.decode` 重新解码。
///
/// 2. **缓存 key 不含 scheme/host**(同 API_CONTRACT.md 3.3 对图片缓存的要求):
///    同一台服务器内外网切换 / http 回退后仍复用同一份缓存。key 含 serverID,
///    两台镜像媒体库的服务器不会串台。
///
/// 3. **per-server epoch 防失效竞态**:写操作(标记已看 / 收藏)会让整台缓存
///    作废,但它之前发出的读请求回来时仍会带着旧数据写缓存、白拿一个新 TTL。
///    `store` 只接受「取数据时读到的那个 epoch」,不匹配就丢弃 —— 与
///    `PlaybackProgressReporter` 的 generation 代次号同一模式(5.4)。
///
/// 失效规则(触发点在 `ServerConnection` / `AppContainer`):
///
/// | 触发 | 行为 |
/// |---|---|
/// | 标记已看 / 收藏 / 移出继续观看 | 整台作废(写操作改了散布在多个列表里的 UserData) |
/// | 播放上报 Playing / Stopped | 整台作废 |
/// | 播放上报 Progress | **不失效**:每 10 秒一次,失效会让播放期间的浏览永远打不到缓存 |
/// | 登录成功 / 登出 | 整台作废 |
/// | 删除服务器 | 内存 + 磁盘一起清(`purgeDisk`) |
/// | 工具栏刷新 | 先作废再重载 |
///
/// ⛔ 登录时的访问验证(`verifyAccessWithFreshViews`)必须绕过缓存,否则失效 token / 被禁用户会假装登录成功。
/// 可缓存端点是 allowlist(`EmbyEndpoint.isResponseCacheable`),图片 / 播放上报 / PlaybackInfo / 认证类不在内。
/// 上限:内存 200 条(FIFO)、磁盘 64 MB(按最旧写入淘汰到 80%);过期文件读到时顺手删(懒清扫)。
/// 图片缓存另见 `PosterImageStore`(内存 LRU 300 条,磁盘 256 MB;没有 `Tag` 的图不进磁盘)。
///
/// 缓存是尽力而为的:磁盘 IO 失败(盘满、权限)静默降级为不缓存,
/// 不影响网络路径的正确性。这不是吞错 —— 缓存命中与否都不改变语义。
actor EmbyResponseCache {
    /// fresh 窗口。依据:用户的服务端数据按小时级变化;resume / nextUp 的时效性
    /// 由「播放上报后失效」保证,不靠这个 TTL。要改只改这一个常量。
    static let freshWindow: TimeInterval = 3600

    /// 内存条目上限(FIFO 淘汰最旧插入的)。
    static let memoryEntryLimit = 200

    /// 磁盘字节上限,超出按最旧写入时间淘汰。
    static let diskByteLimit = 64 * 1024 * 1024

    /// 超限淘汰时回收到的水位(上限的 80%)。只回收到刚好不超限的话,
    /// 之后每次写入都会再超限、每次都全量扫描目录。
    static let diskEvictionTarget = diskByteLimit / 5 * 4

    private struct Entry: Sendable {
        let data: Data
        let storedAt: Date
    }

    /// 注入时钟是为了让 TTL 可单测;生产用 `Date.init`。
    private let now: @Sendable () -> Date
    /// 磁盘根目录(`.../Responses`)。目录**首次写入时才创建**,测试注入临时目录。
    private let directory: URL

    private var memory: [String: Entry] = [:]
    /// 内存 FIFO 的插入顺序(淘汰最前面的)。
    private var insertionOrder: [String] = []
    /// per-server 代次号,`invalidate` 时 +1。
    private var epochs: [UUID: Int] = [:]
    /// 磁盘已用字节数;首次磁盘操作时扫描一次,之后增量维护。nil = 还没扫过。
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

    /// fresh 命中返回原始响应字节;未命中 / 过期 / 损坏返回 nil。
    /// 过期的磁盘文件顺手删除(懒清扫)。
    func freshData(serverID: UUID, endpoint: EmbyEndpoint) -> Data? {
        let key = Self.key(serverID: serverID, endpoint: endpoint)
        if let entry = memory[key] {
            if now().timeIntervalSince(entry.storedAt) <= Self.freshWindow {
                return entry.data
            }
            removeMemoryEntry(key)
        }
        let fileURL = Self.fileURL(directory: directory, serverID: serverID, key: key)
        guard let raw = try? Data(contentsOf: fileURL), raw.count > 8 else {
            return nil
        }
        let storedSeconds = raw.prefix(8).reduce(into: Int64(0)) { $0 = ($0 << 8) | Int64($1) }
        let storedAt = Date(timeIntervalSince1970: TimeInterval(storedSeconds))
        guard now().timeIntervalSince(storedAt) <= Self.freshWindow else {
            try? FileManager.default.removeItem(at: fileURL)
            trackDiskBytes(-raw.count)
            return nil
        }
        return Data(raw.suffix(from: 8))
    }

    // MARK: - 写

    /// 当前代次号。调用方网络请求**开始前**取一次,成功后原样传给 `store`。
    func currentEpoch(serverID: UUID) -> Int {
        epochs[serverID] ?? 0
    }

    /// 写入缓存。`epoch` 必须是取数时读到的 `currentEpoch`,
    /// 与现值不符 = 失效发生在请求在途期间,这次的数据不作数,丢弃。
    func store(_ data: Data, serverID: UUID, endpoint: EmbyEndpoint, epoch: Int) {
        guard epoch == (epochs[serverID] ?? 0) else { return }
        let key = Self.key(serverID: serverID, endpoint: endpoint)
        memory[key] = Entry(data: data, storedAt: now())
        // 同 key 并发取数会 store 两次:先去掉旧位置,否则顺序表里留重复 key,
        // FIFO 淘汰旧那份时会把刚写入的新条目一起删掉
        insertionOrder.removeAll { $0 == key }
        insertionOrder.append(key)
        if insertionOrder.count > Self.memoryEntryLimit {
            let evicted = insertionOrder.removeFirst()
            memory.removeValue(forKey: evicted)
        }
        writeToDisk(data, serverID: serverID, key: key)
    }

    /// 单条作废(缓存字节解不出模型时删掉坏条目,按 miss 重走网络)。
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

    /// 整台服务器作废:代次 +1、清内存、删磁盘目录。
    /// 触发点见类型注释里的失效规则表。
    func invalidate(serverID: UUID) {
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
            // 时间头按大端写(读取端按大端解析,不依赖本机字节序)
            var seconds = Int64(now().timeIntervalSince1970).bigEndian
            withUnsafeBytes(of: &seconds) { payload.append(contentsOf: $0) }
            payload.append(data)
            let fileURL = Self.fileURL(directory: directory, serverID: serverID, key: key)
            // 同 key 重写(内存淘汰后磁盘文件也被容量淘汰过的场景):
            // 旧文件的字节必须从簿记里扣掉,delta 才正确
            let oldSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // 先删再写:原子写遇到已存在文件是覆盖,但先删可让「写了一半」的
            // 旧坏文件不可能残留(原子写本身也保证不会写到一半被读走)
            try? FileManager.default.removeItem(at: fileURL)
            try payload.write(to: fileURL, options: .atomic)
            trackDiskBytes(payload.count - oldSize)
            evictDiskIfOverLimit()
        } catch {
            // 磁盘写不进去:降级为仅内存缓存,不影响正确性(见类注释)
        }
    }

    /// 超出磁盘上限时按最旧写入时间淘汰,直到回到 `diskEvictionTarget` 以下。
    /// 只在写入超限后触发;留 20% 余量,避免贴着上限时每次写都全量扫描。
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

    /// 维护磁盘字节簿记。**先完成文件系统变更,再调这里**;
    /// 首次调用只扫描(扫描结果已含刚完成的变更),不叠加 delta —— 否则双计。
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

    /// 缓存 key:serverID + method + path + queryItems。
    /// `EmbyEndpoint.queryItems` 由 struct 字段按固定顺序拼装,跨启动稳定。
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
