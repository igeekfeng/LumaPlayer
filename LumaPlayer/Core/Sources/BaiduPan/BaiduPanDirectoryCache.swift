import Foundation
import os

/// 百度网盘**目录的落盘缓存**:把一次列目录的原始文件与时长存下来,
/// 下次进同一个目录先出内容、再后台刷新。
///
/// ## 为什么必须有它
///
/// 百度的调用配额极低(`docs/BAIDU_PAN_API.md` §7),而「打开来源 → 进目录 →
/// 退回来 → 再进」这种走法每一层都是 `list` + `filemetas` 两次请求。
/// 会话内的内存缓存(`BaiduPanSourceViewModel.directoryCache`)只活到页面重建为止
/// —— 切一次来源(ViewModel 按 `source.id` 重建)或重启 App 就全空了,
/// 于是每次冷启动都要转圈等网络。
///
/// 这里把「那一层目录里有什么」按 `来源 + 路径` 存到磁盘,冷启动时:
/// ① 先合成卡片(纯函数,毫秒级)让内容立刻出来;
/// ② 同时后台发一次真实请求,回来了就地替换。
///
/// ## 缓存里**不**存什么
///
/// - **封面地址**:百度 `dlink` 8 小时过期,存下来只会端出一批打不开的图。
///   封面靠 `PosterDiskCache`(按 `cacheKey`,含封面文件 mtime)兜底,
///   后台刷新那一趟会重新换到新地址。
/// - **刮削结果**:那一层有自己的落盘缓存(`BaiduPanScrapeCache`),
///   两件事的失效条件不同(文件变了 vs 元数据没变),混在一起会互相误伤。
///
/// ## 失效
///
/// - **时间**:超过 `maxAge`(24 小时)当没有,直接走网络;
/// - **显式**:删 / 改名 / 隐藏之后由调用方 `remove`(删目录要连子层一起丢);
/// - **删除来源**:`purge(sourceID:)` 整片清掉。
///
/// ⚠️ 缓存是「显示用」的,**不是事实来源**:播放前用的仍是当次列表里的
/// `BaiduPanFile`;缓存里那条文件若已被删,播放会如实失败,后台刷新随后把它抹掉。
actor BaiduPanDirectoryCache {

    /// 一个目录的快照。
    struct Entry: Codable, Sendable, Equatable {
        let files: [BaiduPanFile]
        /// `fs_id` → 时长(秒)。列表接口不给时长,这一格来自当次 `filemetas`
        /// (`needmedia=1`);不存它的话冷启动的卡片上又只剩标题。
        /// 键用 `String` 是为了 JSON 形状稳定(`UInt64` 键会被编码成数组)。
        let durations: [String: Double]
        let fetchedAt: Date

        func duration(for fsID: UInt64) -> Double? {
            durations[String(fsID)]
        }
    }

    /// 磁盘上的整份文件:`来源 id` → `目录路径` → 快照。
    private struct Snapshot: Codable, Sendable {
        var sources: [String: [String: Entry]]
    }

    private static let logger = Logger(
        subsystem: NetworkDiagnostics.subsystem, category: "baidu-directory-cache")

    /// 超过这个时间就当没有 —— 24 小时足够覆盖「今天开的 App 明天还开着」,
    /// 又不至于把一周前删掉的文件一直端出来。
    static let maxAge: TimeInterval = 24 * 60 * 60

    /// 每个来源最多留多少个目录。一个来源几百层已经远超正常浏览深度;
    /// 超出时丢**最旧**的那批(按 `fetchedAt`)。
    static let maxDirectoriesPerSource = 300

    private let fileURL: URL
    private var snapshot: Snapshot?
    /// 读盘失败的原因(诊断用)。**不静默吞**:文件损坏时留下原因,
    /// 但浏览照常走网络 —— 缓存坏了不该让片库打不开。
    private(set) var lastLoadFailureDescription: String?
    /// 最近一次写盘失败的原因(nil = 没失败)。写失败不影响浏览,只是下次还得等网络。
    private(set) var lastWriteFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 生产路径:与凭据文件、续播库同在应用支持目录下。
    /// ⚠️ 测试宿主用另一个文件名,避免单测把真实缓存冲掉(与 `HiddenItemsStore` 同一纪律)。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let filename = isTestHost
            ? "baidu-directory-cache-testhost.json"
            : "baidu-directory-cache.json"
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
    }

    // MARK: - 读

    /// 某个目录的缓存;过期 / 没有都返回 nil。
    ///
    /// - Parameter now: 注入时钟只为测试;生产用当前时间。
    func content(sourceID: UUID, directory: String, now: Date = Date()) -> Entry? {
        guard let entry = state()[sourceID.uuidString]?[directory] else { return nil }
        guard now.timeIntervalSince(entry.fetchedAt) <= Self.maxAge else { return nil }
        return entry
    }

    // MARK: - 写

    /// 存一个目录的快照(整层替换)。失败只记原因,⛔ 不抛给浏览链路。
    func store(
        sourceID: UUID,
        directory: String,
        files: [BaiduPanFile],
        durations: [UInt64: Double],
        now: Date = Date()
    ) {
        var all = state()
        var perSource = all[sourceID.uuidString] ?? [:]
        perSource[directory] = Entry(
            files: files,
            durations: Dictionary(
                uniqueKeysWithValues: durations.map { (String($0.key), $0.value) }),
            fetchedAt: now
        )
        // 超上限:先按时间丢最旧的,只丢到上限为止
        if perSource.count > Self.maxDirectoriesPerSource {
            let overflow = perSource.count - Self.maxDirectoriesPerSource
            let oldest = perSource
                .sorted { $0.value.fetchedAt < $1.value.fetchedAt }
                .prefix(overflow)
                .map(\.key)
            for key in oldest { perSource.removeValue(forKey: key) }
        }
        all[sourceID.uuidString] = perSource
        persist(all)
    }

    /// 丢掉某个目录(删 / 改名 / 隐藏之后)。`includeDescendants` 为真时连子层一起丢
    /// —— 删掉一个季目录,它下面的旧内容一样是垃圾。
    func remove(sourceID: UUID, directory: String, includeDescendants: Bool = true) {
        var all = state()
        guard var perSource = all[sourceID.uuidString] else { return }
        let removed = perSource.keys.filter { key in
            key == directory
                || (includeDescendants && BaiduPanPath.isInside(key, applicationRoot: directory))
        }
        guard !removed.isEmpty else { return }
        for key in removed { perSource.removeValue(forKey: key) }
        all[sourceID.uuidString] = perSource
        persist(all)
    }

    /// 删除来源时整片清掉。
    func purge(sourceID: UUID) {
        var all = state()
        guard all.removeValue(forKey: sourceID.uuidString) != nil else { return }
        persist(all)
    }

    // MARK: - 内部

    private func state() -> [String: [String: Entry]] {
        if let snapshot { return snapshot.sources }
        let loaded = readFile()
        snapshot = Snapshot(sources: loaded)
        return loaded
    }

    private func readFile() -> [String: [String: Entry]] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            lastLoadFailureDescription = "读取百度目录缓存失败:\(error)"
            Self.logger.error("目录缓存读取失败 \(String(describing: error), privacy: .public)")
            return [:]
        }
        do {
            let decoder = JSONDecoder()
            // ⚠️ 与写入对称(同一个策略)。项目里踩过「写 iso8601 / 读默认」的坑,
            // 表现是整份文件被判成损坏、缓存永远读不回来(docs/PITFALLS.md)。
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Snapshot.self, from: data).sources
        } catch {
            // ⛔ 不就地重置成空文件:先如实记下原因,下次写盘时自然覆盖。
            lastLoadFailureDescription = "百度目录缓存文件损坏:\(error)"
            Self.logger.error("目录缓存文件损坏 \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private func persist(_ sources: [String: [String: Entry]]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(Snapshot(sources: sources))
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).tmp")
            // 0600:目录名就是用户在网盘里的片名,属于隐私(与隐藏列表同一处置)
            guard FileManager.default.createFile(
                atPath: temporary.path(percentEncoded: false),
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                lastWriteFailureDescription = "目录缓存写入失败(创建临时文件)"
                return
            }
            guard rename(
                temporary.path(percentEncoded: false),
                fileURL.path(percentEncoded: false)) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                lastWriteFailureDescription = "目录缓存写入失败(替换文件)"
                return
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = fileURL
            try? target.setResourceValues(values)
            snapshot = Snapshot(sources: sources)
            lastWriteFailureDescription = nil
        } catch {
            lastWriteFailureDescription = "目录缓存写入失败:\(error)"
            Self.logger.error("目录缓存写入失败 \(String(describing: error), privacy: .public)")
        }
    }
}
