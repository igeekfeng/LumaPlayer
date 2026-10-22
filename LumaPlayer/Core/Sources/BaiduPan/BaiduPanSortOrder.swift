import Foundation

/// 百度目录的客户端排序。百度 `list` 的 `name` 排序是纯字符串序(`10.mp4` 在 `2.mp4` 前,
/// `docs/BAIDU_PAN_API.md` §2.2),所以顺序由这里定。
/// 改排序只重排已取回的条目,⛔ 不重新请求目录(配额,`docs/BAIDU_PAN_API.md` §7)。
enum BaiduPanSortOrder: String, CaseIterable, Identifiable, Sendable {
    /// 默认:有集号的按 (季, 集) 升序,其余按自然名排最后
    case episode
    /// 原始文件名的自然序(`2.mp4` 在 `10.mp4` 前)
    case name
    case modifiedDate
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

    /// 换档时回到的默认方向(同 `LibrarySort.defaultAscending`)
    var defaultAscending: Bool {
        switch self {
        case .episode, .name: return true
        case .modifiedDate, .size: return false
        }
    }
}

extension BaiduPanSortOrder {

    /// 纯函数,⛔ 不给缺失字段编值。
    ///
    /// - Parameters:
    ///   - filesByID: 同一次目录读取的原始文件;原始文件名、`server_mtime`、`size` 不在 `SourceItem` 上。
    ///   - ascending: 目录恒在前、缺值条目恒在后,都不受它影响;目录之间的顺序跟随它(同 Finder)。
    func apply(
        to items: [SourceItem],
        filesByID: [UInt64: BaiduPanFile],
        ascending: Bool
    ) -> [SourceItem] {
        items.sorted { lhs, rhs in
            let lhsIsFolder = lhs.kind.isContainer
            let rhsIsFolder = rhs.kind.isContainer
            if lhsIsFolder != rhsIsFolder { return lhsIsFolder }

            let lhsHasValue = hasValue(lhs, filesByID: filesByID)
            let rhsHasValue = hasValue(rhs, filesByID: filesByID)
            if lhsHasValue != rhsHasValue { return lhsHasValue }

            let primary = compare(lhs, rhs, filesByID: filesByID)
            if primary != .orderedSame {
                return ascending ? primary == .orderedAscending : primary == .orderedDescending
            }
            // 主键相同 → 自然名 → `fs_id`。排序不稳定,少了兜底同键条目顺序会漂移。
            let secondary = compareName(lhs, rhs, filesByID: filesByID)
            if secondary != .orderedSame { return secondary == .orderedAscending }
            return Self.numericFileID(lhs) < Self.numericFileID(rhs)
        }
    }

    /// 百度没给 `server_mtime` / `size` 就是不在场,⛔ 不当成 0 / 1970。
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

    private func compareEpisode(
        _ lhs: SourceItem,
        _ rhs: SourceItem,
        filesByID: [UInt64: BaiduPanFile]
    ) -> ComparisonResult {
        let lhsEpisode = lhs.episodeNumber
        let rhsEpisode = rhs.episodeNumber
        if (lhsEpisode == nil) != (rhsEpisode == nil) {
            // 认不出集号的(花絮、混进来的电影)排后面
            return lhsEpisode == nil ? .orderedDescending : .orderedAscending
        }
        guard let lhsEpisode, let rhsEpisode else {
            return compareName(lhs, rhs, filesByID: filesByID)
        }
        // 未知季排已知季之后;用 `Int.max` 不用 0:0 是特别篇(`docs/TMDB_API.md` §7)
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

    /// 比原始文件名,不比 `title`:剧集目录下 `title` 都是剧名,全一样。
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

    /// 数字段按数值比(`第2季` < `第10季`)。locale 写死简中(按拼音),不用系统 locale,保证跨机器可复现。
    private static func compareNaturally(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(
            rhs,
            options: [.numeric, .caseInsensitive, .widthInsensitive],
            locale: naturalSortLocale
        )
    }

    /// 单边缺值已由 `hasValue` 拦掉,这里的 nil 只会是两边都没有。
    private static func compareValues<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        guard let lhs, let rhs else { return .orderedSame }
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static let naturalSortLocale = Locale(identifier: "zh_Hans_CN")
}

/// 网格的观看状态筛选。百度没有已看字段,判据来自本地续播库(`WatchProgressStore`),纯过滤、零请求;
/// 换机器 / 重装就没了。
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

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .unwatched: return "circle"
        case .watched: return "checkmark.circle"
        }
    }
}
