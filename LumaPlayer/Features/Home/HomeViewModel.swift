import Foundation

/// 首页:我的媒体 / 继续观看 / 每个媒体库的「最新」,外加顶部 hero 的随机推荐池。
/// ⛔ 不做跨剧集的「下一集」行(PITFALLS.md Q31)。
///
/// 请求克制(别回退):
/// - 先显示旧数据:每行没内容时先读本地响应缓存(过期 / 作废的也用,`ServerConnection.cached…`),
///   再照常取新的(fresh 窗口内零网络),回来原地替换;
/// - 返回首页不重新加载,只在 ⌘R、缓存被作废(写操作 / 播放)、超过 fresh 窗口或有分区失败时才加载(`appear`);
/// - 「最新」行滚到才请求(`latestRowAppeared`),屏幕外的只读本地缓存;
/// - 顶栏加载线只为「还空着、在等数据」的行与用户主动刷新亮,静默刷新不亮,也从不挡操作。
///
/// 各分区独立加载、独立状态,一个失败不影响另一个;都带 generation 检查,丢弃切走的服务器的迟到响应。
/// 状态按服务器分开存:切回来直接显示上次内容、后台原地刷新,不回退到 loading,不串台。
@MainActor
@Observable
final class HomeViewModel {
    /// 不是设计 token,与布局无关。
    static let sectionLimit = 20

    /// 远多于轮播张数:给「必须带背景图」的筛选留余量,`Movie` 常常只有竖版海报。
    static let recommendationPoolLimit = 20

    /// 每张都要一张 1920 宽背景图,张数越多首屏请求越多。
    static let heroCarouselLimit = 5

    /// 显示「最新」的媒体库类型。音乐 / 有声书 / 直播是非目标;`CollectionType` 为 null 的混合库照常显示。
    static let latestCollectionTypes: Set<String?> = [nil, "movies", "tvshows", "homevideos", "musicvideos", "mixed"]

    private let container: AppContainer

    /// 每行一个独立的 `@Observable` 对象:别的行到数据时不会让它(及整个首页)重新求值。
    @MainActor
    @Observable
    final class Row<Value: Sendable> {
        private(set) var state: LoadState<Value> = .idle

        /// 这一轮(generation)已发过取数。「最新」行据此保证每轮最多请求一次
        @ObservationIgnored fileprivate var requestedGeneration: Int?

        var hasContent: Bool {
            if case .loaded = state { return true }
            return false
        }

        var isIdle: Bool {
            if case .idle = state { return true }
            return false
        }

        var hasFailed: Bool {
            if case .failed = state { return true }
            return false
        }

        /// 已有内容保持不动;其余进入加载态。不变时不写:写 `@Observable` 属性即通知,哪怕值没变
        func markLoading() {
            if case .loaded = state { return }
            if case .loading = state { return }
            state = .loading
        }

        /// 成功一律替换;失败时若已有内容则保留(后台刷新失败不把好好的一行换成错误卡片)
        func receive(_ new: LoadState<Value>) {
            if case .failed = new, case .loaded = state { return }
            state = new
        }

        /// 直接覆盖(乐观更新、回滚、播放后的静默校正)
        func replace(with new: LoadState<Value>) {
            state = new
        }
    }

    enum HeroPick: Equatable {
        /// 决定它的行还在加载:放骨架
        case pending
        /// 不画 hero
        case none
        /// 只有一张时轮播退化成静默的单张(`HomeHeroCarousel`)
        case items([EmbyItem])
    }

    /// 一台服务器的首页各分区

    @MainActor
    @Observable
    final class Sections {
        /// 「我的媒体」,来自服务器、不写死(DesignTokens.swift「界面规则」)。它回来后才建「最新」行
        let views = Row<[EmbyView]>()
        let resume = Row<[EmbyItem]>()
        /// hero 候选池。⛔ 不驱动任何货架,只有 hero 读。
        let recommended = Row<[EmbyItem]>()
        /// 键是 View 的 Id。只在库的集合变了时整体替换,行对象跨刷新复用
        private(set) var latest: [String: Row<[EmbyItem]>] = [:]

        /// 当前在屏幕上(含 `LazyVStack` 提前建好的)的「最新」行
        @ObservationIgnored fileprivate var visibleLatestIDs: Set<String> = []

        fileprivate func setLatest(_ rows: [String: Row<[EmbyItem]>]) {
            guard Set(rows.keys) != Set(latest.keys) else { return }
            latest = rows
        }

        fileprivate var hasFailure: Bool {
            views.hasFailed || resume.hasFailed || latest.values.contains { $0.hasFailed }
        }
    }

    /// 键是 `ServerProfile.id`,只增不删(服务器很少)。
    /// 不参与观察:`Sections` 建出后不再替换,所以 `sections(for:)` 可在视图求值时按需建对象。
    @ObservationIgnored private var sectionsByServer: [UUID: Sections] = [:]

    /// 上一次整页加载时的情况,`appear` 据此判断要不要再加载
    private struct LoadRecord {
        let refreshToken: Int
        let cacheEpoch: Int
        let date: Date
    }

    @ObservationIgnored private var loadRecords: [UUID: LoadRecord] = [:]

    /// 菜单里的「移出继续观看」据此禁用
    private(set) var updatingResumeIDs: Set<String> = []
    /// 写操作失败必须让用户知道,不能静默回滚
    var resumeActionError: String?
    var seriesPlayError: String?
    /// hero 播放按钮据此转圈、防连点
    private(set) var resolvingSeriesID: String?

    private var generation = 0
    private var tasks: [Task<Void, Never>] = []

    /// 只统计「行还空着在等数据」与用户主动刷新的请求;静默刷新、写操作不计。
    private var inFlight = 0
    /// 顶栏加载线据此显示。⛔ 不要拿它挡操作:请求过程中页面照常可点。
    private(set) var isLoading = false

    init(container: AppContainer) {
        self.container = container
    }

    /// 同一台服务器始终返回同一个对象;没加载过就是全 `.idle`。
    func sections(for serverID: UUID) -> Sections {
        if let sections = sectionsByServer[serverID] { return sections }
        let sections = Sections()
        sectionsByServer[serverID] = sections
        return sections
    }

    /// 首页出现(含从别的页面返回、切回这台服务器)。只在需要时加载:
    /// - 第一次;
    /// - `refreshToken` 变了(⌘R、重新登录):算用户主动刷新,顶栏亮加载线;
    /// - 缓存被作废(写操作 / 播放上报让 epoch 变了)、距上次超过 fresh 窗口、或有分区失败:静默加载。
    /// 其余直接用内存里的内容,零请求。
    func appear(server: ServerProfile, refreshToken: Int) async {
        let epoch = await container.responseCache.currentEpoch(serverID: server.id)
        guard !Task.isCancelled else { return }
        let record = loadRecords[server.id]
        if let record,
           record.refreshToken == refreshToken,
           record.cacheEpoch == epoch,
           Date().timeIntervalSince(record.date) < EmbyResponseCache.freshWindow,
           !sections(for: server.id).hasFailure {
            return
        }
        loadRecords[server.id] = LoadRecord(refreshToken: refreshToken, cacheEpoch: epoch, date: Date())
        let userInitiated = record.map { $0.refreshToken != refreshToken } ?? false
        load(server: server, userInitiated: userInitiated)
    }

    /// 整页加载:媒体库列表、继续观看、推荐池三路并行;「最新」等媒体库列表回来再建行(见 `prepareLatest`)。
    /// `userInitiated`(⌘R / 重试)时有内容的行刷新也亮加载线,并换一批推荐。
    func load(server: ServerProfile, userInitiated: Bool = false) {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        generation += 1
        let sections = self.sections(for: server.id)
        let connection = container.connection(for: server)
        // @Sendable 闭包里不能读 MainActor 静态属性
        let limit = Self.sectionLimit
        fill(
            sections.views,
            showsProgress: userInitiated,
            cached: { await connection.cachedUserViews() },
            fetch: { try await connection.userViews() }
        ) { [weak self] new in
            guard let self else { return }
            sections.views.receive(new)
            // 刷新失败时用保留的旧列表照常建「最新」行
            prepareLatest(views: sections.views.state.value ?? [], sections: sections, connection: connection)
        }
        fill(
            sections.resume,
            showsProgress: userInitiated,
            cached: { await connection.cachedResume(limit: limit) },
            fetch: { try await connection.resume(limit: limit).items }
        ) { new in
            sections.resume.receive(new)
        }
        if container.homeAppearance.showsHeroRecommendations {
            // 推荐是随机的,没有「过时」一说:已有一批时只在用户主动刷新时换,免得静默刷新时 hero 在眼前换人
            if userInitiated || !sections.recommended.hasContent {
                loadRecommendations(sections: sections, connection: connection, showsProgress: userInitiated)
            }
        } else {
            // 关掉了就不发请求,行置空
            sections.recommended.replace(with: .loaded([]))
        }
    }

    /// 只在推荐开关打开时调用(由调用方判断)。
    private func loadRecommendations(sections: Sections, connection: ServerConnection, showsProgress: Bool) {
        let poolLimit = Self.recommendationPoolLimit
        fill(
            sections.recommended,
            showsProgress: showsProgress,
            cached: { await connection.cachedRecommendations(limit: poolLimit) },
            fetch: { try await connection.recommendations(limit: poolLimit) }
        ) { [weak self] new in
            // 在途时开关被关:丢弃,免得下次打开露出过时的一批
            guard let self, self.container.homeAppearance.showsHeroRecommendations else { return }
            sections.recommended.receive(new)
        }
    }

    /// 设置「显示首页推荐」变了。⛔ 只动推荐这一路,不重新加载整页。
    func recommendationsPreferenceChanged(server: ServerProfile) {
        let sections = self.sections(for: server.id)
        guard container.homeAppearance.showsHeroRecommendations else {
            sections.recommended.replace(with: .loaded([]))
            return
        }
        // 显式置 `.loading` 占住 hero 高度:`markLoading()` 见 `.loaded([])` 不动,
        // 退路会先显示一张、推荐回来又换掉,首屏会跳
        sections.recommended.replace(with: .loading)
        loadRecommendations(sections: sections, connection: container.connection(for: server), showsProgress: false)
    }

    // MARK: - 最新

    /// 每个视频类媒体库一行,已不存在的库丢掉。
    ///
    /// ⛔ 不在这里给所有行发网络请求:只给屏幕上的行发,其余等滚到(`latestRowAppeared`)。
    /// 屏幕外的空行先读本地缓存(只读磁盘)填上,hero 退路也用得上。
    /// 加载成功但为空的行界面上不占位、不会「出现」,所以每轮也直接重取。
    private func prepareLatest(views: [EmbyView], sections: Sections, connection: ServerConnection) {
        let latestViews = Self.latestViews(in: views)
        let rows = Dictionary(uniqueKeysWithValues: latestViews.map { view in
            (view.id, sections.latest[view.id] ?? Row())
        })
        sections.setLatest(rows)

        let unfilled = latestViews.compactMap { view in rows[view.id].map { (view.id, $0) } }
            .filter { $0.1.isIdle }
        if !unfilled.isEmpty {
            let limit = Self.sectionLimit
            let myGeneration = generation
            tasks.append(Task { [weak self] in
                for (parentID, row) in unfilled {
                    let query = Self.latestQuery(parentID: parentID, limit: limit)
                    guard let items = await connection.cachedLatest(query: query) else { continue }
                    guard !Task.isCancelled, let self, myGeneration == self.generation else { return }
                    // 期间这一行已经拿到新数据 / 开始取了,不拿旧的覆盖
                    if row.isIdle { row.replace(with: .loaded(items)) }
                }
            })
        }

        for view in latestViews {
            guard let row = rows[view.id] else { continue }
            let isEmpty = row.state.value?.isEmpty == true
            if sections.visibleLatestIDs.contains(view.id) || isEmpty {
                fetchLatest(parentID: view.id, row: row, connection: connection)
            }
        }
    }

    /// 「最新」行出现在屏幕上:这一轮还没取过就取。
    func latestRowAppeared(_ parentID: String, server: ServerProfile) {
        let sections = self.sections(for: server.id)
        sections.visibleLatestIDs.insert(parentID)
        guard let row = sections.latest[parentID] else { return }
        fetchLatest(parentID: parentID, row: row, connection: container.connection(for: server))
    }

    func latestRowDisappeared(_ parentID: String, server: ServerProfile) {
        sections(for: server.id).visibleLatestIDs.remove(parentID)
    }

    private func fetchLatest(parentID: String, row: Row<[EmbyItem]>, connection: ServerConnection) {
        guard row.requestedGeneration != generation else { return }
        row.requestedGeneration = generation
        let query = Self.latestQuery(parentID: parentID, limit: Self.sectionLimit)
        fill(
            row,
            showsProgress: false,
            cached: { await connection.cachedLatest(query: query) },
            fetch: { try await connection.latest(query: query) }
        ) { new in
            row.receive(new)
        }
    }

    nonisolated private static func latestQuery(parentID: String, limit: Int) -> EmbyLatestQuery {
        var query = EmbyLatestQuery()
        query.parentID = parentID
        query.limit = limit
        return query
    }

    /// 播放结束后静默刷新「继续观看」(Q22:进度以服务端为准)。不切加载态,失败保留原内容。
    func refreshProgress(server: ServerProfile) {
        let connection = container.connection(for: server)
        let myGeneration = generation
        let sections = self.sections(for: server.id)
        tasks.append(Task {
            // 失败刻意保留原内容;401 等会在下一次正常加载时暴露
            do {
                let items = try await connection.resume(limit: Self.sectionLimit).items
                if myGeneration == generation { sections.resume.replace(with: .loaded(items)) }
            } catch {}
        })
    }

    // MARK: - 移出继续观看(API_CONTRACT.md 5.7)

    /// 只隐藏、不清进度(5.7)。乐观更新:先拿掉再发请求,失败则按原样放回并提示。
    func hideFromResume(_ item: EmbyItem, server: ServerProfile) {
        let resume = self.sections(for: server.id).resume
        let snapshot = resume.state
        guard case .loaded(let items) = snapshot,
              items.contains(where: { $0.id == item.id }),
              !updatingResumeIDs.contains(item.id) else { return }
        updatingResumeIDs.insert(item.id)
        let myGeneration = generation
        let connection = container.connection(for: server)
        resume.replace(with: .loaded(items.filter { $0.id != item.id }))
        tasks.append(Task { [weak self] in
            defer { self?.updatingResumeIDs.remove(item.id) }
            do {
                _ = try await connection.setHiddenFromResume(itemID: item.id, hidden: true)
            } catch let error as EmbyAPIError {
                guard let self, myGeneration == self.generation, error != .cancelled else { return }
                // 已换代(切服务器 / 刷新)的不回滚(上面 guard),快照是上一代的
                if error == .unauthorized { self.container.state.serverNeedingLogin = server }
                resume.replace(with: snapshot)
                self.resumeActionError = "移出继续观看失败:\(error.userMessage)"
            } catch {
                guard let self, myGeneration == self.generation else { return }
                resume.replace(with: snapshot)
                self.resumeActionError = "移出继续观看失败,请稍后重试。"
            }
        })
    }

    /// hero 上剧集的「播放」:定位分集(`ServerConnection.seriesPlaybackEpisode`)后交给 `onResolved`。
    /// 失败照实提示,⛔ 不退回去随便播一集。定位期间不重复发起。
    func playSeries(_ series: EmbyItem, server: ServerProfile, onResolved: @escaping @MainActor (EmbyItem) -> Void) {
        guard resolvingSeriesID == nil else { return }
        resolvingSeriesID = series.id
        let myGeneration = generation
        let connection = container.connection(for: server)
        tasks.append(Task { [weak self] in
            defer {
                if let self, self.resolvingSeriesID == series.id { self.resolvingSeriesID = nil }
            }
            do {
                let episode = try await connection.seriesPlaybackEpisode(seriesID: series.id)
                guard let self, myGeneration == self.generation else { return }
                if let episode {
                    onResolved(episode)
                } else {
                    self.seriesPlayError = "「\(series.name)」还没有可播放的分集。"
                }
            } catch let error as EmbyAPIError {
                guard let self, myGeneration == self.generation, error != .cancelled else { return }
                if error == .unauthorized { self.container.state.serverNeedingLogin = server }
                self.seriesPlayError = "找不到要播放的分集:\(error.userMessage)"
            } catch {
                guard let self, myGeneration == self.generation else { return }
                self.seriesPlayError = "找不到要播放的分集,请稍后重试。"
            }
        })
    }

    /// 等已发出的任务(含期间新追加的)全部结束。测试据此确定时序。
    func waitUntilIdle() async {
        var finished: Set<Task<Void, Never>> = []
        while let next = tasks.first(where: { !finished.contains($0) }) {
            await next.value
            finished.insert(next)
        }
    }

    /// 所有分区都加载完且都为空。媒体库列表没回来时不算空。
    ///
    /// ⛔ 推荐行刻意不参与:整页空由货架决定。不会出现「hero 有内容却报整页空」:
    /// 推荐是根查询,媒体库列表为空时它必然也空。
    static func isEverythingEmpty(
        views: LoadState<[EmbyView]>,
        resume: LoadState<[EmbyItem]>,
        latest: [LoadState<[EmbyItem]>]
    ) -> Bool {
        switch views {
        case .idle, .loading: return false
        case .loaded, .failed: break
        }
        return ([resume] + latest).allSatisfy { state in
            if case .loaded(let items) = state { return items.isEmpty }
            return false
        }
    }

    /// hero 铺哪几项。纯函数,只读已加载的行。
    ///
    /// - 推荐关掉 → `.none`,⛔ 不走退路(用户主动关的,不找替补);
    /// - 推荐还没回来 → `.pending`,占住高度,免得退路先显示、推荐回来又换掉;
    /// - 推荐池里带背景图的,最多 `heroCarouselLimit` 张;
    /// - 推荐为空 / 失败 → 退路(见 `fallbackHeroPick`)。库没刮削过时没有背景图很常见。
    static func heroPick(
        recommended: LoadState<[EmbyItem]>,
        views: LoadState<[EmbyView]>,
        resume: LoadState<[EmbyItem]>,
        latest: (EmbyView) -> LoadState<[EmbyItem]>,
        recommendationsEnabled: Bool = true
    ) -> HeroPick {
        guard recommendationsEnabled else { return .none }
        switch recommended {
        case .idle, .loading:
            return .pending
        case .loaded(let items):
            let picks = Array(items.lazy.filter(isHeroCandidate).prefix(heroCarouselLimit))
            if !picks.isEmpty { return .items(picks) }
        case .failed:
            break
        }
        return fallbackHeroPick(views: views, resume: resume, latest: latest)
    }

    /// 继续观看里第一个有背景图的 → 各库「最新」(按库顺序)第一个有背景图的 → 没有。
    /// 失败的与还没请求的行跳过。只给一张:这几项之间没有关系,摊成轮播像随机跳。
    private static func fallbackHeroPick(
        views: LoadState<[EmbyView]>,
        resume: LoadState<[EmbyItem]>,
        latest: (EmbyView) -> LoadState<[EmbyItem]>
    ) -> HeroPick {
        switch resume {
        case .idle, .loading:
            return .pending
        case .loaded(let items):
            if let item = items.first(where: isHeroCandidate) { return .items([item]) }
        case .failed:
            break
        }
        switch views {
        case .idle, .loading:
            return .pending
        case .failed:
            return .none
        case .loaded(let views):
            for view in latestViews(in: views) {
                switch latest(view) {
                case .loading:
                    return .pending
                case .loaded(let items):
                    if let item = items.first(where: isHeroCandidate) { return .items([item]) }
                case .idle, .failed:
                    // `.idle` = 没滚到、也没本地缓存的行(「最新」滚到才请求),等它会让 hero 一直是骨架
                    continue
                }
            }
            return .none
        }
    }

    /// 必须有背景图(自己或父级的):只有海报的铺成整宽会被裁成一条。
    static func isHeroCandidate(_ item: EmbyItem) -> Bool {
        item.backdropSource != nil
    }

    static func latestViews(in views: [EmbyView]) -> [EmbyView] {
        views.filter { latestCollectionTypes.contains($0.collectionType) }
    }

    // MARK: - 内部

    /// 填一行:没内容时先用本地缓存垫上(过期的也行),再照常取(fresh 窗口内零网络),回来原地替换。
    /// 只有垫完仍空着、或 `showsProgress` 时才计入 `isLoading`。
    private func fill<Value: Sendable>(
        _ row: Row<Value>,
        showsProgress: Bool,
        cached: @escaping @Sendable () async -> Value?,
        fetch: @escaping @Sendable () async throws -> Value,
        apply: @escaping (LoadState<Value>) -> Void
    ) {
        let myGeneration = generation
        row.markLoading()
        tasks.append(Task { [weak self] in
            if let self, !row.hasContent, let stale = await cached() {
                guard !Task.isCancelled, myGeneration == self.generation else { return }
                if !row.hasContent { apply(.loaded(stale)) }
            }
            guard let self, !Task.isCancelled else { return }
            let counts = showsProgress || !row.hasContent
            if counts { requestStarted() }
            defer { if counts { requestFinished() } }
            guard let state = await Self.fetchState(fetch), myGeneration == generation else { return }
            apply(state)
        })
    }

    /// 只由 `fill` 调用。用计数:并行请求最后一个回来才算完。
    private func requestStarted() {
        inFlight += 1
        isLoading = true
    }

    private func requestFinished() {
        inFlight = max(0, inFlight - 1)
        isLoading = inFlight > 0
    }

    /// 被取消返回 nil:调用方什么都不应用
    nonisolated private static func fetchState<Value: Sendable>(
        _ fetch: @Sendable () async throws -> Value
    ) async -> LoadState<Value>? {
        do {
            return .loaded(try await fetch())
        } catch let error as EmbyAPIError {
            return error == .cancelled ? nil : .failed(LoadFailure(error))
        } catch {
            return .failed(LoadFailure(.transport(.unknown)))
        }
    }
}
