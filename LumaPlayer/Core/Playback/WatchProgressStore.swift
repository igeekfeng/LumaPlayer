import Foundation
import os

/// 本地续播库(**百度来源唯一的进度存储**)。
///
/// ## 为什么必须自己造一个
///
/// Emby 的「继续观看」是**服务端**能力:进度写在 Emby 上,换设备也在。
/// 百度网盘**没有播放进度上报接口**(`docs/BAIDU_PAN_API.md`)——
/// 也就是说百度来源上「接着看」这件事在服务端根本不存在,只能记在本地。
/// ⛔ 这不是接线问题,是产品能力缺口。
///
/// ## 为什么是 JSON 文件而不是数据库
///
/// 与 `CredentialFileStore` 同一套做法:原子写、0600、不进备份。
/// 自用场景下几千条记录,体量完全不需要数据库。
///
/// ⚠️ 落点与凭据文件同级(`Library/Application Support/LumaPlayer/`)。
actor WatchProgressStore {

    /// 一条进度记录。
    ///
    /// ⚠️ `display` 是**后加**的可选字段。它缺失时旧文件照常解码
    /// (合成的 `Codable` 对可选字段走 `decodeIfPresent`)——
    /// 升级不该把用户已有的进度判成损坏(§7 那条迁移纪律)。
    struct Entry: Codable, Sendable, Equatable {
        var positionSeconds: Double
        /// 已知总时长;未知为 nil
        var durationSeconds: Double?
        var updatedAt: Date
        /// 渲染续播卡片要的展示信息(标题 / 定位 / 封面)。
        /// ⛔ 可选:老记录没有它,照样能续播,只是不出现在「继续观看」区。
        var display: Display?
    }

    /// 一条记录的**展示快照**。
    ///
    /// ## 为什么进度库里要存这些
    ///
    /// 「继续观看」要的是一张能看的卡片(标题 + 封面 + 已看到哪),而这些
    /// 在百度侧**不在进度里**:标题是文件名解析出来的,封面是同目录兄弟文件。
    /// 它们只在**播放那一刻**拿得到(浏览页刚合成过 `SourceItem`)。
    /// 所以播放时顺手记一份 —— ⛔ 而不是回头再列一遍网盘(配额 10 次/小时)。
    struct Display: Codable, Sendable, Equatable {
        /// 哪个来源。多来源时按它过滤,删来源时按它整片清。
        var sourceID: UUID
        /// 卡片标题(合成器解析出来的)
        var title: String
        /// 来源内定位信息(百度:文件 `path`)。重新播它要用。
        var locator: String
        /// 原始文件名(重建 `BaiduPanFile` 用)
        var fileName: String
        /// 封面快照。nil = 当时没配到封面,卡片降级成图标
        var cover: ImageDescriptor.Snapshot?
        /// 集号。nil = 不是一集(电影 / 单条视频),或老记录没记。
        /// 它只在**卡片合并后**才有意义:一部剧只出一张卡时,得说清接着看的是第几集。
        var episodeNumber: Int? = nil
    }

    /// 一条可供 UI 渲染的续播记录(`resumeEntries` 的返回)。
    struct ResumeRecord: Sendable, Equatable {
        /// 来源内 id(百度:`fs_id` 字符串)
        let fileID: String
        let positionSeconds: Double
        let durationSeconds: Double?
        let updatedAt: Date
        let display: Display
    }

    /// 视为「已看完」的比例:超过它就不再续播,从头开始。
    /// 与 Emby 那边的语义对齐(服务端自己按比例判已看),
    /// 这里的阈值只影响本地续播,不影响任何上报。
    static let finishedThreshold: Double = 0.95

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "watch-progress")

    private let fileURL: URL
    private var loaded: [String: Entry]?
    /// 读盘失败的原因(诊断用)。**不静默吞**:读到损坏的文件时把原因留下来,
    /// 由调用方决定要不要提示;⛔ 不假装「没有记录」然后继续。
    private(set) var lastLoadFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 生产路径:与凭据文件同在应用支持目录下。
    ///
    /// ⚠️ 测试宿主用**另一个文件名**:单元测试跑在宿主 App 进程里、共享真实
    /// 沙盒容器(与 `NetworkDiagnostics` 的处置同一个理由),写同一个文件
    /// 会把真实记录冲掉。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let filename = isTestHost ? "watch-progress-testhost.json" : "watch-progress.json"
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
    }

    // MARK: - 读

    /// 该从哪一秒接着看。
    ///
    /// - Returns: 需要续播的位置(已扣掉「已看完」这一档);`nil` = 没有记录
    ///   或已看完,调用方从 0 开始。
    ///   ⚠️ 不在这里做 `Metrics.resumeRewind` 的回退 —— 那是播放层的规则
    ///   (`PlaybackRules.resumePosition`),与 Emby 来源走同一个函数。
    func resumeSeconds(forFileID id: String) -> Double? {
        guard let entry = entries()[id], entry.positionSeconds > 0 else { return nil }
        guard !Self.isFinished(entry) else { return nil }
        return entry.positionSeconds
    }

    /// 这一条是不是已经看完。
    ///
    /// ⚠️ 时长未知时**判不了**,按未看完处理(⛔ 不猜):宁可多留一张卡,
    /// 也不能因为缺时长就把看到一半的判成看完。
    private static func isFinished(_ entry: Entry) -> Bool {
        guard let duration = entry.durationSeconds, duration > 0 else { return false }
        return entry.positionSeconds / duration >= finishedThreshold
    }

    /// 全部记录(诊断 / 测试观察用)
    func snapshot() -> [String: Entry] { entries() }

    /// 某个来源下**有进度**的续播记录(UI 渲染「继续观看」用)。
    ///
    /// 过滤三条:必须带展示快照(老记录没有),位置必须 > 0(起播那一刻
    /// 写进来的 0 秒不算「看过」),已看完(≥ `finishedThreshold`)的不再续播 ——
    /// 与 `resumeSeconds` 同一把尺子,否则看完的集会一直占着一张卡。
    /// 按 `updatedAt` 倒序 —— 最近看的排前面。
    func resumeEntries(sourceID: UUID) -> [ResumeRecord] {
        entries()
            .compactMap { key, entry -> ResumeRecord? in
                guard let display = entry.display,
                      display.sourceID == sourceID,
                      entry.positionSeconds > 0,
                      !Self.isFinished(entry) else { return nil }
                return ResumeRecord(
                    fileID: key,
                    positionSeconds: entry.positionSeconds,
                    durationSeconds: entry.durationSeconds,
                    updatedAt: entry.updatedAt,
                    display: display
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - 写

    /// 记一条进度。位置为 0 或负值时**删掉**这条记录 ——
    /// 「从 0 开始看」不是一条进度,留着会让下次续播读到 0。
    ///
    /// ⚠️ 保留已有的 `display`:进度与展示信息是**两个写入方**
    /// (上报器写位置、播放页写展示),后写的不能把先写的抹掉。
    func record(fileID id: String, positionSeconds: Double, durationSeconds: Double?) throws {
        guard positionSeconds > 0 else {
            try remove(fileID: id)
            return
        }
        var current = entries()
        current[id] = Entry(
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            updatedAt: Date(),
            display: current[id]?.display
        )
        try persist(current)
    }

    /// 记一条展示快照(播放那一刻从 `SourceItem` 提取)。
    ///
    /// ⚠️ 与 `record` 对称:保留已有的位置 —— 起播时先记展示(此刻位置还是 0),
    /// 上报器随后才把位置写进来。两者都改同一份文件,由 actor 串行化,⛔ 不竞态。
    func rememberDisplay(fileID id: String, display: Display) throws {
        var current = entries()
        let existing = current[id]
        current[id] = Entry(
            positionSeconds: existing?.positionSeconds ?? 0,
            durationSeconds: existing?.durationSeconds,
            updatedAt: Date(),
            display: display
        )
        try persist(current)
    }

    func remove(fileID id: String) throws {
        var current = entries()
        guard current.removeValue(forKey: id) != nil else { return }
        try persist(current)
    }

    // MARK: - 内部(actor 隔离内同步,不产生 await)

    private func entries() -> [String: Entry] {
        if let loaded { return loaded }
        let result = readFile()
        loaded = result
        return result
    }

    private func readFile() -> [String: Entry] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            lastLoadFailureDescription = "读取续播库失败:\(error)"
            Self.logger.error("续播库读取失败 \(String(describing: error), privacy: .public)")
            return [:]
        }
        do {
            // ⚠️ 解码策略必须与 `persist` 的编码策略对称:写的时候用了 `.iso8601`,
            // 读的时候用默认策略(`.deferredToDate`)会解不出 `Date`,整份文件被判成损坏。
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([String: Entry].self, from: data)
        } catch {
            // 文件坏了。⛔ 不就地重置成空文件 —— 先如实记下原因,
            // 让用户/我们有一次机会看到它(写操作会覆盖,所以放在写路径之前)。
            lastLoadFailureDescription = "续播库文件损坏:\(error)"
            Self.logger.error("续播库文件损坏 \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private func persist(_ entries: [String: Entry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw WatchProgressStoreError.writeFailed
        }
        // 0600:进度虽非凭据,但「谁看了什么」属于隐私,不该对同机其他用户可读
        guard FileManager.default.createFile(
            atPath: temporary.path(percentEncoded: false),
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw WatchProgressStoreError.writeFailed
        }
        guard rename(temporary.path(percentEncoded: false), fileURL.path(percentEncoded: false)) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw WatchProgressStoreError.writeFailed
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = fileURL
        try target.setResourceValues(values)
        loaded = entries
    }
}

enum WatchProgressStoreError: Error, Equatable {
    case writeFailed
}
