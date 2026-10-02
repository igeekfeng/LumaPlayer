import Foundation

/// 首页:我的媒体 / 继续观看 / 下一集 / 每个媒体库的「最新」。
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

    /// 首页为之显示「最新」的媒体库类型。音乐 / 有声书 / 直播不在首版范围内
    /// (ARCHITECTURE.md 2.4),`CollectionType` 为 null 的混合库照常显示。
    static let latestCollectionTypes: Set<String?> = [nil, "movies", "tvshows", "homevideos", "musicvideos", "mixed"]

    private let container: AppContainer

    /// 一台服务器的首页各分区
    struct Sections {
        /// 「我的媒体」:`/Users/{UserId}/Views`,入口列表来自服务器、不写死「电影/电视剧」
        /// (UI_DESIGN.md 3.1)。「最新」的行也按它来,所以先回来它才发「最新」的请求
        var views: LoadState<[EmbyView]> = .idle
        var resume: LoadState<[EmbyItem]> = .idle
        var nextUp: LoadState<[EmbyItem]> = .idle
        /// 每个媒体库的「最新」,键是 View 的 Id
        var latest: [String: LoadState<[EmbyItem]>] = [:]
    }

    /// 键是 `ServerProfile.id`。只增不删:服务器数量很少,且首页重建
    /// (删光服务器回到引导页再进来)时整个 ViewModel 随之重建
    private var sectionsByServer: [UUID: Sections] = [:]

    /// 正在写「继续观看」的条目(菜单里的「移出继续观看」据此禁用)
    private(set) var updatingResumeIDs: Set<String> = []
    /// 「移出继续观看」失败的提示(写操作失败必须让用户知道,不能静默回滚)
    var resumeActionError: String?

    private var generation = 0
    private var tasks: [Task<Void, Never>] = []

    init(container: AppContainer) {
        self.container = container
    }

    /// 某台服务器的首页内容;没加载过就是全 `.idle`
    func sections(for serverID: UUID) -> Sections {
        sectionsByServer[serverID] ?? Sections()
    }

    /// 加载(或切换服务器 / 刷新后重新加载)全部分区。
    ///
    /// 「继续观看」「下一集」与媒体库列表并行;「最新」等媒体库列表回来再按库发,
    /// 每个库只请求一次。
    func load(server: ServerProfile) {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        generation += 1
        // 这台服务器已有内容时不回退到 loading(同一台刷新、或从别的服务器切回来):
        // 保留当前内容,新数据到达后原地替换,失败则保留旧内容。
        // 首次加载 / 上次失败才显示加载态。
        let serverID = server.id
        update(serverID) {
            Self.markLoading(&$0.views)
            Self.markLoading(&$0.resume)
            Self.markLoading(&$0.nextUp)
        }

        let connection = container.connection(for: server)
        // 闭包是 @Sendable,不能在里面读 MainActor 上的静态属性,先取出来
        let limit = Self.sectionLimit
        track { try await connection.userViews() } apply: { [weak self] new in
            guard let self else { return }
            update(serverID) { $0.views = Self.merge(new, into: $0.views) }
            // 刷新失败时保留的旧列表照常加载「最新」;首次就失败则没有「最新」可加载
            loadLatest(views: sections(for: serverID).views.value ?? [], serverID: serverID, connection: connection)
        }
        track { try await connection.resume(limit: limit).items } apply: { [weak self] new in
            self?.update(serverID) { $0.resume = Self.merge(new, into: $0.resume) }
        }
        track { try await connection.nextUp(limit: limit) } apply: { [weak self] new in
            self?.update(serverID) { $0.nextUp = Self.merge(new, into: $0.nextUp) }
        }
    }

    /// 每个视频类媒体库一行「最新」。列表里已没有的库顺手丢掉
    private func loadLatest(views: [EmbyView], serverID: UUID, connection: ServerConnection) {
        let latestViews = Self.latestViews(in: views)
        update(serverID) { sections in
            sections.latest = Dictionary(uniqueKeysWithValues: latestViews.map { view in
                var state = sections.latest[view.id] ?? .idle
                Self.markLoading(&state)
                return (view.id, state)
            })
        }
        let limit = Self.sectionLimit
        for view in latestViews {
            track {
                var query = EmbyLatestQuery()
                query.parentID = view.id
                query.limit = limit
                return try await connection.latest(query: query)
            } apply: { [weak self] new in
                self?.update(serverID) { $0.latest[view.id] = Self.merge(new, into: $0.latest[view.id]) }
            }
        }
    }

    /// 播放结束后静默刷新「继续观看」与「下一集」(Q22:进度以服务端为准)。
    /// 不切回加载态、失败时保留原内容 —— 这是后台校正,页面不该闪。
    func refreshProgress(server: ServerProfile) {
        let connection = container.connection(for: server)
        let myGeneration = generation
        tasks.append(Task {
            // 两段各自 do/catch:一段失败不影响另一段;失败时刻意保留原内容
            // (与 MediaDetailViewModel.refreshDetail 同一立场),401 等问题会在
            // 用户下一次操作时由正常加载路径暴露。
            do {
                let items = try await connection.resume(limit: Self.sectionLimit).items
                if myGeneration == generation { update(server.id) { $0.resume = .loaded(items) } }
            } catch {}
            do {
                let items = try await connection.nextUp(limit: Self.sectionLimit)
                if myGeneration == generation { update(server.id) { $0.nextUp = .loaded(items) } }
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
        let serverID = server.id
        let snapshot = sections(for: serverID).resume
        guard case .loaded(let items) = snapshot,
              items.contains(where: { $0.id == item.id }),
              !updatingResumeIDs.contains(item.id) else { return }
        updatingResumeIDs.insert(item.id)
        let myGeneration = generation
        let connection = container.connection(for: server)
        update(serverID) { $0.resume = .loaded(items.filter { $0.id != item.id }) }
        tasks.append(Task { [weak self] in
            defer { self?.updatingResumeIDs.remove(item.id) }
            do {
                _ = try await connection.setHiddenFromResume(itemID: item.id, hidden: true)
            } catch let error as EmbyAPIError {
                guard let self, myGeneration == self.generation, error != .cancelled else { return }
                // 列表已经换过一代(切服务器 / 刷新)就不回滚:快照是上一代的内容
                if error == .unauthorized { self.container.state.serverNeedingLogin = server }
                self.update(serverID) { $0.resume = snapshot }
                self.resumeActionError = "移出继续观看失败:\(error.userMessage)"
            } catch {
                guard let self, myGeneration == self.generation else { return }
                self.update(serverID) { $0.resume = snapshot }
                self.resumeActionError = "移出继续观看失败,请稍后重试。"
            }
        })
    }

    /// 「下一集」行失败时整行不显示(docs/PITFALLS.md Q31 方案 B)。
    ///
    /// 跨剧集的 NextUp 不带 `SeriesId`,有的服务器会直接拒绝
    /// (实测一台 4.7.11.0 返回 400 `{"error":"SeriesId is required"}`)。
    /// 这一行是锦上添花,失败时露出错误卡片只会让首页看起来坏了;
    /// 状态本身仍保留 `.failed`,不伪装成空列表,原因由 `NetworkDiagnostics` 留档。
    static func showsNextUpRow(_ state: LoadState<[EmbyItem]>) -> Bool {
        if case .failed = state { return false }
        return true
    }

    /// 所有**可见**分区都加载完且都为空。被隐藏的「下一集」不参与判断 ——
    /// 否则它一失败,空服务器上的「还没有可看的内容」提示就永远出不来。
    ///
    /// 媒体库列表还没回来时不算空:「最新」的行要等它回来才知道有几行。
    static func isEverythingEmpty(
        views: LoadState<[EmbyView]>,
        resume: LoadState<[EmbyItem]>,
        nextUp: LoadState<[EmbyItem]>,
        latest: [LoadState<[EmbyItem]>]
    ) -> Bool {
        switch views {
        case .idle, .loading: return false
        case .loaded, .failed: break
        }
        let states = [resume] + (showsNextUpRow(nextUp) ? [nextUp] : []) + latest
        return states.allSatisfy { state in
            if case .loaded(let items) = state { return items.isEmpty }
            return false
        }
    }

    static func latestViews(in views: [EmbyView]) -> [EmbyView] {
        views.filter { latestCollectionTypes.contains($0.collectionType) }
    }

    // MARK: - 内部

    private func update(_ serverID: UUID, _ change: (inout Sections) -> Void) {
        var sections = sections(for: serverID)
        change(&sections)
        sectionsByServer[serverID] = sections
    }

    /// 已有内容(`.loaded`)保持不动;其余(空闲 / 失败 / 加载中)进入加载态
    private static func markLoading<Value>(_ state: inout LoadState<Value>) {
        if case .loaded = state { return }
        state = .loading
    }

    /// 新结果并入现有状态:成功一律替换;失败时若已有内容则保留内容(后台刷新失败不该
    /// 把好好的一行换成错误卡片,401 等问题会在用户下一次操作时由正常路径暴露)
    private static func merge<Value>(
        _ new: LoadState<Value>,
        into current: LoadState<Value>?
    ) -> LoadState<Value> {
        if case .failed = new, case .loaded? = current { return current ?? new }
        return new
    }

    private func track<Value>(
        _ fetch: @escaping @Sendable () async throws -> Value,
        apply: @escaping (LoadState<Value>) -> Void
    ) {
        let myGeneration = generation
        tasks.append(Task {
            do {
                let items = try await fetch()
                guard myGeneration == generation else { return }
                apply(.loaded(items))
            } catch let error as EmbyAPIError {
                guard myGeneration == generation, error != .cancelled else { return }
                apply(.failed(LoadFailure(error)))
            } catch {
                guard myGeneration == generation else { return }
                apply(.failed(LoadFailure(.transport(.unknown))))
            }
        })
    }
}
