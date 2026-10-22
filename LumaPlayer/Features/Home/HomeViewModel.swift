import Foundation

/// 首页:我的媒体 / 继续观看 / 每个媒体库的「最新」,外加顶部 hero 的随机推荐池。
/// ⛔ 不做跨剧集的「下一集」行(PITFALLS.md Q31)。
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

    /// 「最新」同时在途上限(低频率纪律)。`URLSession` 每台主机默认 6 个连接,给其余请求留余量。
    static let latestConcurrency = 4

    private let container: AppContainer

    /// 每行一个独立的 `@Observable` 对象:别的行到数据时不会让它(及整个首页)重新求值。
    @MainActor
    @Observable
    final class Row<Value: Sendable> {
        private(set) var state: LoadState<Value> = .idle

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
        /// 「我的媒体」,来自服务器、不写死(DesignTokens.swift「界面规则」)。它回来后才发「最新」
        let views = Row<[EmbyView]>()
        let resume = Row<[EmbyItem]>()
        /// hero 候选池。⛔ 不驱动任何货架,只有 hero 读。
        let recommended = Row<[EmbyItem]>()
        /// 键是 View 的 Id。只在库的集合变了时整体替换,行对象跨刷新复用
        private(set) var latest: [String: Row<[EmbyItem]>] = [:]

        fileprivate func setLatest(_ rows: [String: Row<[EmbyItem]>]) {
            guard Set(rows.keys) != Set(latest.keys) else { return }
            latest = rows
        }
    }

    /// 键是 `ServerProfile.id`,只增不删(服务器很少,首页重建时 ViewModel 随之重建)。
    /// 不参与观察:`Sections` 建出后不再替换,所以 `sections(for:)` 可在视图求值时按需建对象。
    @ObservationIgnored private var sectionsByServer: [UUID: Sections] = [:]

    /// 菜单里的「移出继续观看」据此禁用
    private(set) var updatingResumeIDs: Set<String> = []
    /// 写操作失败必须让用户知道,不能静默回滚
    var resumeActionError: String?
    var seriesPlayError: String?
    /// hero 播放按钮据此转圈、防连点
    private(set) var resolvingSeriesID: String?

    private var generation = 0
    private var tasks: [Task<Void, Never>] = []

    /// 只统计首屏加载路径;静默校正与写操作不计,不该让刷新图标转起来。
    private var inFlight = 0
    /// 顶栏加载线据此显示。不能只看各行 `state`:刷新时有内容的行保持 `.loaded`。
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

    /// 媒体库列表、继续观看、推荐池三路并行;「最新」等媒体库列表回来再按库发。
    func load(server: ServerProfile) {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        generation += 1
        // 已有内容时不回退到 loading,原地替换;首次 / 上次失败才显示加载态
        let sections = self.sections(for: server.id)
        sections.views.markLoading()
        sections.resume.markLoading()

        let connection = container.connection(for: server)
        // @Sendable 闭包里不能读 MainActor 静态属性
        let limit = Self.sectionLimit
        track { try await connection.userViews() } apply: { [weak self] new in
            guard let self else { return }
            sections.views.receive(new)
            // 刷新失败时用保留的旧列表照常加载「最新」
            loadLatest(views: sections.views.state.value ?? [], sections: sections, connection: connection)
        }
        track { try await connection.resume(limit: limit).items } apply: { new in
            sections.resume.receive(new)
        }
        if container.homeAppearance.showsHeroRecommendations {
            loadRecommendations(sections: sections, connection: connection)
        } else {
            // 关掉了就不发请求,行置空
            sections.recommended.replace(with: .loaded([]))
        }
    }

    /// 只在推荐开关打开时调用(由调用方判断)。
    private func loadRecommendations(sections: Sections, connection: ServerConnection) {
        sections.recommended.markLoading()
        let poolLimit = Self.recommendationPoolLimit
        track { try await connection.recommendations(limit: poolLimit) } apply: { [weak self] new in
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
        loadRecommendations(sections: sections, connection: container.connection(for: server))
    }

    /// 每个视频类媒体库一行,已不存在的库丢掉。按页面从上到下发,同时最多 `latestConcurrency` 个。
    private func loadLatest(views: [EmbyView], sections: Sections, connection: ServerConnection) {
        let latestViews = Self.latestViews(in: views)
        let rows = Dictionary(uniqueKeysWithValues: latestViews.map { view in
            (view.id, sections.latest[view.id] ?? Row())
        })
        sections.setLatest(rows)
        let orderedRows = latestViews.compactMap { rows[$0.id] }
        orderedRows.forEach { $0.markLoading() }

        let parentIDs = latestViews.map(\.id)
        let limit = Self.sectionLimit
        let myGeneration = generation
        requestStarted()
        tasks.append(Task { [weak self] in
            defer { self?.requestFinished() }
            await Self.runLimited(
                count: parentIDs.count,
                maxConcurrent: Self.latestConcurrency
            ) { index in
                var query = EmbyLatestQuery()
                query.parentID = parentIDs[index]
                query.limit = limit
                let request = query
                return await Self.fetchState { try await connection.latest(query: request) }
            } onResult: { index, state in
                guard let self, let state, myGeneration == self.generation else { return }
                orderedRows[index].receive(state)
            }
        })
    }

    /// 按下标顺序启动,同时不超过 `maxConcurrent`,完成一个补一个;结果逐个交给 `onResult`。
    /// 外层取消后不再启动新的。
    static func runLimited<Result: Sendable>(
        count: Int,
        maxConcurrent: Int,
        operation: @escaping @Sendable (Int) async -> Result,
        onResult: (Int, Result) -> Void
    ) async {
        await withTaskGroup(of: (Int, Result).self) { group in
            var nextIndex = 0
            while nextIndex < min(count, max(1, maxConcurrent)) {
                let index = nextIndex
                group.addTask { (index, await operation(index)) }
                nextIndex += 1
            }
            while let (index, result) = await group.next() {
                onResult(index, result)
                guard nextIndex < count, !Task.isCancelled else { continue }
                let next = nextIndex
                group.addTask { (next, await operation(next)) }
                nextIndex += 1
            }
        }
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
    /// 失败的行跳过。只给一张:这几项之间没有关系,摊成轮播像随机跳。
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
                case .idle, .loading:
                    return .pending
                case .loaded(let items):
                    if let item = items.first(where: isHeroCandidate) { return .items([item]) }
                case .failed:
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

    private func track<Value: Sendable>(
        _ fetch: @escaping @Sendable () async throws -> Value,
        apply: @escaping (LoadState<Value>) -> Void
    ) {
        let myGeneration = generation
        requestStarted()
        tasks.append(Task {
            defer { requestFinished() }
            guard let state = await Self.fetchState(fetch), myGeneration == generation else { return }
            apply(state)
        })
    }

    /// 只由 `track` 与 `loadLatest` 调用。用计数:并行请求最后一个回来才算完。
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
