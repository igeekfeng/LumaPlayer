import Foundation
import os

/// 本地续播库:百度来源唯一的进度与观看状态存储。
///
/// 百度没有任何播放进度 / 状态接口(`docs/BAIDU_PAN_API.md` §2),「接着看」与「已看」只能记本地;
/// ⛔ 这是产品能力缺口,不是接线问题。进度与 `played` 同生同灭,放同一份文件。
/// 做法同 `CredentialFileStore`:JSON、原子写、0600、不进备份,与凭据文件同目录。
actor WatchProgressStore {

    /// `played` / `upNext` / `display` 都是可选字段,缺失时旧文件照常解码,⛔ 不能把已有进度判成损坏。
    struct Entry: Codable, Sendable, Equatable {
        var positionSeconds: Double
        var durationSeconds: Double?
        var updatedAt: Date
        /// 显式观看状态:nil = 按比例现算;true = 已看;false = 用户手动标成未看。
        /// 必须存下来:百度列表不给时长(§4),没播过的算不出比例,而「标记已看」本就与比例无关。
        var played: Bool? = nil
        /// 「下一集」占位(Emby NextUp 的对位物),位置为 0。看完一集后库里没有进行中记录,
        /// 没有它整部剧就从「继续观看」消失;点过播放还没进度的集也记成它(`rememberDisplay`)。
        /// 真看了一点后 `record` 把它改回普通进度。
        var upNext: Bool? = nil
        /// 渲染续播卡片的展示信息。nil 的记录照样能续播,只是不出现在「继续观看」区。
        var display: Display?
    }

    /// 「看到一半」与「看完」互斥:看完的位置归 0,不再续播。
    enum WatchState: Sendable, Equatable {
        case unwatched
        case inProgress(seconds: Double)
        case watched
    }

    /// 续播卡片的展示快照。百度侧标题、封面都不在进度里,只在播放那一刻拿得到,
    /// 所以播放时顺手记一份;⛔ 不回头再列一遍网盘(配额见 §7)。
    struct Display: Codable, Sendable, Equatable {
        /// 多来源时按它过滤,删来源时整片清
        var sourceID: UUID
        var title: String
        /// 来源内定位(百度:文件 `path`),重新起播用
        var locator: String
        /// 重建 `BaiduPanFile` 用
        var fileName: String
        /// nil = 当时没配到封面,卡片降级成图标
        var cover: ImageDescriptor.Snapshot?
        /// nil = 不是一集或老记录。一部剧只出一张卡时用来说清接着看第几集
        var episodeNumber: Int? = nil
    }

    struct ResumeRecord: Sendable, Equatable {
        /// 百度:`fs_id` 字符串
        let fileID: String
        /// `isUpNext` 时为 0
        let positionSeconds: Double
        let durationSeconds: Double?
        let updatedAt: Date
        let display: Display
        /// UI 据此显示「下一集」而不是「已看到 00:00」,也不画进度条
        var isUpNext: Bool = false
    }

    /// 删除网盘条目时用,不管还续不续播。⛔ 不能用 `ResumeRecord` 代替:它会漏掉看完的 /
    /// 位置为 0 的记录,留下死记录。
    struct StoredRecord: Sendable, Equatable {
        /// 百度:`fs_id` 字符串
        let fileID: String
        let display: Display
    }

    /// 过了就落成 `played = true`、位置归 0。对齐 Emby 的 `MaxResumePct` 默认 90%。
    static let finishedThreshold: Double = 0.90

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "watch-progress")

    private let fileURL: URL
    private var loaded: [String: Entry]?
    /// 本次运行内已删的 id,写入路径据此拒绝写回:正在播的会话每 10 秒还会报进度
    /// (`LocalResumeReporting`),不挡会冒出一张播不了的卡。
    /// 不落盘:重启后没有会话在写,落盘反而会永久挡住同 id 的新内容。
    private var forgottenIDs: Set<String> = []
    /// 读盘失败的原因,由调用方决定是否提示;⛔ 不假装「没有记录」。
    private(set) var lastLoadFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 测试宿主用另一个文件名:单测跑在宿主 App 里、共享真实沙盒容器,同名会冲掉真实记录。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let filename = isTestHost ? "watch-progress-testhost.json" : "watch-progress.json"
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
    }

    // MARK: - 读

    /// nil = 从 0 开始(没有记录 / 已看完 / 标过已看)。
    /// 回退几秒(`Metrics.resumeRewind`)由播放层 `PlaybackRules.resumePosition` 做,不在这里。
    func resumeSeconds(forFileID id: String) -> Double? {
        guard let entry = entries()[id],
              case .inProgress(let seconds) = Self.state(of: entry) else { return nil }
        return seconds
    }

    /// UI 观看状态的唯一入口(「已看」角标、「已看到 mm:ss」、「继续观看」都从它推)。
    func watchState(forFileID id: String) -> WatchState {
        guard let entry = entries()[id] else { return .unwatched }
        return Self.state(of: entry)
    }

    /// 未看的不返回,调用方按「没查到 = 未看」处理。
    func watchStates(forFileIDs ids: [String]) -> [String: WatchState] {
        let all = entries()
        var result: [String: WatchState] = [:]
        for id in ids {
            guard let entry = all[id] else { continue }
            let state = Self.state(of: entry)
            guard state != .unwatched else { continue }
            result[id] = state
        }
        return result
    }

    /// 显式标记优先,否则按比例现算。`played == false` 时位置必为 0(`record` 写新位置会清掉标记)。
    /// 时长未知判不了看完,按看到一半处理(⛔ 不猜)。
    private static func state(of entry: Entry) -> WatchState {
        // 占位不是看过,只负责让续播区有张卡
        if entry.upNext == true { return .unwatched }
        if let played = entry.played { return played ? .watched : .unwatched }
        guard entry.positionSeconds > 0 else { return .unwatched }
        guard reachesFinished(position: entry.positionSeconds, duration: entry.durationSeconds) else {
            return .inProgress(seconds: entry.positionSeconds)
        }
        return .watched
    }

    /// 时长未知 / 为 0 时返回 false。
    private static func reachesFinished(position: Double, duration: Double?) -> Bool {
        guard let duration, duration > 0, position > 0 else { return false }
        return position / duration >= finishedThreshold
    }

    /// 诊断 / 测试观察用
    func snapshot() -> [String: Entry] { entries() }

    /// nil = 没有记录,或老记录没有快照
    func display(forFileID id: String) -> Display? {
        entries()[id]?.display
    }

    /// 「继续观看」的记录:看到一半的 + `upNext` 占位;按 `updatedAt` 倒序。
    func resumeEntries(sourceID: UUID) -> [ResumeRecord] {
        entries()
            .compactMap { key, entry -> ResumeRecord? in
                guard let display = entry.display, display.sourceID == sourceID else { return nil }
                if entry.upNext == true {
                    return ResumeRecord(
                        fileID: key,
                        positionSeconds: 0,
                        durationSeconds: entry.durationSeconds,
                        updatedAt: entry.updatedAt,
                        display: display,
                        isUpNext: true
                    )
                }
                guard case .inProgress(let seconds) = Self.state(of: entry) else { return nil }
                return ResumeRecord(
                    fileID: key,
                    positionSeconds: seconds,
                    durationSeconds: entry.durationSeconds,
                    updatedAt: entry.updatedAt,
                    display: display
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - 写

    /// 来源下全部带展示快照的记录(删除条目时用)。没有 `display` 的老记录界不出删除范围,⛔ 不猜。
    func storedRecords(sourceID: UUID) -> [StoredRecord] {
        entries().compactMap { key, entry -> StoredRecord? in
            guard let display = entry.display, display.sourceID == sourceID else { return nil }
            return StoredRecord(fileID: key, display: display)
        }
    }

    /// 记一条进度。
    ///
    /// - 位置 ≤ 0 删记录(从 0 开始不是进度),但显式已看与 `upNext` 占位不删。
    /// - 越过 `finishedThreshold` 就地落成已看 + 位置归 0(放库里保证读完 / 标完 / 播完状态一致)。
    /// - 没越过则把显式状态清成 nil:标过已看后又从头看,就是进行中。
    /// - `display` 与已知时长保留:展示与进度是两个写入方,后写的不能抹掉先写的。
    func record(fileID id: String, positionSeconds: Double, durationSeconds: Double?) throws {
        guard !forgottenIDs.contains(id) else { return }
        var current = entries()
        let existing = current[id]
        guard positionSeconds > 0 else {
            // 显式已看是用户的话;占位被 0 秒起播删掉的话续播卡会整张消失且回不来
            guard existing?.played != true, existing?.upNext != true else { return }
            guard current.removeValue(forKey: id) != nil else { return }
            try persist(current)
            return
        }
        let duration = durationSeconds ?? existing?.durationSeconds
        let finished = Self.reachesFinished(position: positionSeconds, duration: duration)
        current[id] = Entry(
            positionSeconds: finished ? 0 : positionSeconds,
            durationSeconds: duration,
            updatedAt: Date(),
            played: finished ? true : nil,
            upNext: nil,
            display: existing?.display
        )
        try persist(current)
    }

    /// 自然播完(`end-file(.eof)`)直接落成已看 + 位置 0,不靠比例:百度常拿不到时长,
    /// 比例恒判不出看完,那一集会卡在 99% 占住续播卡,「下一集」永远轮不到。
    ///
    /// 时长兜底用 `endedAt`:关窗还会再报一次进度(`PlayerViewModel.stop()`),没有时长的话
    /// `record` 会把已看翻回 99%。⛔ 已知时长优先,不拿终点覆盖。
    func markFinished(
        fileID id: String,
        display: Display?,
        endedAt positionSeconds: Double,
        durationSeconds: Double?
    ) throws {
        guard !forgottenIDs.contains(id) else { return }
        var current = entries()
        let existing = current[id]
        let duration = durationSeconds ?? existing?.durationSeconds
            ?? (positionSeconds > 0 ? positionSeconds : nil)
        current[id] = Entry(
            positionSeconds: 0,
            durationSeconds: duration,
            updatedAt: Date(),
            played: true,
            upNext: nil,
            display: existing?.display ?? display
        )
        try persist(current)
    }

    /// 起播时记展示快照,保留已有的位置与状态(位置随后由上报器写入)。
    ///
    /// 剧集(有集号)还没进度、也没看完时顺带记成 `upNext` 占位:点过播放就该留在「继续观看」里,
    /// 0 秒就关窗也一样(`record` 不删占位)。没有集号的(电影等)不占位,没看就不算在看。
    func rememberDisplay(fileID id: String, display: Display) throws {
        guard !forgottenIDs.contains(id) else { return }
        var current = entries()
        let existing = current[id]
        let isUntouched = existing?.played != true && (existing?.positionSeconds ?? 0) <= 0
        current[id] = Entry(
            positionSeconds: existing?.positionSeconds ?? 0,
            durationSeconds: existing?.durationSeconds,
            updatedAt: Date(),
            played: existing?.played,
            upNext: display.episodeNumber != nil && isUntouched ? true : existing?.upNext,
            display: display
        )
        try persist(current)
    }

    struct PlayedMark: Sendable, Equatable {
        let fileID: String
        /// 不覆盖已有快照;nil 用于记录一定在、只改状态的场合(如续播卡片)
        let display: Display?
    }

    /// 批量标已看 / 未看,只落一次盘(对齐 Emby `UserData.Played`)。
    ///
    /// - 已看:`played = true`、位置归 0;没有记录就新建。
    /// - 未看:`played = false`、位置归 0。⛔ 不能只靠位置 0 表达(那会删记录,变成「从没看过」);
    ///   没有记录时不做事。
    ///
    /// 正在播的那集标已看后,10 秒后的上报会把它带回进行中,这是如实的;要保持已看先停播。
    ///
    /// - Returns: 真正改动的条数
    @discardableResult
    func setPlayed(_ marks: [PlayedMark], played: Bool) throws -> Int {
        guard !marks.isEmpty else { return 0 }
        var current = entries()
        var changed = 0
        for mark in marks where !forgottenIDs.contains(mark.fileID) {
            let existing = current[mark.fileID]
            if played {
                // 已是已看则跳过,除非能补上缺的展示快照(删文件时要靠它按路径圈到)
                let alreadyWatched = existing?.played == true && existing?.positionSeconds == 0
                let canFillDisplay = existing?.display == nil && mark.display != nil
                guard !alreadyWatched || canFillDisplay else { continue }
                current[mark.fileID] = Entry(
                    positionSeconds: 0,
                    durationSeconds: existing?.durationSeconds,
                    updatedAt: Date(),
                    played: true,
                    upNext: nil,
                    display: existing?.display ?? mark.display
                )
                changed += 1
                continue
            }
            guard var entry = existing else { continue }
            guard entry.played != false || entry.positionSeconds > 0 else { continue }
            entry.played = false
            entry.positionSeconds = 0
            entry.upNext = nil
            entry.updatedAt = Date()
            current[mark.fileID] = entry
            changed += 1
        }
        guard changed > 0 else { return 0 }
        try persist(current)
        return changed
    }

    /// 写「下一集」占位(见 `Entry.upNext`)。已看过的、还有进度的不写(会把「已看到 12:34」抹成 0)。
    /// 旧占位不清:一部剧只出一张卡(`oneCardPerSeries` 取最近更新),新占位会顶掉它。
    ///
    /// - Returns: 写入的条数
    @discardableResult
    func setUpNext(_ marks: [PlayedMark]) throws -> Int {
        guard !marks.isEmpty else { return 0 }
        var current = entries()
        var changed = 0
        for mark in marks where !forgottenIDs.contains(mark.fileID) {
            let existing = current[mark.fileID]
            guard existing?.played != true, (existing?.positionSeconds ?? 0) <= 0 else { continue }
            current[mark.fileID] = Entry(
                positionSeconds: 0,
                durationSeconds: existing?.durationSeconds,
                updatedAt: Date(),
                played: nil,
                upNext: true,
                display: existing?.display ?? mark.display
            )
            changed += 1
        }
        guard changed > 0 else { return 0 }
        try persist(current)
        return changed
    }

    func remove(fileID id: String) throws {
        var current = entries()
        guard current.removeValue(forKey: id) != nil else { return }
        try persist(current)
    }

    /// 批量删,只落一次盘,不记 `forgottenIDs`(之后再看照常记)。用于「移出继续观看」、隐藏;
    /// 删网盘条目用 `forget(fileIDs:)`。写盘失败抛错、内存保持原样。
    ///
    /// - Returns: 真正删掉的条数
    @discardableResult
    func remove(fileIDs ids: [String]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var current = entries()
        var removed = 0
        for id in ids where current.removeValue(forKey: id) != nil {
            removed += 1
        }
        guard removed > 0 else { return 0 }
        try persist(current)
        return removed
    }

    /// 网盘条目被真删时用:删记录并在本次运行内拒绝再写(见 `forgottenIDs`)。
    /// ⛔ 隐藏不要用它(隐藏可恢复)。写盘失败抛错且不记已忘,否则重试永远写不进。
    @discardableResult
    func forget(fileIDs ids: [String]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let removed = try remove(fileIDs: ids)
        forgottenIDs.formUnion(ids)
        return removed
    }

    /// 网盘改名 / 挪位后更新 `Display.locator` 与 `fileName`(进度按 `fs_id` 存不会丢,
    /// 但卡片靠路径起播)。没有快照的老记录跳过。
    /// ⛔ 不抛错:网盘已改完,写盘失败记进 `lastLoadFailureDescription`。
    func relocate(fileID id: String, path: String, fileName: String) {
        var current = entries()
        guard var entry = current[id], var display = entry.display else { return }
        display.locator = path
        display.fileName = fileName
        entry.display = display
        current[id] = entry
        do {
            try persist(current)
        } catch {
            lastLoadFailureDescription = "更新续播快照失败:\(error)"
            Self.logger.error("续播快照更新失败 \(String(describing: error), privacy: .public)")
        }
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
            // 必须与 `persist` 的 `.iso8601` 对称,否则整份文件被判损坏
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([String: Entry].self, from: data)
        } catch {
            // ⛔ 不就地重置成空文件,先如实记下原因
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
        // 0600:「谁看了什么」属于隐私
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

extension WatchProgressStore.Display {

    /// 起播(`AppContainer.rememberResumeCard`)与手动标记已看都用它;标记时也要定位信息,
    /// 否则删网盘文件时 `BaiduPanWatchHistory` 按路径圈不到,留下死记录。
    init(item: SourceItem, file: BaiduPanFile) {
        self.init(
            sourceID: item.ref.sourceID,
            title: item.title,
            locator: file.path,
            fileName: file.name,
            cover: item.poster?.snapshot,
            episodeNumber: item.episodeNumber
        )
    }
}
