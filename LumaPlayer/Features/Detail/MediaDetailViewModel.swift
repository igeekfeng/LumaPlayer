import Foundation

/// Emby 详情页的数据。
///
/// 列表对象字段不全(API_CONTRACT.md 3.2),⛔ 不能直接当详情展示,必须再取 `/Users/{UserId}/Items/{Id}`。
/// 剧集是单页模型:季与分集在同一页,唯一的播放按钮作用于 `focusedEpisode`;点分集行只换定位,不跳页。
@MainActor
@Observable
final class MediaDetailViewModel {
    private let container: AppContainer

    private(set) var detailState: LoadState<EmbyItem> = .idle
    private(set) var seasonsState: LoadState<[EmbyItem]> = .idle
    private(set) var episodesState: LoadState<[EmbyItem]> = .idle
    private(set) var selectedSeason: EmbyItem?
    /// 只有剧集才有。nil = 还没定位到
    private(set) var focusedEpisode: EmbyItem?
    /// 电影 / 剧集才查。失败或为空时页面不显示这一区块
    private(set) var similarState: LoadState<[EmbyItem]> = .idle
    /// 写操作失败必须让用户知道
    var userDataError: String?
    /// 按钮据此禁用,防连点发出相反的两次请求
    private(set) var updatingItemIDs: Set<String> = []

    /// 刷新时 `detailState` 仍是 `.loaded`,单看它不够。
    var isLoading: Bool {
        detailState.isLoading || seasonsState.isLoading || episodesState.isLoading || isRefreshing
    }
    /// 原地刷新中(首次加载由 `detailState` 表达)
    private var isRefreshing = false

    private var seriesID: String?
    /// 「服务器 + 条目」。同一个键再次 `load` 是原地刷新,不切回加载态
    private var loadedKey: String?
    /// 服务端给的该播那一集,决定初始定位
    private var focusEpisodeID: String?
    /// 手动选过后自动定位不再覆盖(切季重置)
    private var didPickEpisodeManually = false
    private var generation = 0
    private var detailTask: Task<Void, Never>?
    private var seasonsTask: Task<Void, Never>?
    private var episodesTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var episodesRefreshTask: Task<Void, Never>?
    private var similarTask: Task<Void, Never>?
    /// 批量标记的代次号,换条目时 +1,旧批次结果不再回写。与管加载任务的 `generation` 分开。
    private var batchToken = 0

    /// 与 Emby Web 同为一行 12 个
    static let similarLimit = 12

    init(container: AppContainer) {
        self.container = container
    }

    func load(item: EmbyItem, server: ServerProfile) {
        detailTask?.cancel()
        seasonsTask?.cancel()
        episodesTask?.cancel()
        refreshTask?.cancel()
        episodesRefreshTask?.cancel()
        similarTask?.cancel()
        generation += 1
        // 上一页的批量进度与提示不再属于这里(见 runBatch)
        batchToken += 1
        batchProgress = nil
        batchMessage = nil
        let myGeneration = generation

        // 同一项且已有内容:原地刷新,失败保留旧内容
        let key = "\(server.id.uuidString)-\(item.id)"
        let isRefresh: Bool = {
            if loadedKey == key, case .loaded = detailState { return true }
            return false
        }()
        loadedKey = key

        if !isRefresh {
            detailState = .loading
            similarState = .idle
            seasonsState = .idle
            episodesState = .idle
            selectedSeason = nil
            seriesID = nil
            focusedEpisode = nil
            focusEpisodeID = nil
            didPickEpisodeManually = false
        } else {
            isRefreshing = true
        }

        detailTask = Task {
            defer {
                // 期间又发起了新一轮就不动标记,交给它管
                if isRefresh, myGeneration == generation { isRefreshing = false }
            }
            do {
                let connection = container.connection(for: server)
                // 点进来的是分集:同 Emby Web,打开整部剧并定位到这一集。
                // 列表对象通常自带 SeriesId,没有时先取分集详情拿到它。
                var requestedEpisode: EmbyItem?
                var full: EmbyItem
                if item.kind == .episode, let seriesID = item.seriesID {
                    requestedEpisode = item
                    full = try await connection.item(id: seriesID)
                } else {
                    full = try await connection.item(id: item.id)
                    if full.kind == .episode, let seriesID = full.seriesID {
                        requestedEpisode = full
                        full = try await connection.item(id: seriesID)
                    }
                }
                guard myGeneration == generation else { return }
                detailState = .loaded(full)
                if full.kind == .movie || full.kind == .series {
                    loadSimilar(itemID: full.id, server: server, generation: myGeneration)
                }
                guard full.kind == .series else { return }
                seriesID = full.id
                await loadSeasons(server: server, generation: myGeneration, requestedEpisode: requestedEpisode)
            } catch let error as EmbyAPIError {
                guard myGeneration == generation else { return }
                if error == .cancelled { return }
                if isRefresh { return }
                detailState = .failed(LoadFailure(error))
            } catch {
                guard myGeneration == generation else { return }
                if isRefresh { return }
                detailState = .failed(LoadFailure(.transport(.unknown)))
            }
        }
    }

    // MARK: - 已看 / 收藏(API_CONTRACT.md 5.5 / 5.6)

    /// 作用于 Series 时服务端会级联标分集;客户端不依赖级联,写后一律重读详情与分集。
    func togglePlayed(_ item: EmbyItem, server: ServerProfile) {
        let target = !(item.userData?.played ?? false)
        writeUserData(item, server: server, failureVerb: target ? "标记为已看" : "标记为未看") { connection in
            try await connection.setPlayed(itemID: item.id, played: target)
        }
    }

    // MARK: - 批量标记(API_CONTRACT.md 5.8)

    /// Emby 没有批量端点,只能逐条写,慢时要几秒,界面须显示进度。
    struct BatchPlayedProgress: Sendable, Equatable {
        /// 不含已处于目标状态的集
        let total: Int
        var completed: Int = 0
        let played: Bool
    }

    /// nil = 没有在跑
    private(set) var batchProgress: BatchPlayedProgress?

    /// 结果提示,成功也要说一声;有失败时是错误文案。
    var batchMessage: String?

    /// 已处于目标状态的不再发请求;`UserData` 缺失按未看算(同 `EmbyItem.isPlayed`)。
    nonisolated static func pendingIDs(in episodes: [EmbyItem], played: Bool) -> [String] {
        episodes.filter { $0.isPlayed != played }.map(\.id)
    }

    /// 单季一键
    func markSeasonPlayed(_ episodes: [EmbyItem], played: Bool, server: ServerProfile) {
        runBatch(itemIDs: Self.pendingIDs(in: episodes, played: played), played: played, server: server)
    }

    /// 勾选面板
    func markEpisodesPlayed(_ episodes: [EmbyItem], played: Bool, server: ServerProfile) {
        runBatch(itemIDs: Self.pendingIDs(in: episodes, played: played), played: played, server: server)
    }

    /// 批量写入唯一出口:串行、失败不中断,结束后以服务端为准重读。
    /// 中途切了条目:请求照样发完,但不再回写进度 / 提示 / `updatingItemIDs`。
    /// ⛔ 清理只能放 `defer`,不能靠 `guard` 提前 return:会把 `batchProgress` 永久卡住。
    private func runBatch(itemIDs: [String], played: Bool, server: ServerProfile) {
        guard !itemIDs.isEmpty, batchProgress == nil else { return }
        batchToken += 1
        let myToken = batchToken
        batchProgress = BatchPlayedProgress(total: itemIDs.count, played: played)
        let connection = container.connection(for: server)
        let myGeneration = generation
        updatingItemIDs.formUnion(itemIDs)
        Task {
            defer {
                if myToken == batchToken {
                    updatingItemIDs.subtract(itemIDs)
                    batchProgress = nil
                }
            }
            let verb = played ? "标记为已看" : "标记为未看"
            let result: PlayedBatchResult
            do {
                result = try await connection.setPlayed(itemIDs: itemIDs, played: played) { done, _ in
                    await MainActor.run {
                        guard myToken == self.batchToken, var progress = self.batchProgress else { return }
                        progress.completed = done
                        self.batchProgress = progress
                    }
                }
            } catch let error as EmbyAPIError {
                guard myToken == batchToken else { return }
                if error == .cancelled { return }
                if error == .unauthorized { container.state.serverNeedingLogin = server }
                batchMessage = "\(verb)失败:\(error.userMessage)"
                return
            } catch {
                guard myToken == batchToken else { return }
                batchMessage = "\(verb)失败,请稍后重试。"
                return
            }
            guard myToken == batchToken, myGeneration == generation else { return }
            for (itemID, userData) in result.written {
                apply(userData, to: itemID)
            }
            let succeeded = result.written.count
            if result.isComplete {
                batchMessage = "已把 \(succeeded) 集\(verb)。"
            } else {
                let reason = result.firstError.map { "(\($0.userMessage))" } ?? ""
                batchMessage = "\(verb):\(succeeded) 集成功,\(result.failedItemIDs.count) 集失败\(reason)。"
            }
            if result.firstError == .unauthorized { container.state.serverNeedingLogin = server }
            // 已看会改变续播定位与剧 / 季汇总,以服务端为准重读
            refreshAfterPlayback(server: server)
        }
    }

    func toggleFavorite(_ item: EmbyItem, server: ServerProfile) {
        let target = !(item.userData?.isFavorite ?? false)
        writeUserData(item, server: server, failureVerb: target ? "收藏" : "取消收藏") { connection in
            try await connection.setFavorite(itemID: item.id, favorite: target)
        }
    }

    private func writeUserData(
        _ item: EmbyItem,
        server: ServerProfile,
        failureVerb: String,
        _ write: @escaping @Sendable (ServerConnection) async throws -> EmbyUserData
    ) {
        guard !updatingItemIDs.contains(item.id) else { return }
        updatingItemIDs.insert(item.id)
        let connection = container.connection(for: server)
        let myGeneration = generation
        Task {
            defer { updatingItemIDs.remove(item.id) }
            do {
                let userData = try await write(connection)
                guard myGeneration == generation else { return }
                apply(userData, to: item.id)
                // 会连带改变剧 ↔ 集的状态与续播定位,以服务端为准重读
                refreshAfterPlayback(server: server)
            } catch let error as EmbyAPIError {
                guard myGeneration == generation, error != .cancelled else { return }
                if error == .unauthorized { container.state.serverNeedingLogin = server }
                userDataError = "\(failureVerb)失败:\(error.userMessage)"
            } catch {
                guard myGeneration == generation else { return }
                userDataError = "\(failureVerb)失败,请稍后重试。"
            }
        }
    }

    /// 就地替换页面上所有同 Id 的对象。
    private func apply(_ userData: EmbyUserData, to itemID: String) {
        if case .loaded(var detail) = detailState, detail.id == itemID {
            detail.userData = userData
            detailState = .loaded(detail)
        }
        if case .loaded(var episodes) = episodesState,
           let index = episodes.firstIndex(where: { $0.id == itemID }) {
            episodes[index].userData = userData
            episodesState = .loaded(episodes)
        }
        if focusedEpisode?.id == itemID {
            focusedEpisode?.userData = userData
        }
    }

    // MARK: - 分集定位

    func selectEpisode(_ episode: EmbyItem) {
        didPickEpisodeManually = true
        focusedEpisode = episode
    }

    /// 播放结束后按服务端重读详情(PITFALLS.md Q22):续播与已看规则(MinResumePct 等)⛔ 不在客户端复刻。
    /// 后台校正:不切加载态、不重拉季与分集,失败保留现有内容(401 等由下一次正常操作暴露)。
    func refreshDetail(server: ServerProfile) {
        guard case .loaded(let current) = detailState else { return }
        refreshTask?.cancel()
        let myGeneration = generation
        refreshTask = Task {
            let full: EmbyItem
            do {
                full = try await container.connection(for: server).item(id: current.id)
            } catch {
                // 刻意保留现有内容
                return
            }
            guard myGeneration == generation else { return }
            detailState = .loaded(full)
        }
    }

    /// 详情 + 当前季分集一起重读:分集进度只在分集对象上。
    func refreshAfterPlayback(server: ServerProfile) {
        refreshDetail(server: server)
        refreshEpisodes(server: server)
    }

    func selectSeason(_ season: EmbyItem, server: ServerProfile) {
        episodesTask?.cancel()
        // 同季原地刷新保留分集与手动选的集;换季才回到加载态并重新定位
        let isSameSeason = selectedSeason?.id == season.id
        selectedSeason = season
        if case .loaded = episodesState, isSameSeason {} else { episodesState = .loading }
        if !isSameSeason { didPickEpisodeManually = false }
        let myGeneration = generation
        let series = seriesID
        episodesTask = Task {
            do {
                // 优先季对象自带的 SeriesId,缺失时用当前详情项(就是这部剧)
                let seriesID = season.seriesID ?? series ?? season.id
                let episodes = try await container.connection(for: server)
                    .episodes(seriesID: seriesID, seasonID: season.id)
                guard myGeneration == generation else { return }
                episodesState = .loaded(episodes)
                resolveFocus(episodes: episodes)
            } catch let error as EmbyAPIError {
                guard myGeneration == generation else { return }
                if error == .cancelled { return }
                if case .loaded = episodesState { return }
                episodesState = .failed(LoadFailure(error))
            } catch {
                guard myGeneration == generation else { return }
                if case .loaded = episodesState { return }
                episodesState = .failed(LoadFailure(.transport(.unknown)))
            }
        }
    }

    func retryEpisodes(server: ServerProfile) {
        guard let season = selectedSeason else { return }
        selectSeason(season, server: server)
    }

    // MARK: - 内部

    private func loadSimilar(itemID: String, server: ServerProfile, generation: Int) {
        similarTask?.cancel()
        if case .loaded = similarState {} else { similarState = .loading }
        similarTask = Task {
            do {
                let items = try await container.connection(for: server)
                    .similar(itemID: itemID, limit: Self.similarLimit)
                guard generation == self.generation else { return }
                similarState = .loaded(items)
            } catch let error as EmbyAPIError {
                guard generation == self.generation, error != .cancelled else { return }
                if case .loaded = similarState { return }
                similarState = .failed(LoadFailure(error))
            } catch {
                guard generation == self.generation else { return }
                if case .loaded = similarState { return }
                similarState = .failed(LoadFailure(.transport(.unknown)))
            }
        }
    }

    /// `requestedEpisode`:从分集点进来时直接定位到它,不再问服务端。
    private func loadSeasons(server: ServerProfile, generation: Int, requestedEpisode: EmbyItem? = nil) async {
        guard let seriesID else { return }
        if case .loaded = seasonsState {} else { seasonsState = .loading }
        let seasons: [EmbyItem]
        do {
            seasons = try await container.connection(for: server).seasons(seriesID: seriesID)
        } catch let error as EmbyAPIError {
            guard generation == self.generation else { return }
            if error == .cancelled { return }
            if case .loaded = seasonsState { return }
            seasonsState = .failed(LoadFailure(error))
            return
        } catch {
            guard generation == self.generation else { return }
            if case .loaded = seasonsState { return }
            seasonsState = .failed(LoadFailure(.transport(.unknown)))
            return
        }
        guard generation == self.generation else { return }
        seasonsState = .loaded(seasons)
        guard !seasons.isEmpty else { return }

        // 定位要在拉分集之前做,否则先落第一季再跳,页面会闪。顺序见 `ServerConnection.focusEpisode`。
        let focus: EmbyItem?
        if let requestedEpisode {
            focus = requestedEpisode
        } else {
            do {
                focus = try await container.connection(for: server).focusEpisode(seriesID: seriesID)
            } catch {
                // 定位失败退回第一季,不把整页变错误态;401 等会在随后的分集请求暴露
                focus = nil
            }
        }
        guard generation == self.generation else { return }
        focusEpisodeID = focus?.id

        // 进该播那集所在的季,否则第一季
        let target = focus.flatMap { episode in
            seasons.first { $0.id == episode.seasonID }
        } ?? seasons[0]
        selectSeason(target, server: server)
    }

    /// 有续播记录定位到那一集,否则本季第一集;手动点过后不再自动改。
    private func resolveFocus(episodes: [EmbyItem]) {
        guard !didPickEpisodeManually else { return }
        if let targetID = focusEpisodeID,
           let match = episodes.first(where: { $0.id == targetID }) {
            focusedEpisode = match
            return
        }
        if let current = focusedEpisode,
           episodes.contains(where: { $0.id == current.id }) {
            return
        }
        focusedEpisode = episodes.first
    }

    /// 静默重拉当前季分集,列表不闪。
    private func refreshEpisodes(server: ServerProfile) {
        guard let season = selectedSeason else { return }
        episodesRefreshTask?.cancel()
        let myGeneration = generation
        let series = seriesID
        episodesRefreshTask = Task {
            let episodes: [EmbyItem]
            do {
                let seriesID = season.seriesID ?? series ?? season.id
                episodes = try await container.connection(for: server)
                    .episodes(seriesID: seriesID, seasonID: season.id)
            } catch {
                // 同 refreshDetail,失败保留现有列表
                return
            }
            guard myGeneration == generation else { return }
            episodesState = .loaded(episodes)
            // 换成列表里的同 id 对象,进度是新的
            if let current = focusedEpisode {
                focusedEpisode = episodes.first { $0.id == current.id } ?? current
            } else {
                resolveFocus(episodes: episodes)
            }
        }
    }
}
