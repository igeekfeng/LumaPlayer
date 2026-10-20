import Foundation
import os

/// 本地续播库(**百度来源唯一的进度与观看状态存储**)。
///
/// ## 为什么必须自己造一个
///
/// Emby 的「继续观看」与「已看」是**服务端**能力:进度与 `UserData.Played` 都写在
/// Emby 上,换设备也在。百度网盘**既没有播放进度上报接口,也没有任何播放状态接口**
/// (`docs/BAIDU_PAN_API.md` §2:只有授权 / 列表 / 元信息 / 播放流 / 删除 / 改名)——
/// 所以百度来源上「接着看」与「已看 / 未看」都只能记在本地。
/// ⛔ 这不是接线问题,是产品能力缺口。
///
/// 一份文件里装两件事:进度(`positionSeconds` + `durationSeconds`)与状态
/// (`played`)。它们本来就同生同灭 —— 删一条记录两边一起没,标记已看要清进度,
/// 拆成两个文件只会多一处不同步的机会。
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
    /// ⚠️ `display` 与 `played` 都是**后加**的可选字段。它们缺失时旧文件照常解码
    /// (合成的 `Codable` 对可选字段走 `decodeIfPresent`)——
    /// 升级不该把用户已有的进度判成损坏(§7 那条迁移纪律)。
    struct Entry: Codable, Sendable, Equatable {
        var positionSeconds: Double
        /// 已知总时长;未知为 nil
        var durationSeconds: Double?
        var updatedAt: Date
        /// 显式观看状态。`nil` = 没有显式状态(老记录),按比例现算;
        /// `true` = 已看,`false` = 用户手动标成未看。
        ///
        /// ## 为什么必须存下来,而不是每次按比例现算
        ///
        /// 比例只有在**知道总时长**时才成立,而百度列表不返回时长(要 `filemetas`
        /// 带 `dlink` 才有,`docs/BAIDU_PAN_API.md` §4)—— 没播过的条目根本算不出来;
        /// 而「标记已看」本身就是用户的口头结论,与比例无关。
        var played: Bool? = nil
        /// 「下一集」占位:这一条不是看过,而是**接下来该看的那一集**(Emby 的 NextUp)。
        ///
        /// ## 为什么需要一条「没进度」的记录
        ///
        /// 「继续观看」原来的唯一来源是「看到一半的集」。于是**看完一集整部剧就消失**
        /// (用户报的):第一集越过 90% 变成已看、位置归 0,下一集又没人看过 ——
        /// 库里再没有任何 in-progress 记录,卡片就没了。Emby 那边由服务端按
        /// 「第一集没看的」给出 NextUp,衔接是天然的。
        ///
        /// 所以这里补一条 `positionSeconds = 0` 的占位:它让续播区端出「下一集」,
        /// 起播位置仍是 0;一旦真的看了一点,`record` 就把它改回普通进度记录。
        var upNext: Bool? = nil
        /// 渲染续播卡片要的展示信息(标题 / 定位 / 封面)。
        /// ⛔ 可选:老记录没有它,照样能续播,只是不出现在「继续观看」区。
        var display: Display?
    }

    /// 一条记录对 UI 的三种状态(`watchState` 的返回)。
    ///
    /// ⚠️ 「看到一半」与「看完」是**互斥**的:看完的位置会归 0,不再续播。
    enum WatchState: Sendable, Equatable {
        /// 没有进度,也没标已看
        case unwatched
        /// 看到一半,`seconds` 是本地进度
        case inProgress(seconds: Double)
        case watched
    }

    /// 一条记录的**展示快照**。
    ///
    /// ## 为什么进度库里要存这些
    ///
    /// 「继续观看」要的是一张能看的卡片(标题 + 封面 + 已看到哪),而这些
    /// 在百度侧**不在进度里**:标题是文件名解析出来的,封面是同目录兄弟文件。
    /// 它们只在**播放那一刻**拿得到(浏览页刚合成过 `SourceItem`)。
    /// 所以播放时顺手记一份 —— ⛔ 而不是回头再列一遍网盘(配额见 §7)。
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
        /// 已看秒数。`isUpNext` 时为 0(那一条还没开始看)
        let positionSeconds: Double
        let durationSeconds: Double?
        let updatedAt: Date
        let display: Display
        /// 这一条是「下一集该看」的占位(不是看到一半)—— UI 据此报「下一集」
        /// 而不是「已看到 00:00」,也不画进度条。
        var isUpNext: Bool = false
    }

    /// 一条**存档**记录(`storedRecords` 的返回):不管还续不续播。
    ///
    /// ## 为什么不能拿 `ResumeRecord` 代替
    ///
    /// `ResumeRecord` 是**续播语义**:位置 > 0、没看完、带展示快照的才给。
    /// 删除一个网盘条目时要清的是**它名下的全部记录** —— 已看完的那几集、
    /// 位置还是 0 的那几条也都在里面。只按续播语义找会漏掉它们,留下指向
    /// 已不存在文件的死记录(它们不占卡片,但会一直躺在库里)。
    ///
    /// ⚠️ 只留删除要用的两格:`fileID` 是要删的键,`display` 给出定位信息
    /// (`locator` / 标题)。进度数值这里用不上,⛔ 不为了「看起来完整」多存一份。
    struct StoredRecord: Sendable, Equatable {
        /// 来源内 id(百度:`fs_id` 字符串)
        let fileID: String
        let display: Display
    }

    /// 视为「已看完」的比例:到这里就落成 `played = true`、位置归 0。
    ///
    /// 与 Emby 服务端的 `MaxResumePct`(默认 90%)对齐 —— 那边的「已看」也是过了
    /// 这个比例就不再续播。低于它的进度原样留着,状态是「看到一半」。
    static let finishedThreshold: Double = 0.90

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "watch-progress")

    private let fileURL: URL
    private var loaded: [String: Entry]?
    /// 本次运行内已经删掉的 id。写入路径据此拒绝「把记录写回来」。
    ///
    /// ## 为什么需要它
    ///
    /// 删的若正是**正在播**的那一条,播放器的进度上报器每 10 秒还会写一次进度
    /// (`LocalResumeReporting`)—— 刚清掉的记录会被重新写回去,「继续观看」里
    /// 又冒出一张点开就播不了的卡。删除不可恢复,所以这个 id 在本进程内
    /// 就不该再有记录。
    ///
    /// ⚠️ 不落盘:重启之后没有播放会话在写它;而 `fs_id` 是网盘分配的唯一 id,
    /// 不会分给另一条文件。落盘反而会在「同一个 id 后来又真有了内容」时永久挡住它。
    private var forgottenIDs: Set<String> = []
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
    /// - Returns: 需要续播的位置;`nil` = 没有记录、已看完,或标过已看,
    ///   调用方从 0 开始。
    ///   ⚠️ 不在这里做 `Metrics.resumeRewind` 的回退 —— 那是播放层的规则
    ///   (`PlaybackRules.resumePosition`),与 Emby 来源走同一个函数。
    func resumeSeconds(forFileID id: String) -> Double? {
        guard let entry = entries()[id],
              case .inProgress(let seconds) = Self.state(of: entry) else { return nil }
        return seconds
    }

    /// 这一条的观看状态 —— **UI 的唯一入口**(「已看」角标、「已看到 mm:ss」、
    /// 「继续观看」都从它推)。
    func watchState(forFileID id: String) -> WatchState {
        guard let entry = entries()[id] else { return .unwatched }
        return Self.state(of: entry)
    }

    /// 批量读状态。**未看的不返回**(调用方按「没查到 = 未看」处理):
    /// 一屏几十张卡,逐张塞一个 `.unwatched` 只是让调用方再过滤一遍。
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

    /// 一条记录的状态。**显式标记优先**,没有标记才按比例现算。
    ///
    /// ⚠️ `played == false` 直接是未看,不看位置:标记那一刻位置已经归 0,而
    /// `record` 一旦写进新位置就会把显式标记清成 `nil`(回到自动判定)——
    /// 所以「显式未看 + 位置 > 0」这个组合不会出现。
    ///
    /// ⚠️ 时长未知时**判不了**看完,按「看到一半」处理(⛔ 不猜):宁可多留一张卡,
    /// 也不能因为缺时长就把看到一半的判成看完。
    private static func state(of entry: Entry) -> WatchState {
        // 「下一集」占位不是看过:✓ 与「已看到 mm:ss」都不该因为它出现,
        // 它只负责让续播区有一张卡(见 `Entry.upNext`)。
        if entry.upNext == true { return .unwatched }
        if let played = entry.played { return played ? .watched : .unwatched }
        guard entry.positionSeconds > 0 else { return .unwatched }
        guard reachesFinished(position: entry.positionSeconds, duration: entry.durationSeconds) else {
            return .inProgress(seconds: entry.positionSeconds)
        }
        return .watched
    }

    /// 位置是否已经越过「已看完」这一档(时长未知 / 为 0 时判不了,返回 false)。
    private static func reachesFinished(position: Double, duration: Double?) -> Bool {
        guard let duration, duration > 0, position > 0 else { return false }
        return position / duration >= finishedThreshold
    }

    /// 全部记录(诊断 / 测试观察用)
    func snapshot() -> [String: Entry] { entries() }

    /// 某个来源下**有进度**的续播记录(UI 渲染「继续观看」用)。
    ///
    /// 两条进:状态是「看到一半」的,以及标了 `upNext` 的「下一集」占位
    /// (位置 0,`isUpNext = true`)。其余(已看完 / 标过已看 / 从没看过)都不占卡,
    /// 与 `resumeSeconds` 同一把尺子,否则看完的集会一直占着一张卡。
    /// 按 `updatedAt` 倒序 —— 最近看的排前面。
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

    /// 某个来源下**全部**带展示快照的记录,不管还续不续播(删除条目时用)。
    ///
    /// 与 `resumeEntries` 的差别只在于**不过滤**:位置 0 的、已经看完的都留着。
    /// `display` 仍然必需 —— 没有展示快照的老记录没有 `locator`,判断不了
    /// 「这条属于哪个文件 / 哪部剧」,连删除的范围都界不出来(⛔ 不猜)。
    func storedRecords(sourceID: UUID) -> [StoredRecord] {
        entries().compactMap { key, entry -> StoredRecord? in
            guard let display = entry.display, display.sourceID == sourceID else { return nil }
            return StoredRecord(fileID: key, display: display)
        }
    }

    /// 记一条进度。位置为 0 或负值时**删掉**这条记录 ——
    /// 「从 0 开始看」不是一条进度,留着会让下次续播读到 0。
    ///
    /// ## 越过 90% 就地落成「已看」
    ///
    /// 与 Emby 服务端同一个动作:进度过了 `finishedThreshold` 就把 `played` 置 true、
    /// 位置归 0 —— 于是它同时退出续播与「继续观看」,并显示 ✓。这一步放在库里
    /// 而不是 UI 里,是因为**读完 / 标完 / 播完**三条路必须得到同一个状态。
    ///
    /// ⚠️ 没越过阈值的上报会把显式状态清成 `nil`(回到自动判定):用户标过已看
    /// 之后又从头看起,那就是「进行中」;⛔ 不保留一个已被事实推翻的标记。
    ///
    /// ⚠️ `display` 保留:进度与展示信息是**两个写入方**
    /// (上报器写位置、播放页 / 标记动作写展示),后写的不能把先写的抹掉。
    /// 时长同理:这一次没带(`nil`)时的旧值留着,⛔ 不把已知时长抹成未知。
    func record(fileID id: String, positionSeconds: Double, durationSeconds: Double?) throws {
        // 这条已经被删掉了(网盘里的文件不在,见 `forgottenIDs`)——
        // 正在播的那一次会话还在往下报,不能让它把记录写回来。
        guard !forgottenIDs.contains(id) else { return }
        var current = entries()
        let existing = current[id]
        guard positionSeconds > 0 else {
            // 「从 0 开始看」不是一条进度,删掉它 —— 但**显式标过已看的不删**:
            // 那是用户说的话,不该被一次 0 秒的起播抹掉。
            guard existing?.played != true else { return }
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
            // 真看过了:占位使命结束,这一条变成(或继续是)普通进度记录
            upNext: nil,
            display: existing?.display
        )
        try persist(current)
    }

    /// 记一条展示快照(播放那一刻从 `SourceItem` 提取)。
    ///
    /// ⚠️ 与 `record` 对称:保留已有的位置 —— 起播时先记展示(此刻位置还是 0),
    /// 上报器随后才把位置写进来。两者都改同一份文件,由 actor 串行化,⛔ 不竞态。
    func rememberDisplay(fileID id: String, display: Display) throws {
        guard !forgottenIDs.contains(id) else { return }
        var current = entries()
        let existing = current[id]
        current[id] = Entry(
            positionSeconds: existing?.positionSeconds ?? 0,
            durationSeconds: existing?.durationSeconds,
            updatedAt: Date(),
            played: existing?.played,
            upNext: existing?.upNext,
            display: display
        )
        try persist(current)
    }

    /// 一次「标记」的输入:改哪一条,以及顺手能补上的展示快照。
    struct PlayedMark: Sendable, Equatable {
        let fileID: String
        /// 展示快照(标题 / 定位 / 封面)。**已经有的记录不会被它覆盖**;
        /// `nil` 用于「记录一定在、只是改状态」的场合(如续播卡片)。
        let display: Display?
    }

    /// 把一批记录标成已看 / 未看,**只落一次盘**。
    ///
    /// ## 语义(与 Emby 的 `UserData.Played` 对齐)
    ///
    /// - **已看** → `played = true`、位置归 0。位置归零有两个作用:不再续播
    ///   (`resumeSeconds` 直接 nil),这一条也不再占「继续观看」的卡。
    ///   没有记录时**新建一条** —— 状态得存下来,而它和进度是同一份文件。
    /// - **未看** → `played = false`、位置归 0。这一步⛔ 不能只靠「位置 0」表达:
    ///   位置 0 的 `record` 会删记录,删掉之后这一条回到「从没看过」——
    ///   与「用户明确说了未看」是两件事。没有记录时什么都不做(本来就是未看)。
    ///
    /// ⚠️ 标已看时若这一集**正在播**,那场会话 10 秒后还会报一次进度
    /// (`LocalResumeReporting`),`record` 会把它带回「进行中」—— 这是如实的
    /// (你确实还在看),不是状态丢失。要它保持已看,先停播再标。
    ///
    /// - Returns: 真正改动的条数(已经是该状态的、被删过的、以及「没有记录 + 标未看」不计)。
    @discardableResult
    func setPlayed(_ marks: [PlayedMark], played: Bool) throws -> Int {
        guard !marks.isEmpty else { return 0 }
        var current = entries()
        var changed = 0
        for mark in marks where !forgottenIDs.contains(mark.fileID) {
            let existing = current[mark.fileID]
            if played {
                // 已经是「已看 + 位置 0」就不再写一次;唯一例外是这条记录还缺
                // 展示快照(标记时能补),补上它才谈得上「删文件时按路径圈得到」。
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
            // 没有记录 = 本来就是未看,不必为它写一条空记录。
            // 已经有 `played = false` 且没有位置时也是同一个状态,不算改动。
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

    /// 把「接下来该看的那一集」写成续播区的占位(Emby 的 NextUp 对位物)。
    ///
    /// ## 为什么必须有这一步
    ///
    /// 看完一集之后,这一集变成「已看 + 位置 0」,而下一集谁也没播过 ——
    /// 库里没有任何 in-progress 记录,整部剧就从「继续观看」里消失了(用户报的)。
    /// 补一条位置 0 的占位,卡片才衔接得上;起播仍是 0 秒,看过一点后由
    /// `record` 改回普通进度。
    ///
    /// ⚠️ **已经看过的不写**:那是事实,不能被一条占位盖掉。
    /// ⚠️ **还有进度的也不写**:那一集本来就在续播区里躺着,写占位会把「已看到 12:34」
    /// 抹成 0 秒 —— 用户看起来像进度丢了。
    ///
    /// ⚠️ 旧占位不在这里清:一部剧只出一张卡(`oneCardPerSeries` 取最近更新的),
    /// 新占位一写就顶掉了;留在库里的旧占位既不出卡也不算看过,无害。
    ///
    /// - Returns: 写入的条数(已看过的、有进度的、被删过的都不计)。
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

    /// 一次性删掉多条记录,**只落一次盘**(不记「已忘」,之后写还会生效)。
    ///
    /// 用途是「移出继续观看」:那是**用户主动弃掉进度**,不是内容没了 ——
    /// 他之后再点开这一集看,进度当然要重新记下来。
    /// ⚠️ 删网盘条目请用 `forget(fileIDs:)`:那边要挡住正在播的会话把记录写回来。
    ///
    /// ⚠️ 写盘失败**抛错**,内存快照保持原样。调用方据此如实报错,
    /// ⛔ 不假装已经清干净。
    ///
    /// - Returns: 真正删掉的条数(不在库里 / 已被删过的 id 不计)。
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

    /// 一次性清掉多条记录,并在本次运行内**拒绝**再写它们。
    ///
    /// 用于「网盘里的条目被**真删**」:文件已经不在网盘,而删除不可恢复。
    /// 与 `remove(fileIDs:)` 的唯一差别就是这里多记一道 `forgottenIDs` ——
    /// 正在播的那一条每 10 秒还会报一次进度(`LocalResumeReporting`),
    /// 不挡就会把刚清掉的记录写回去,「继续观看」里又冒出一张点开就播不了的卡。
    ///
    /// ⚠️ 「隐藏」**不要**用它:隐藏可恢复,恢复之后这一项还要能重新记进度,
    /// 用 `remove(fileIDs:)`。
    ///
    /// ⚠️ 写盘失败**抛错**,且**不**记「已忘」(否则重试永远写不进去);
    /// 调用方据此如实说「文件已处理,但记录没清掉」。
    @discardableResult
    func forget(fileIDs ids: [String]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let removed = try remove(fileIDs: ids)
        forgottenIDs.formUnion(ids)
        return removed
    }

    /// 文件在网盘上被改名 / 挪位之后,更新**展示快照**里的定位信息。
    ///
    /// ## 为什么只改这两个字段
    ///
    /// 进度本身按 `fs_id` 存,改名后它照样对得上(**不会丢**);会失效的是
    /// `Display.locator`(路径)与 `Display.fileName` —— 续播卡片靠它们重新起播。
    /// 不更新的后果是:卡片还在「继续观看」里,点下去却定位不到文件。
    ///
    /// ⚠️ 没有展示快照的老记录直接跳过:它本来就没有定位信息可更新。
    ///
    /// ⛔ 不抛错:网盘那边已经改完了,本地快照写不进去不该推翻这个事实。
    /// 写盘失败记进 `lastLoadFailureDescription`(⛔ 不静默吞,只是不打断流程)。
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

extension WatchProgressStore.Display {

    /// 从「浏览页那一刻的条目 + 原始文件」折出展示快照。
    ///
    /// ⚠️ 两个写入方都用它:**起播**(`AppContainer.rememberResumeCard`)与
    /// **手动标记已看**。标记时并没有播放,但记录同样需要定位信息,否则
    /// 删网盘文件时按路径圈不到它(`BaiduPanWatchHistory`),会留一条死记录。
    init(item: SourceItem, file: BaiduPanFile) {
        self.init(
            sourceID: item.ref.sourceID,
            title: item.title,
            locator: file.path,
            fileName: file.name,
            cover: item.poster?.snapshot,
            // 集号:一部剧的续播卡片只出一张,靠它说清接着看的是第几集
            episodeNumber: item.episodeNumber
        )
    }
}
