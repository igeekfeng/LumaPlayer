import Foundation

/// 百度网盘目录的**客户端排序**。
///
/// ## 为什么排序得自己做
///
/// 百度 `method=list` 的 `order` 只有 `name` / `time` / `size`,而且 `name` 是
/// **纯字符串序** —— 官方原话「排序按字符串处理,有剧集排序需求需自行开发」
/// (`docs/BAIDU_PAN_API.md` §2.2)。字符串序下 `10.mp4` 排在 `2.mp4` 前面,
/// 对「一集一集往下看」这件事是**倒着的**。
///
/// ⇒ 目录列回来之后,顺序由这里定。改排序**只重排已经取回的条目**,
/// ⛔ 不重新请求目录(应用配额见 `docs/BAIDU_PAN_API.md` §7)。
///
/// ## 默认为什么是「剧集顺序」
///
/// 「看剧都是从前往后看的」。所以默认按 **(季号, 集号)** 升序 ——
/// 目录名是剧名、文件名只是集号的存法(`琅琊榜/01.mp4`)也排得对;
/// 认不出集号的条目排在最后,按自然名。
enum BaiduPanSortOrder: String, CaseIterable, Identifiable, Sendable {
    /// 剧集顺序(**默认**):有集号的按 (季, 集) 升序,其余按自然名
    case episode
    /// 名称:原始文件名的**自然序**(`2.mp4` 在 `10.mp4` 前)
    case name
    /// 修改时间
    case modifiedDate
    /// 大小
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .episode: return "剧集顺序"
        case .name: return "名称"
        case .modifiedDate: return "修改时间"
        case .size: return "大小"
        }
    }

    /// 这一档的**自然方向**。换档时回到它(与 `LibrarySort.defaultAscending` 同一条纪律):
    /// 剧集 / 名称从小到大,时间 / 大小从新(大)到旧(小)。
    var defaultAscending: Bool {
        switch self {
        case .episode, .name: return true
        case .modifiedDate, .size: return false
        }
    }
}

extension BaiduPanSortOrder {

    /// 排一个目录的条目。**纯函数**:⛔ 不发请求、⛔ 不给缺失字段编值。
    ///
    /// - Parameters:
    ///   - items: 合成后的条目(进来时是百度返回的原始顺序)
    ///   - filesByID: 同一次目录读取的原始文件。**必须**传:名称档要原始文件名,
    ///     时间 / 大小档要 `server_mtime` / `size` —— 这些都不在 `SourceItem` 上。
    ///   - ascending: 方向。⚠️ **目录恒在前**,不受它影响;但**目录之间**的顺序跟随
    ///     它(倒序时季文件夹也从后往前,与 Finder 一致)。同理,「这一档没有值」
    ///     的条目(百度没给 `server_mtime` / `size`)恒排最后,也不受它影响。
    func apply(
        to items: [SourceItem],
        filesByID: [UInt64: BaiduPanFile],
        ascending: Bool
    ) -> [SourceItem] {
        items.sorted { lhs, rhs in
            // 目录恒在前 —— 与 Finder 一致:目录是「再往里走一步」,文件是「点开就播」。
            // 混在一起排,一部剧几十个条目里找东西会很费眼。
            // ⚠️ 它**不跟随 `ascending`**:把一屏目录倒过来没有任何意义。
            let lhsIsFolder = lhs.kind.isContainer
            let rhsIsFolder = rhs.kind.isContainer
            if lhsIsFolder != rhsIsFolder { return lhsIsFolder }

            // 「这一档没有值」的也恒在后,同样**不跟随 `ascending`**:
            // 把「不知道它多大 / 什么时候改的」倒到最前面是最糟的一种排法。
            let lhsHasValue = hasValue(lhs, filesByID: filesByID)
            let rhsHasValue = hasValue(rhs, filesByID: filesByID)
            if lhsHasValue != rhsHasValue { return lhsHasValue }

            let primary = compare(lhs, rhs, filesByID: filesByID)
            if primary != .orderedSame {
                return ascending ? primary == .orderedAscending : primary == .orderedDescending
            }
            // 主键相同(同一秒的 mtime / 同样大小)→ 用自然名;再相同 → 用 `fs_id`。
            // ⚠️ 兜底不是为了好看:排序算法**本身不保证稳定**,少了它同键条目的
            // 顺序会随数据规模漂移,测试也就不可复现。
            let secondary = compareName(lhs, rhs, filesByID: filesByID)
            if secondary != .orderedSame { return secondary == .orderedAscending }
            return Self.numericFileID(lhs) < Self.numericFileID(rhs)
        }
    }

    /// 这一档要用的值在不在场。
    ///
    /// - `episode` / `name` 恒在场(集号排不出来时另有「排在最后」的规则;名称永远有);
    /// - `modifiedDate` / `size` 要看百度有没有给 —— 没给就是不在场,
    ///   ⛔ 不当成 0 / 1970 去插进真实数据里。
    private func hasValue(_ item: SourceItem, filesByID: [UInt64: BaiduPanFile]) -> Bool {
        switch self {
        case .episode, .name: return true
        case .modifiedDate: return file(item, filesByID: filesByID)?.modifiedAt != nil
        case .size: return file(item, filesByID: filesByID)?.sizeBytes != nil
        }
    }

    // MARK: - 各档的比较

    private func compare(
        _ lhs: SourceItem,
        _ rhs: SourceItem,
        filesByID: [UInt64: BaiduPanFile]
    ) -> ComparisonResult {
        switch self {
        case .episode: return compareEpisode(lhs, rhs, filesByID: filesByID)
        case .name: return compareName(lhs, rhs, filesByID: filesByID)
        case .modifiedDate: return compareModifiedDate(lhs, rhs, filesByID: filesByID)
        case .size: return compareSize(lhs, rhs, filesByID: filesByID)
        }
    }

    /// 剧集顺序:有集号的在前、按 (季, 集) 升序;没有集号的在后、按自然名。
    private func compareEpisode(
        _ lhs: SourceItem,
        _ rhs: SourceItem,
        filesByID: [UInt64: BaiduPanFile]
    ) -> ComparisonResult {
        let lhsEpisode = lhs.episodeNumber
        let rhsEpisode = rhs.episodeNumber
        if (lhsEpisode == nil) != (rhsEpisode == nil) {
            // 认不出集号的(花絮、混进剧集目录的电影)排到后面,
            // ⛔ 不让它占「第 1 集」的位置。
            return lhsEpisode == nil ? .orderedDescending : .orderedAscending
        }
        guard let lhsEpisode, let rhsEpisode else {
            return compareName(lhs, rhs, filesByID: filesByID)
        }
        // 季号:未知季排在**已知季之后**。
        // ⚠️ 这里用 `Int.max` 而不是 0 —— 0 是 TMDB 的**特别篇**
        // (`docs/TMDB_API.md` §7),不是「不知道」的哨兵(模型层同理留 nil)。
        let lhsSeason = lhs.seasonNumber ?? Int.max
        let rhsSeason = rhs.seasonNumber ?? Int.max
        if lhsSeason != rhsSeason {
            return lhsSeason < rhsSeason ? .orderedAscending : .orderedDescending
        }
        if lhsEpisode != rhsEpisode {
            return lhsEpisode < rhsEpisode ? .orderedAscending : .orderedDescending
        }
        return compareName(lhs, rhs, filesByID: filesByID)
    }

    /// 名称:比**原始文件名**。
    ///
    /// ⚠️ 不是 `title` —— 剧集文件夹结构下 `title` 是剧名,整个目录每一张都一样,
    /// 拿它排等于没排(`SourceItem.episodeNumber` 的注释里那件事)。
    private func compareName(
        _ lhs: SourceItem,
        _ rhs: SourceItem,
        filesByID: [UInt64: BaiduPanFile]
    ) -> ComparisonResult {
        Self.compareNaturally(
            displayName(lhs, filesByID: filesByID),
            displayName(rhs, filesByID: filesByID)
        )
    }

    private func compareModifiedDate(
        _ lhs: SourceItem,
        _ rhs: SourceItem,
        filesByID: [UInt64: BaiduPanFile]
    ) -> ComparisonResult {
        Self.compareValues(
            file(lhs, filesByID: filesByID)?.modifiedAt,
            file(rhs, filesByID: filesByID)?.modifiedAt
        )
    }

    private func compareSize(
        _ lhs: SourceItem,
        _ rhs: SourceItem,
        filesByID: [UInt64: BaiduPanFile]
    ) -> ComparisonResult {
        Self.compareValues(
            file(lhs, filesByID: filesByID)?.sizeBytes,
            file(rhs, filesByID: filesByID)?.sizeBytes
        )
    }

    // MARK: - 取值

    /// 排序用的名字:优先原始文件名(它带着集号与发布信息),
    /// 取不到才退回 `title`(那是给界面看的)。
    private func displayName(_ item: SourceItem, filesByID: [UInt64: BaiduPanFile]) -> String {
        file(item, filesByID: filesByID)?.name ?? item.title
    }

    private func file(_ item: SourceItem, filesByID: [UInt64: BaiduPanFile]) -> BaiduPanFile? {
        guard let fsID = UInt64(item.ref.itemID) else { return nil }
        return filesByID[fsID]
    }

    private static func numericFileID(_ item: SourceItem) -> UInt64 {
        UInt64(item.ref.itemID) ?? 0
    }

    // MARK: - 通用比较

    /// 自然序:**数字段按数值比**(`2` < `10`,`第2季` < `第10季`),其余按 locale 比。
    ///
    /// ⚠️ locale **写死简中**,不用系统 locale:同一份目录在两台机器上要排出同一个顺序,
    /// 否则排序结果不可复现(测试也就测不出东西)。中文标题在简中 collation 下按拼音。
    private static func compareNaturally(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(
            rhs,
            options: [.numeric, .caseInsensitive, .widthInsensitive],
            locale: naturalSortLocale
        )
    }

    /// 比两个值的大小。⚠️ 「缺值排最后」那一路由 `hasValue` 在前面就拦掉了,
    /// 走不到这里 —— 这里的 `nil` 只可能是「两边都没有」,那就等于没差别。
    private static func compareValues<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        guard let lhs, let rhs else { return .orderedSame }
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static let naturalSortLocale = Locale(identifier: "zh_Hans_CN")
}

/// 网格的**观看状态筛选**。
///
/// ## 为什么这个能做、而且不花请求
///
/// 百度的列表接口没有任何「已看 / 未看」字段(`docs/BAIDU_PAN_API.md` §2),
/// 所以 Emby 那种按观看状态过滤看起来做不了。但客户端本来就有一份**本地续播库**
/// (`WatchProgressStore`)—— 卡片上的 ✓ 与「已看到 mm:ss」就是它画的。
/// 既然数据在手,筛选就是**纯过滤**,零请求、零额外状态。
///
/// ⚠️ 判据只在客户端成立:换台机器、重装 App 就没了(与「已看」本身同一局限)。
enum BaiduPanWatchFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case unwatched
    case watched

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .unwatched: return "未看"
        case .watched: return "已看"
        }
    }

    /// 菜单上的图标(与 `BaiduPanCard` 上那个 ✓ 同一套语义)
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .unwatched: return "circle"
        case .watched: return "checkmark.circle"
        }
    }
}
