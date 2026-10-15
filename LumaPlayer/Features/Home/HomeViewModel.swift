import Foundation

/// 首页:我的媒体 / 继续观看 / 每个媒体库的「最新」,外加顶部 hero 的**随机推荐池**。
///
/// 没有跨剧集的「下一集」行(2026-10-02 去掉):用户所有服务器上它都是加载一下就消失,
/// 见 `docs/PITFALLS.md` Q31。
///
/// 每个分区各自独立加载、各自有自己的状态:一个失败不该让另一个也消失。
/// 每个分区都带 generation 检查 —— 快速切换服务器时,旧服务器慢到的响应
/// 会被丢弃(不出现旧服务器内容)。
///
/// 状态**按服务器分开存**(issue #3):A → B → A 切回来时直接显示 A 上次的内容、
/// 后台原地刷新,不回退到 loading;各台之间互不可见,不串台。
@MainActor
@Observable
final class HomeViewModel {
    /// 首页每个分区取多少条。不是设计 token,与布局无关。
    static let sectionLimit = 20

    /// 顶部 hero 的推荐池一次取多少条(:而非直接取轮播要的张数)。
    ///
    /// 不是设计 token,与布局无关。取 20 是给「必须带背景图」那道筛选留余量:
    /// 2026-10-15 本机 4.9.5.0 实测,随机 6 条里只有 1 条带 `BackdropImageTags`
    /// (顶层 `Series` 通常有,`Movie` 常常只有竖版海报)。只取 5 条的话
    /// 十有八九筛完是空的。
    static let recommendationPoolLimit = 20

    /// hero 轮播最多几张。轮播的每一张都要一张 1920 宽的背景图,
    /// 张数越多首屏的图片请求越多 —— 见 `HomeHeroCarousel`。
    static let heroCarouselLimit = 5

    /// 首页为之显示「最新」的媒体库类型。音乐 / 有声书 / 直播不在首版范围内
    /// (CLAUDE.md「非目标」),`CollectionType` 为 null 的混合库照常显示。
    static let latestCollectionTypes: Set<String?> = [nil, "movies", "tvshows", "homevideos", "musicvideos", "mixed"]

    /// 「最新」同时最多在途几个请求。媒体库 20+ 的服务器上,一次刷新不该把
    /// 二十几个请求同时压过去(真实服务器使用纪律:低频率)。取 4:
    /// `URLSession` 每台主机默认 6 个连接,给「继续观看」与首屏图片留出余量。
    static let latestConcurrency = 4

    private let container: AppContainer

    /// 首页的一行。每行一个独立的 `@Observable` 对象:行视图只读自己那一个 `state`,
    /// 别的行到数据时不会让它(以及整个首页)重新求值 —— 媒体库多时「最新」有很多行。
    @MainActor
    @Observable
    final class Row<Value: Sendable> {
        private(set) var state: LoadState<Value> = .idle

        /// 已有内容(`.loaded`)保持不动;其余(空闲 / 失败 / 加载中)进入加载态。
        /// 不变时不写属性:写 `@Observable` 属性即通知,哪怕值没变
        func markLoading() {
            if case .loaded = state { return }
            if case .loading = state { return }
            state = .loading
        }

        /// 新结果并入现有状态:成功一律替换;失败时若已有内容则保留内容(后台刷新失败不该
        /// 把好好的一行换成错误卡片,401 等问题会在用户下一次操作时由正常路径暴露)
        func receive(_ new: LoadState<Value>) {
            if case .failed = new, case .loaded = state { return }
            state = new
        }

        /// 直接覆盖(乐观更新、回滚、播放后的静默校正)
        func replace(with new: LoadState<Value>) {
            state = new
        }
    }

    /// 一台服务器的首页各分区
    /// `heroPick` 的结果
    enum HeroPick: Equatable {
        /// 决定它的行还在加载:hero 位置放骨架
        case pending
        /// 没有能上 hero 的条目:不画 hero,首页从普通页面的顶部开始
        case none
        /// 铺满顶部的一项或多项。**只有一张**(退路)时轮播自然退化成静默的单张,
        /// 不给箭头 / 圆点(`HomeHeroCarousel`)。
        case items([EmbyItem])
    }

    @MainActor
    @Observable
    final class Sections {
        /// 「我的媒体」:`/Users/{UserId}/Views`,入口列表来自服务器、不写死「电影/电视剧」
        /// (DesignTokens.swift「界面规则」)。「最新」的行也按它来,所以先回来它才发「最新」的请求
        let views = Row<[EmbyView]>()
        let resume = Row<[EmbyItem]>()
        /// hero 轮播的候选池(`SortBy=Random`)。⛔ 它**不驱动**任何货架 ——
        /// `HomeView` 的行列表里没有它,只有 hero 读。
        let recommended = Row<[EmbyItem]>()
        /// 每个媒体库的「最新」,键是 View 的 Id。只在库的集合变了时整体替换,
        /// 行对象跨刷新复用(刷新只改行内的 `state`)
        private(set) var latest: [String: Row<[EmbyItem]>] = [:]

        fileprivate func setLatest(_ rows: [String: Row<[EmbyItem]>]) {
            guard Set(rows.keys) != Set(latest.keys) else { return }
            latest = rows
        }
    }

    /// 键是 `ServerProfile.id`。只增不删:服务器数量很少,且首页重建
    /// (删光服务器回到引导页再进来)时整个 ViewModel 随之重建。
    ///
    /// 不参与观察:`Sections` 对象一旦建出来就不再替换,视图观察的是对象内部的属性。
    /// 所以 `sections(for:)` 可以在视图求值时按需建对象,不会触发「求值中改状态」
    @ObservationIgnored private var sectionsByServer: [UUID: Sections] = [:]

    /// 正在写「继续观看」的条目(菜单里的「移出继续观看」据此禁用)
    private(set) var updatingResumeIDs: Set<String> = []
    /// 「移出继续观看」失败的提示(写操作失败必须让用户知道,不能静默回滚)
    var resumeActionError: String?

    private var generation = 0
    private var tasks: [Task<Void, Never>] = []

    /// 在途请求数。只统计首屏加载路径(媒体库列表、继续观看、各「最新」行)——
    /// 播放后的静默校正与「移出继续观看」不计,那些不该让刷新图标转起来。
    private var inFlight = 0
    /// 首屏是否正在加载 / 刷新(顶栏加载线据此显示)。
    ///
    /// 不能只看各行的 `state`:刷新时已有内容的行会保持 `.loaded`(不闪加载态),
    /// 所以需要一个独立标记。
    private(set) var isLoading = false

    init(container: AppContainer) {
        self.container = container
    }

    /// 某台服务器的首页内容;没加载过就是全 `.idle`。
    /// 同一台服务器始终返回同一个对象(没有就当场建一个)
    func sections(for serverID: UUID) -> Sections {
        if let sections = sectionsByServer[serverID] { return sections }
        let sections = Sections()
        sectionsByServer[serverID] = sections
        return sections
    }

    /// 加载(或切换服务器 / 刷新后重新加载)全部分区。
    ///
    /// 媒体库列表、继续观看、hero 的推荐池三路**并行**;「最新」等媒体库列表
    /// 回来再按库发,每个库只请求一次。
    func load(server: ServerProfile) {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        generation += 1
        // 这台服务器已有内容时不回退到 loading(同一台刷新、或从别的服务器切回来):
        // 保留当前内容,新数据到达后原地替换,失败则保留旧内容。
        // 首次加载 / 上次失败才显示加载态。
        let sections = self.sections(for: server.id)
        sections.views.markLoading()
        sections.resume.markLoading()
        sections.recommended.markLoading()

        let connection = container.connection(for: server)
        // 闭包是 @Sendable,不能在里面读 MainActor 上的静态属性,先取出来
        let limit = Self.sectionLimit
        let poolLimit = Self.recommendationPoolLimit
        track { try await connection.userViews() } apply: { [weak self] new in
            guard let self else { return }
            sections.views.receive(new)
            // 刷新失败时保留的旧列表照常加载「最新」;首次就失败则没有「最新」可加载
            loadLatest(views: sections.views.state.value ?? [], sections: sections, connection: connection)
        }
        track { try await connection.resume(limit: limit).items } apply: { new in
            sections.resume.receive(new)
        }
        track { try await connection.recommendations(limit: poolLimit) } apply: { new in
            sections.recommended.receive(new)
        }
    }

    /// 每个视频类媒体库一行「最新」。列表里已没有的库顺手丢掉。
    ///
    /// 按页面上**从上到下**的顺序发,同时最多 `latestConcurrency` 个:首屏那几行先回来,
    /// 排队中的行先显示加载态。
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

    /// 依次启动 `count` 个任务(下标从小到大),同时在跑的不超过 `maxConcurrent`;
    /// 每完成一个就补一个,结果一回来就交给 `onResult`(在 MainActor 上,不等其余的)。
    /// 外层任务被取消后不再启动新的,已在跑的随任务组一起取消。
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

    /// 播放结束后静默刷新「继续观看」(Q22:进度以服务端为准)。
    /// 不切回加载态、失败时保留原内容 —— 这是后台校正,页面不该闪。
    func refreshProgress(server: ServerProfile) {
        let connection = container.connection(for: server)
        let myGeneration = generation
        let sections = self.sections(for: server.id)
        tasks.append(Task {
            // 失败时刻意保留原内容(与 MediaDetailViewModel.refreshDetail 同一立场),
            // 401 等问题会在用户下一次操作时由正常加载路径暴露。
            do {
                let items = try await connection.resume(limit: Self.sectionLimit).items
                if myGeneration == generation { sections.resume.replace(with: .loaded(items)) }
            } catch {}
        })
    }

    // MARK: - 移出继续观看(API_CONTRACT.md 5.7)

    /// 把一条从「继续观看」里移出。**只隐藏、不清进度**(5.7),服务端仍然记着看到哪,
    /// 也仍然是未看 —— 适合「看了一点、暂时不想看」。
    ///
    /// 乐观更新:先把这一项从列表里拿掉再发请求。写操作是用户明确点出来的,
    /// 等一个往返再动界面会显得没反应;失败则把列表**按原样放回**并给出提示
    /// (硬规则:不静默吞错、不用假数据占位)。
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
                // 列表已经换过一代(切服务器 / 刷新)就不回滚:快照是上一代的内容
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

    /// 等已发出的任务全部结束:加载、媒体库列表回来后才追加的「最新」、
    /// 静默刷新、「移出继续观看」的写请求。`load` 是发出去就返回的,
    /// 测试据此确定时序,不靠睡一个固定时长去赌请求已经回来。
    /// 等待期间新追加的任务也会等到;没有在途任务时立即返回。
    func waitUntilIdle() async {
        var finished: Set<Task<Void, Never>> = []
        while let next = tasks.first(where: { !finished.contains($0) }) {
            await next.value
            finished.insert(next)
        }
    }

    /// 所有分区都加载完且都为空。
    ///
    /// 媒体库列表还没回来时不算空:「最新」的行要等它回来才知道有几行。
    ///
    /// ⛔ **推荐行(`recommended`)刻意不参与**。它空不代表这台服务器没内容,
    /// 而「空」该不该报整页空状态由**货架**决定(hero 只是顶部一块装饰)。
    /// 不会出现「hero 有内容却报整页空」:推荐查询是不带 `ParentId` 的根查询,
    /// 媒体库列表为空时它必然也是空 —— 两者同源。
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

    /// 首页顶部 hero 铺哪几项。**纯函数**:只读已经加载的行,自己一个请求都不发 ——
    /// 推荐池由 `load` 里那一路 `recommendations` 填(hero 从此**有**自己的请求了,
    /// 但取数不在这个函数里,所以它照旧可以纯单测)。
    ///
    /// **首选随机推荐**(`SortBy=Random`,见 `ServerConnection.recommendations`):
    /// 池子里筛出带背景图的,最多 `heroCarouselLimit` 张交给轮播。
    ///
    /// **推荐行还没回来时返回 `.pending`**:先占住 hero 的高度等它,
    /// 不然退路先显示了别的、等推荐回来又换掉,首屏会跳。
    ///
    /// **推荐为空 / 失败时退回老逻辑**:继续观看里第一个有背景图的 →
    /// 各媒体库「最新」里(按媒体库顺序)第一个有背景图的 → 没有。
    /// 这时只给**一张**,`HomeHeroCarousel` 会自动退化成静默的单张。
    /// 留这条退路是因为「推荐拿不到图」在真实服务器上很常见:
    /// 库没刮削过元数据时 `BackdropImageTags` 就是空的(DTS 那种静默删轨同理)。
    /// 失败的行跳过 —— 它自己那一行会报错,hero 不跟着空着。
    static func heroPick(
        recommended: LoadState<[EmbyItem]>,
        views: LoadState<[EmbyView]>,
        resume: LoadState<[EmbyItem]>,
        latest: (EmbyView) -> LoadState<[EmbyItem]>
    ) -> HeroPick {
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

    /// 推荐拿不到时的退路(2026-10-15 之前 hero 的唯一逻辑)。
    /// 只给一张 —— 轮播的箭头 / 圆点需要用户能预期「下一张是什么」,
    /// 退路这几项之间没有那种关系,摊成轮播反而像随机跳。
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

    /// 能上 hero 的条目:必须有背景图(自己的或父级的,`backdropSource`)。
    /// 只有海报的条目铺成整宽 hero 会被裁成一条,不选。
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

    /// 开始 / 结束一个「首屏加载」请求(只由 `track` 与 `loadLatest` 调用)。
    /// 用计数而不是布尔:一轮 `load` 里有多个并行请求,最后一个回来才算加载完。
    private func requestStarted() {
        inFlight += 1
        isLoading = true
    }

    private func requestFinished() {
        inFlight = max(0, inFlight - 1)
        isLoading = inFlight > 0
    }

    /// 取一次数据并折成 `LoadState`。被取消(`.cancelled`)返回 nil:调用方什么都不应用
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
