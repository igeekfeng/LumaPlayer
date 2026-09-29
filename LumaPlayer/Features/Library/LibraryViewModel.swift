import Foundation

/// 媒体库排序项(参照 Emby Web 的排序菜单)。
///
/// `SortBy` 取值一律出自 API_CONTRACT.md 3.2 参数表(官方 4.1.1.0 核实 2026-09-23)。
/// 每项带一个「自然方向」:名称默认升序,日期 / 评分默认降序(新的、高的在前)。
enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case name
    case dateAdded
    case premiereDate
    case year
    case rating
    case datePlayed
    case runtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .dateAdded: return "加入日期"
        case .premiereDate: return "发行日期"
        case .year: return "年份"
        case .rating: return "评分"
        case .datePlayed: return "播放日期"
        case .runtime: return "时长"
        }
    }

    /// 次级键固定追加 `SortName`:主键相同(同年、同分)时顺序稳定,翻页不会重复或漏项。
    var sortBy: [String] {
        switch self {
        case .name: return ["SortName"]
        case .dateAdded: return ["DateCreated", "SortName"]
        case .premiereDate: return ["PremiereDate", "SortName"]
        case .year: return ["ProductionYear", "SortName"]
        case .rating: return ["CommunityRating", "SortName"]
        case .datePlayed: return ["DatePlayed", "SortName"]
        case .runtime: return ["Runtime", "SortName"]
        }
    }

    var defaultAscending: Bool {
        switch self {
        case .name, .runtime: return true
        case .dateAdded, .premiereDate, .year, .rating, .datePlayed: return false
        }
    }
}

/// 媒体库筛选(`Filters` 取值出自 API_CONTRACT.md 3.2,官方 4.1.1.0 核实)。
///
/// ⛔ 不提供「可续播」:`Filters=IsResumable` 在 4.7.11.0 上的行为未核实(Q28)。
enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case unplayed
    case played
    case favorite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .unplayed: return "未看"
        case .played: return "已看"
        case .favorite: return "收藏"
        }
    }

    var filters: [String] {
        switch self {
        case .all: return []
        case .unplayed: return ["IsUnplayed"]
        case .played: return ["IsPlayed"]
        case .favorite: return ["IsFavorite"]
        }
    }
}

/// 媒体库网格(分页)的 ViewModel(@MainActor + @Observable)。
///
/// 分页与 generation 的并发正确性在 `PagedItemList` 里,本类型只负责
/// 「按服务器 + 媒体库 + 排序 / 筛选构造查询」:查询参数一律取 `API_CONTRACT.md` 3.2 的
/// 参数表,不发明新参数。
@MainActor
@Observable
final class LibraryViewModel {
    private let container: AppContainer

    private(set) var list: PagedItemList?
    private var configuredKey: String?
    private var server: ServerProfile?
    private var view: EmbyView?
    private var refreshToken = 0

    var sort: LibrarySort = .name {
        didSet {
            guard sort != oldValue else { return }
            ascending = sort.defaultAscending
            reconfigure()
        }
    }
    var ascending = true {
        didSet { if ascending != oldValue { reconfigure() } }
    }
    var filter: LibraryFilter = .all {
        didSet { if filter != oldValue { reconfigure() } }
    }

    /// 标记已看 / 收藏失败的提示
    var userDataError: String?
    private(set) var updatingItemIDs: Set<String> = []

    init(container: AppContainer) {
        self.container = container
    }

    /// 按「服务器 + 媒体库 + 刷新计数」配置列表。
    ///
    /// key 没变就不重建 —— 否则 SwiftUI 每次重绘视图都会丢掉已加载的分页,
    /// 并向服务器重复发请求(服务器不是我们的,见项目 MEMORY.md 的低频纪律)。
    /// key 变了(换服务器 / 换媒体库 / 手动刷新 / 改排序筛选)才重建,旧请求由
    /// `PagedItemList` 取消。
    func configure(server: ServerProfile, view: EmbyView?, refreshToken: Int = 0) {
        self.server = server
        self.view = view
        self.refreshToken = refreshToken
        reconfigure()
    }

    private func reconfigure() {
        guard let server else { return }
        let key = [
            server.id.uuidString, view?.id ?? "", String(refreshToken),
            sort.rawValue, String(ascending), filter.rawValue,
        ].joined(separator: "|")
        guard configuredKey != key else { return }
        configuredKey = key

        let parentID = view?.id
        let collectionType = view?.collectionType
        let sort = self.sort
        let ascending = self.ascending
        let filter = self.filter
        let connection = container.connection(for: server)
        list = PagedItemList { startIndex, limit in
            let query = LibraryViewModel.makeQuery(
                parentID: parentID,
                collectionType: collectionType,
                sort: sort,
                ascending: ascending,
                filter: filter,
                startIndex: startIndex,
                limit: limit
            )
            let response = try await connection.items(query)
            return PagedFetchResult(items: response.items, totalRecordCount: response.totalRecordCount)
        }
        list?.reload()
    }

    // MARK: - 已看 / 收藏(API_CONTRACT.md 5.5 / 5.6)

    func togglePlayed(_ item: EmbyItem) {
        let target = !item.isPlayed
        write(item, failureVerb: target ? "标记为已看" : "标记为未看") { connection in
            try await connection.setPlayed(itemID: item.id, played: target)
        }
    }

    func toggleFavorite(_ item: EmbyItem) {
        let target = !item.isFavorite
        write(item, failureVerb: target ? "收藏" : "取消收藏") { connection in
            try await connection.setFavorite(itemID: item.id, favorite: target)
        }
    }

    private func write(
        _ item: EmbyItem,
        failureVerb: String,
        _ operation: @escaping @Sendable (ServerConnection) async throws -> EmbyUserData
    ) {
        guard let server, !updatingItemIDs.contains(item.id) else { return }
        updatingItemIDs.insert(item.id)
        let connection = container.connection(for: server)
        let list = self.list
        Task {
            defer { updatingItemIDs.remove(item.id) }
            do {
                let userData = try await operation(connection)
                // 列表换过(改了排序 / 筛选)就不回写旧列表;新列表本来就是服务端的新状态
                guard list === self.list else { return }
                list?.updateUserData(userData, forItemID: item.id)
            } catch let error as EmbyAPIError {
                guard error != .cancelled else { return }
                if error == .unauthorized { container.state.serverNeedingLogin = server }
                userDataError = "\(failureVerb)失败:\(error.userMessage)"
            } catch {
                userDataError = "\(failureVerb)失败,请稍后重试。"
            }
        }
    }

    /// 一页的查询条件(纯函数,便于测试;参数名全部出自 API_CONTRACT.md 3.2)。
    nonisolated static func makeQuery(
        parentID: String?,
        collectionType: String?,
        sort: LibrarySort,
        ascending: Bool,
        filter: LibraryFilter,
        startIndex: Int,
        limit: Int
    ) -> EmbyItemsQuery {
        var query = EmbyItemsQuery()
        query.parentID = parentID
        query.recursive = true
        query.includeItemTypes = includeItemTypes(forCollectionType: collectionType)
        query.sortBy = sort.sortBy
        // SortOrder 与 SortBy 一一对应(3.2);次级键 SortName 始终升序
        query.sortOrder = [ascending ? "Ascending" : "Descending"]
            + Array(repeating: "Ascending", count: sort.sortBy.count - 1)
        query.filters = filter.filters
        query.startIndex = startIndex
        query.limit = limit
        return query
    }

    /// 媒体库 → `IncludeItemTypes`。
    ///
    /// `CollectionType` 可能为 null(混合库,API_CONTRACT.md 3.2),此时退化为
    /// 「电影 + 剧集」两类:LumaPlayer 是视频播放器,把音乐/书籍混进海报网格
    /// 比少显示几个条目更糟。这个取舍尚未在混合库上验证过
    /// (docs/KNOWN_ISSUES.md Q14)。
    nonisolated static func includeItemTypes(forCollectionType collectionType: String?) -> [String] {
        switch collectionType {
        case "movies": return ["Movie"]
        case "tvshows": return ["Series"]
        default: return ["Movie", "Series"]
        }
    }
}
