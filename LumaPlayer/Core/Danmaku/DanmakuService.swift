import Foundation

/// 一个可选的弹幕库(某作品的某一集)。`/match` 候选与手动搜索结果都归一成它。
struct DanmakuCandidate: Sendable, Equatable, Identifiable, Hashable {
    let episodeID: Int64
    let animeID: Int64
    let animeTitle: String?
    let episodeTitle: String?
    let typeDescription: String?
    /// 弹弹play 给的偏移(秒,只有 `/match` 结果带)
    let shift: Double?

    var id: Int64 { episodeID }
}

/// 手动搜索的一组结果:一个作品及其剧集。
struct DanmakuSearchGroup: Sendable, Equatable, Identifiable {
    let animeID: Int64
    let animeTitle: String?
    let typeDescription: String?
    let episodes: [DanmakuCandidate]

    var id: Int64 { animeID }
}

/// 已加载好的一集弹幕。
struct LoadedDanmaku: Sendable, Equatable {
    let binding: DanmakuBindingStore.EpisodeBinding
    /// 按时间升序
    let comments: [DanmakuComment]
    /// 解析不了被丢弃的条数(如实显示,⛔ 不悄悄吞掉)
    let droppedCount: Int
}

/// 匹配的结论:要么直接拿到了弹幕,要么需要用户从候选里挑。
enum DanmakuResolution: Sendable, Equatable {
    case loaded(LoadedDanmaku)
    /// 没能自动确定。`candidates` 是 `/match` 的模糊结果(按可能性排序,可为空)
    case needsSelection(candidates: [DanmakuCandidate])
}

/// 弹幕的编排层:凭据 → 绑定 → 匹配 → 拉取 / 缓存。
///
/// 播放页只跟它说话(`DanmakuController`),⛔ 不直接碰 `DandanplayClient`。
/// 详细流程与取舍见 `docs/DANMAKU.md` §3。
actor DanmakuService {

    private let credentialStore: CredentialStore
    private let client: DandanplayClient
    private let bindings: DanmakuBindingStore
    private let cache: DanmakuCommentCache
    /// 作品剧集列表的进程内记忆:同一部剧连看几集只请求一次 `/bangumi`
    private var bangumiEpisodes: [Int64: [DandanplayBangumiEpisode]] = [:]

    /// 简繁转换:统一转简体(本 App 面向简体中文用户,与 TMDB 用 `zh-CN` 同一口径)
    static let conversion: DandanplayEndpoint.ChineseConversion = .simplified

    init(
        credentials: CredentialStore,
        client: DandanplayClient = DandanplayClient(),
        bindings: DanmakuBindingStore,
        cache: DanmakuCommentCache
    ) {
        self.credentialStore = credentials
        self.client = client
        self.bindings = bindings
        self.cache = cache
    }

    // MARK: - 自动匹配

    /// 为一条视频找弹幕。顺序:
    /// 1. 这一集手选 / 精确匹配过 → 直接用;
    /// 2. 这一部剧绑定过作品且知道集号 → 在作品剧集列表里按集号对上;
    /// 3. `/match`(只按文件名):`isMatched` 视为精确关联直接采用(官方语义),
    ///    否则把候选交给用户挑(⛔ 不自作主张取第一个模糊结果)。
    func resolve(_ query: DanmakuMediaQuery, durationSeconds: Double?) async throws -> DanmakuResolution {
        let credentials = try await requireCredentials()

        if let binding = await bindings.episode(for: query.itemKey) {
            return .loaded(try await load(binding, credentials: credentials))
        }

        if let seriesKey = query.seriesKey, let episodeNumber = query.episodeNumber,
           let series = await bindings.series(for: seriesKey),
           let episode = try await episode(number: episodeNumber, inAnime: series.animeID, credentials: credentials)
        {
            let binding = DanmakuBindingStore.EpisodeBinding(
                episodeID: episode.episodeId, animeID: series.animeID,
                animeTitle: series.animeTitle, episodeTitle: episode.episodeTitle, shift: nil)
            try await bindings.bind(binding, itemKey: query.itemKey, seriesKey: nil)
            return .loaded(try await load(binding, credentials: credentials))
        }

        let request = DandanplayMatchRequest(
            fileName: query.matchFileName,
            // ⚠️ 必须带 32 位 Hash 串,否则服务端直接回 errorCode 2(见 `placeholderFileHash`)
            fileHash: DandanplayMatchRequest.placeholderFileHash,
            fileSize: query.fileSize,
            videoDuration: durationSeconds.flatMap { $0.isFinite && $0 > 0 ? Int32(exactly: $0.rounded()) : nil },
            matchMode: DandanplayMatchRequest.fileNameOnly)
        let response = try await client.match(request, credentials: credentials)
        let candidates = (response.matches ?? []).map(DanmakuCandidate.init(match:))
        if response.isMatched == true, let exact = candidates.first {
            return .loaded(try await select(exact, for: query))
        }
        return .needsSelection(candidates: candidates)
    }

    // MARK: - 手动

    /// 关键词搜索(§3)。`episode` 只在用户想缩小到某一集时传。
    func search(keyword: String, episode: Int?) async throws -> (groups: [DanmakuSearchGroup], hasMore: Bool) {
        let credentials = try await requireCredentials()
        let response = try await client.searchEpisodes(
            anime: keyword, episode: episode.map(String.init), credentials: credentials)
        let groups = (response.animes ?? []).map { anime in
            DanmakuSearchGroup(
                animeID: anime.animeId,
                animeTitle: anime.animeTitle,
                typeDescription: anime.typeDescription,
                episodes: (anime.episodes ?? []).map {
                    DanmakuCandidate(
                        episodeID: $0.episodeId, animeID: anime.animeId, animeTitle: anime.animeTitle,
                        episodeTitle: $0.episodeTitle, typeDescription: anime.typeDescription, shift: nil)
                })
        }
        return (groups, response.hasMore ?? false)
    }

    /// 用户选定一个弹幕库:记住(这一集 + 这一部剧),然后加载。
    func select(_ candidate: DanmakuCandidate, for query: DanmakuMediaQuery) async throws -> LoadedDanmaku {
        let credentials = try await requireCredentials()
        let binding = DanmakuBindingStore.EpisodeBinding(
            episodeID: candidate.episodeID, animeID: candidate.animeID,
            animeTitle: candidate.animeTitle, episodeTitle: candidate.episodeTitle, shift: candidate.shift)
        try await bindings.bind(binding, itemKey: query.itemKey, seriesKey: query.seriesKey)
        return try await load(binding, credentials: credentials)
    }

    /// 忘掉这一集(及这一部剧)的绑定。
    func unbind(_ query: DanmakuMediaQuery) async throws {
        try await bindings.unbind(itemKey: query.itemKey, seriesKey: query.seriesKey)
    }

    // MARK: - 内部

    private func requireCredentials() async throws -> DandanplayCredentials {
        guard let credentials = try await credentialStore.dandanplayCredentials(), credentials.isComplete else {
            throw DandanplayError.credentialsMissing
        }
        return credentials
    }

    private func load(
        _ binding: DanmakuBindingStore.EpisodeBinding,
        credentials: DandanplayCredentials
    ) async throws -> LoadedDanmaku {
        if let cached = await cache.comments(forEpisode: binding.episodeID) {
            return LoadedDanmaku(binding: binding, comments: cached, droppedCount: 0)
        }
        let raw = try await client.comments(
            episodeID: binding.episodeID, conversion: Self.conversion, credentials: credentials)
        let parsed = DanmakuComment.fromDandanplay(raw)
        await cache.store(parsed.comments, forEpisode: binding.episodeID)
        return LoadedDanmaku(binding: binding, comments: parsed.comments, droppedCount: parsed.dropped)
    }

    /// 作品里集号为 `number` 的那一集。`episodeNumber` 不一定是纯数字(`S1` / `C1` 是特别篇),
    /// 只认能解析成整数且相等的那一项;对不上返回 nil(交给后面的 `/match`)。
    private func episode(
        number: Int,
        inAnime animeID: Int64,
        credentials: DandanplayCredentials
    ) async throws -> DandanplayBangumiEpisode? {
        let episodes: [DandanplayBangumiEpisode]
        if let memo = bangumiEpisodes[animeID] {
            episodes = memo
        } else {
            episodes = try await client.bangumi(animeID: animeID, credentials: credentials).episodes ?? []
            bangumiEpisodes[animeID] = episodes
        }
        return Self.episode(number: number, in: episodes)
    }

    static func episode(number: Int, in episodes: [DandanplayBangumiEpisode]) -> DandanplayBangumiEpisode? {
        let hits = episodes.filter { episode in
            guard let raw = episode.episodeNumber?.trimmingCharacters(in: .whitespaces) else { return false }
            return Int(raw) == number
        }
        // 同一集号出现多次(多季被并进一个作品)时无从判断 → 不选
        return hits.count == 1 ? hits[0] : nil
    }
}

extension DanmakuCandidate {
    init(match: DandanplayMatch) {
        self.init(
            episodeID: match.episodeId, animeID: match.animeId, animeTitle: match.animeTitle,
            episodeTitle: match.episodeTitle, typeDescription: match.typeDescription, shift: match.shift)
    }
}
