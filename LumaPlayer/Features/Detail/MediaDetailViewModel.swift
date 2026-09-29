import Foundation

/// 详情页的数据。
///
/// 列表接口返回的字段比单项接口少(API_CONTRACT.md 3.2),所以选中一项后
/// **必须**用 `/Users/{UserId}/Items/{Id}` 再取一次完整详情,
/// 不能拿列表里的对象直接当详情展示。
///
/// 剧集走「单页」模型:季与分集就在这同一页里,页面只有**一个**播放按钮,
/// 它作用于 `focusedEpisode` —— 进页面时自动定位(有续播记录定位到那一集,
/// 否则第一集),点分集行只是就地换定位,不再跳到另一个详情页。
@MainActor
@Observable
final class MediaDetailViewModel {
    private let container: AppContainer

    private(set) var detailState: LoadState<EmbyItem> = .idle
    private(set) var seasonsState: LoadState<[EmbyItem]> = .idle
    private(set) var episodesState: LoadState<[EmbyItem]> = .idle
    private(set) var selectedSeason: EmbyItem?
    /// 播放按钮作用于的那一集(只有剧集才有)。nil = 还没定位到任何一集。
    private(set) var focusedEpisode: EmbyItem?
    /// 相似推荐(电影 / 剧集才查)。失败或为空时页面不显示这一区块 ——
    /// 它是附加信息,不值得为它占一块错误页。
    private(set) var similarState: LoadState<[EmbyItem]> = .idle
    /// 标记已看 / 收藏失败的提示(写操作失败必须让用户知道,不能静默回滚)
    var userDataError: String?
    /// 正在写入 UserData 的条目 Id(按钮据此禁用,防止连点发出相反的两次请求)
    private(set) var updatingItemIDs: Set<String> = []

    private var seriesID: String?
    /// 当前内容对应的「服务器 + 打开的条目」。同一个键再次 `load` 是原地刷新:
    /// 保留已有内容、不切回加载态(已有缓存时不该闪 loading)
    private var loadedKey: String?
    /// 服务端报的「最近可续播」的集 Id;用来决定初始定位在哪一集。
    private var focusEpisodeID: String?
    /// 用户手动点过分集。手动选过之后,切季以外的自动定位不再覆盖他的选择。
    private var didPickEpisodeManually = false
    private var generation = 0
    private var detailTask: Task<Void, Never>?
    private var seasonsTask: Task<Void, Never>?
    private var episodesTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var episodesRefreshTask: Task<Void, Never>?
    private var similarTask: Task<Void, Never>?

    /// 相似推荐的条数(与 Emby Web 同为一行 12 个)
    static let similarLimit = 12

    init(container: AppContainer) {
        self.container = container
    }

    /// 加载某一项的详情;剧集额外加载季,并自动定位到该播的那一集。
    func load(item: EmbyItem, server: ServerProfile) {
        detailTask?.cancel()
        seasonsTask?.cancel()
        episodesTask?.cancel()
        refreshTask?.cancel()
        episodesRefreshTask?.cancel()
        similarTask?.cancel()
        generation += 1
        let myGeneration = generation

        // 同一台服务器上的同一项、且已经有内容:原地刷新,不回退到 loading,
        // 新数据到达后直接替换(失败则保留旧内容,与 refreshDetail 同一立场)
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
        }

        detailTask = Task {
            do {
                let connection = container.connection(for: server)
                // 从「继续观看」「下一集」等处点进来的是分集:和 Emby Web 一样打开
                // 它所属的整部剧,并定位到这一集,而不是只显示单集(否则没法切别的集)。
                // 列表对象通常自带 SeriesId;没有时先取一次分集详情拿到它。
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
                // 只有剧集才有季 / 分集(API_CONTRACT.md 3.2)
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

    /// 切换已看。作用于剧集(Series)时服务端会把整部剧的分集一起标上,
    /// 所以成功后要重拉分集与详情,而不只是改这一项。
    func togglePlayed(_ item: EmbyItem, server: ServerProfile) {
        let target = !(item.userData?.played ?? false)
        writeUserData(item, server: server, failureVerb: target ? "标记为已看" : "标记为未看") { connection in
            try await connection.setPlayed(itemID: item.id, played: target)
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
                // 已看会连带改变父子项(剧 ↔ 集)的状态与续播定位,以服务端为准重读一次
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

    /// 用服务端返回的 UserData 就地替换页面上所有同 Id 的对象。
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

    /// 用户点了分集列表里的某一集:就地换定位,不跳页。
    func selectEpisode(_ episode: EmbyItem) {
        didPickEpisodeManually = true
        focusedEpisode = episode
    }

    /// 播放结束后按服务端重读当前详情(docs/PITFALLS.md Q22)。
    ///
    /// 续播位置与已看状态以 `/Users/{UserId}/Items/{Id}` 为准 —— 服务端还有
    /// MinResumePct / MaxResumePct / 最短可续播时长等规则,不在客户端复刻。
    ///
    /// 与 `load` 的区别:
    /// - 不切回加载态,也不重拉季与分集:只是一次后台校正,页面不该闪;
    /// - 失败时**保留现有内容**:旧详情仍可用,为一次后台校正把整页换成错误页
    ///   得不偿失;401 等问题会在用户下一次操作时由正常路径暴露。
    func refreshDetail(server: ServerProfile) {
        guard case .loaded(let current) = detailState else { return }
        refreshTask?.cancel()
        let myGeneration = generation
        refreshTask = Task {
            let full: EmbyItem
            do {
                full = try await container.connection(for: server).item(id: current.id)
            } catch {
                // 见上:刻意保留现有内容,不改 detailState
                return
            }
            // 期间换了条目(generation 已变)就丢弃,不能把上一项的详情写回来
            guard myGeneration == generation else { return }
            detailState = .loaded(full)
        }
    }

    /// 播完一集后的完整校正:详情 + 当前季分集 + 定位集。
    ///
    /// 播的是分集时,只重读剧的详情拿不到这一集的新进度(剧对象上没有),
    /// 所以还要把当前季的分集重拉一次,进度条才会动。
    func refreshAfterPlayback(server: ServerProfile) {
        refreshDetail(server: server)
        refreshEpisodes(server: server)
    }

    /// 选择某一季并加载它的分集。
    func selectSeason(_ season: EmbyItem, server: ServerProfile) {
        episodesTask?.cancel()
        // 同一季的原地刷新(详情页重载)保留分集列表与用户手动选的集;
        // 换季才回到加载态、并重新定位(上一季里手动选的集不适用于这一季)
        let isSameSeason = selectedSeason?.id == season.id
        selectedSeason = season
        if case .loaded = episodesState, isSameSeason {} else { episodesState = .loading }
        if !isSameSeason { didPickEpisodeManually = false }
        let myGeneration = generation
        let series = seriesID
        episodesTask = Task {
            do {
                // `Shows/{Id}/Episodes` 需要 SeriesId:优先季对象自带的 SeriesId,
                // 缺失时退回当前详情项的 Id(它就是这部剧)
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

    /// 重试分集(页脚的失败态用)。
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

    /// - Parameter requestedEpisode: 用户点进来的那一集(从分集进剧集页时)。
    ///   有它就直接定位到它,不再问服务端「该播哪一集」。
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

        // 定位要在拉分集**之前**做:否则会先落在第一季、再跳到该播的那一集,页面闪一下。
        // 顺序是 NextUp → 可续播 → 第一集,理由见 `ServerConnection.focusEpisode`。
        let focus: EmbyItem?
        if let requestedEpisode {
            focus = requestedEpisode
        } else {
            do {
                focus = try await container.connection(for: server).focusEpisode(seriesID: seriesID)
            } catch {
                // 只是一次定位:拿不到就回退到第一季,不把整页变成错误态。
                // 紧随其后的分集请求走同一条连接,同类问题(如 401)会在那里正常暴露。
                focus = nil
            }
        }
        guard generation == self.generation else { return }
        focusEpisodeID = focus?.id

        // 该播的集在哪个季就进哪个季;拿不到它的季(或压根定位不到)就进第一季。
        let target = focus.flatMap { episode in
            seasons.first { $0.id == episode.seasonID }
        } ?? seasons[0]
        selectSeason(target, server: server)
    }

    /// 决定播放按钮作用于哪一集:有续播记录就定位到那一集,否则这一季的第一集。
    ///
    /// 用户手动点过之后不再自动改动(切季会重置这个标志)。
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

    /// 静默重拉当前季的分集:播完一集后进度条要动,但列表不该闪。
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
                // 同 refreshDetail:一次后台校正失败就保留现有列表
                return
            }
            guard myGeneration == generation else { return }
            episodesState = .loaded(episodes)
            // 换成列表里的同 id 对象:它的字段更齐,进度也是新的
            if let current = focusedEpisode {
                focusedEpisode = episodes.first { $0.id == current.id } ?? current
            } else {
                resolveFocus(episodes: episodes)
            }
        }
    }
}
