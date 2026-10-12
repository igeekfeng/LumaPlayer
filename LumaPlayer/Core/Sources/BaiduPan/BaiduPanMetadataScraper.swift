import Foundation

/// 百度来源的**在线刮削**层:把本地合成出来的条目拿去问 TMDB,补封面 / 简介 / 年份 / 集名。
///
/// ## 它在链路里的位置
///
/// `BaiduPanMetadataSynthesizer`(纯函数、只认文件名)→ **这里**(要网络)→
/// 回填 `SourceItem.poster` 等字段。合成器本身不认识网络,这一层是它之后的独立一步
/// (`docs/SOURCE_ABSTRACTION_PLAN.md` §6.3,事实来源 `docs/TMDB_API.md`)。
///
/// ## 三种条目、三种问法
///
/// | 条目 | 怎么问 | 回填什么 |
/// |---|---|---|
/// | 剧集(`.episode`) | 一次 `/3/search/tv` 拿**剧**(海报 / 简介 / 首播年)+ 一次 `/3/tv/{id}/season/{n}` 拿**分集** | 分集:**分集剧照** / 集名 / 单集简介;剧级字段兜底 |
/// | 电影 / 单条视频 | 一次 `/3/search/movie` | 海报 / 简介 / 年份 |
/// | 目录卡片(`.folder`) | 一次 `/3/search/tv`(**严格**标题一致) | 剧级海报 / 简介 / 首播年 |
///
/// ⚠️ **剧集为什么必须钻到季**:`/3/search/tv` 只给剧级海报。拿它去配每一集,
/// 结果就是「每一集的封面都长一样、还都没有集名」—— 分集剧照 / 集名 / 单集简介
/// 只有季详情端点给(`docs/TMDB_API.md` §7)。
///
/// ## 三条硬纪律
///
/// 1. **不伪造**。年份对不上、标题不敢认、季对不上,**都不填那一格** ——
///    宁可没有封面 / 没有集名,也不能端出别的片子的海报(`CLAUDE.md` 硬规则 4)。
/// 2. **不打断浏览**。没 token / token 无效 / 连不上,都只记在
///    `lastFailureDescription` 里给 UI 提一句,目录照常能看。
/// 3. **不重复问**。搜索按「标题 + 年份 + 是不是剧」记一份(含「查过但没命中」),
///    季详情按「剧 id + 季」记一份,重进同一个目录不再发请求。
///
/// ⚠️ 它**不发任何写请求**,也不下载图片 —— 图片由 `PosterImage` 按 `ImageDescriptor.remote`
/// 走既有通路(`image.tmdb.org` 是公开 CDN,不带认证头)。
actor BaiduPanMetadataScraper {

    /// 一次最多同时发几个请求。
    ///
    /// TMDB 的上限约 40 次/秒(`docs/TMDB_API.md` §6),这里压到 4:刮削是浏览的
    /// **附加**动作,⛔ 不与用户正在等的目录请求抢带宽,也避免一屏三十个文件打出一串并发。
    static let maxConcurrentRequests = 4

    /// 季号解析不出来时,拿哪一季去问。
    ///
    /// ⚠️ 这是一个**明说的取舍**:`琅琊榜/01.mp4` 这种平铺存法里文件名没写季号,
    /// 而 `01.mp4` 是「这一季第 1 集」在绝大多数情况下就是第 1 季(Emby 的文件名解析器
    /// 也是这个口径)。认得出季号时(文件名 `SxxExx` / 季文件夹 `第13季/`)一律以**认出来的**
    /// 为准 —— 有 13 季的剧一旦判错季,就会拿第 1 季的剧照去配第 13 季的文件。
    /// 这一档的局限记在 `docs/KNOWN_ISSUES.md`。
    static let seasonWhenUnknown = 1

    private let credentials: CredentialStore
    private let client: TMDBClient

    /// 一次搜索的键。同一个键问出来的结果不随会话变化,所以内存缓存足够;
    /// 进程重启后重新问一遍是可接受的代价(刮削是低频动作)。
    ///
    /// ⚠️ 剧集条目与**同名目录卡片**共用同一个键(都是「剧名 + 无年份 + 是剧」),
    /// 所以「进剧集目录」与「看外层目录」不会把同一次搜索问两遍。
    struct QueryKey: Hashable, Sendable {
        let title: String
        let year: Int?
        let isSeries: Bool
    }

    /// 一季分集的键:剧 id + 季号。
    struct SeasonKey: Hashable, Sendable {
        let seriesID: Int
        let season: Int
    }

    /// 一组剧集条目:同一个「剧名 + 年份 + 季」共用一次搜索 + 一次季详情。
    struct SeriesKey: Hashable, Sendable {
        let title: String
        let year: Int?
        let season: Int

        init(title: String, year: Int?, season: Int?) {
            self.title = title
            self.year = year
            self.season = season ?? BaiduPanMetadataScraper.seasonWhenUnknown
        }
    }

    /// 查过的**搜索**结果。`nil` = 查过但**没有可用的命中**。
    ///
    /// ⚠️ 之所以要连「没命中」一起缓存:认不出来的文件(发布组命名法等)如果每次都重查,
    /// 每进一次目录就白烧一轮请求。
    /// 值类型是 `TMDBMatch?`,写的时候用 `updateValue(_:forKey:)` 而不是下标赋值 ——
    /// 下标赋 `nil` 是**删键**,那样「查过没命中」这件事就丢了(见 `searchMatch`)。
    private var searchCache: [QueryKey: TMDBMatch?] = [:]

    /// 查过的**季详情报表**(集号 → 分集)。只在**成功**时写(以及 404 这种确定性失败写成空表),
    /// 传输类失败不写 —— 下次进目录要能重试。
    private var seasonCache: [SeasonKey: [Int: TMDBEpisode]] = [:]

    /// 最后一次刮削失败的可读原因(nil = 没失败)。
    /// ⛔ 不上模型层:它只用来给界面提一句,不改变任何条目(`LocalResumeReporting` 同一处置)。
    private(set) var lastFailureDescription: String?

    init(credentials: CredentialStore, client: TMDBClient = TMDBClient()) {
        self.credentials = credentials
        self.client = client
    }

    // MARK: - 入口

    /// 给整个目录的条目补 TMDB 的封面 / 简介 / 年份 / 集名。
    ///
    /// ⛔ 不抛错:调用方是「目录已经列出来之后」的第二趟,刮削失败不该让浏览变错。
    /// 失败原因留在 `lastFailureDescription`。
    func enrich(_ items: [SourceItem]) async -> [SourceItem] {
        let token: String
        do {
            guard let stored = try await credentials.tmdbReadAccessToken(),
                  !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // 没填 token = 用户没开刮削,不是失败(设置页的文案就是这么承诺的)
                return items
            }
            token = stored
        } catch {
            // ⛔ 读凭据失败不假装「没配置」:如实记下来
            lastFailureDescription = "读取 TMDB 凭据失败"
            return items
        }
        lastFailureDescription = nil
        // 分三步:**先剧集**(要钻季详情),再单条电影 / 视频,最后目录卡片。
        // 三步各只碰自己那几种 `kind`,互不重叠。
        let episodes = await enrichEpisodes(items: items, token: token)
        let singles = await enrichSingles(items: episodes, token: token)
        return await enrichFolders(items: singles, token: token)
    }

    // MARK: - 剧集(剧 + 季详情)

    /// 剧集条目:按「剧名 + 年份 + 季」分组,每组一次搜索 + 一次季详情。
    private func enrichEpisodes(items: [SourceItem], token: String) async -> [SourceItem] {
        var offsetsByKey: [SeriesKey: [Int]] = [:]
        for (offset, item) in items.enumerated()
        where item.kind == .episode && Self.isScrapable(item) {
            let key = SeriesKey(title: item.title, year: item.year, season: item.seasonNumber)
            offsetsByKey[key, default: []].append(offset)
        }
        guard !offsetsByKey.isEmpty else { return items }

        let bundles = await inBatches(Array(offsetsByKey.keys)) { key in
            (key, await self.seriesBundle(for: key, token: token))
        }
        var bundleByKey: [SeriesKey: SeriesBundle] = [:]
        for (key, bundle) in bundles {
            // 没命中剧 → 这一组什么都不补(不伪造,硬规则 1)
            if let bundle { bundleByKey[key] = bundle }
        }

        var result = items
        for (key, offsets) in offsetsByKey {
            guard let bundle = bundleByKey[key] else { continue }
            for offset in offsets {
                result[offset] = Self.applyEpisode(bundle, to: items[offset])
            }
        }
        return result
    }

    /// 一次「剧的刮削结果」:剧级命中 + 该季的分集表。
    private struct SeriesBundle: Sendable {
        let series: TMDBMatch
        /// 集号 → 分集。空 = 剧命中了但季详情取不到(剧级信息照补)
        let episodes: [Int: TMDBEpisode]
    }

    /// 查一组的剧 + 该季分集。任一步拿不到就返回 nil(⛔ 不拿别的剧来凑)。
    private func seriesBundle(for key: SeriesKey, token: String) async -> SeriesBundle? {
        guard let series = await searchMatch(
            title: key.title, year: key.year, isSeries: true, token: token) else {
            return nil
        }
        let episodes = await seasonEpisodes(
            seriesID: series.tmdbID, season: key.season, token: token)
        return SeriesBundle(series: series, episodes: episodes)
    }

    /// 拉一季的分集,折成「集号 → 分集」表。
    ///
    /// ⛔ **不按数组下标猜集号**:分集表里 `episode_number` 才是集号
    /// (`docs/TMDB_API.md` §7),下标与集号可能因特别篇 / 缺失而不一致。
    private func seasonEpisodes(seriesID: Int, season: Int, token: String) async -> [Int: TMDBEpisode] {
        let key = SeasonKey(seriesID: seriesID, season: season)
        if let cached = seasonCache[key] { return cached }

        let episodes: [TMDBEpisode]
        do {
            episodes = try await client.seasonDetails(
                seriesID: seriesID, seasonNumber: season, token: token)
        } catch is CancellationError {
            // 用户换了目录 / 关页面:这次不算失败,也不写缓存(下次还要问)
            return [:]
        } catch let error as TMDBError {
            // ⛔ 不静默吞:记下最后一条失败原因,但**不影响目录**
            lastFailureDescription = error.userMessage
            // 404 = 这一季就是不存在,是**确定性**答案 → 记住不再重问;
            // 其余(401 / 429 / 传输)不写缓存,下次进目录要能重试。
            if case .notFound = error { seasonCache[key] = [:] }
            return [:]
        } catch {
            lastFailureDescription = "刮削失败:\(error)"
            return [:]
        }
        var table: [Int: TMDBEpisode] = [:]
        for episode in episodes { table[episode.episodeNumber] = episode }
        seasonCache[key] = table
        return table
    }

    /// 一集的回填:分集剧照 → 封面;集名 → `episodeTitle`;单集简介(退剧级) → `overview`。
    ///
    /// ⚠️ 剧级海报**不**往分集上套 —— 那正是「每集的封面都是剧海报」的成因。
    /// 分集没有剧照时**留空**(UI 降级成图标卡),由 `PosterImage` 去显示占位图。
    private static func applyEpisode(_ bundle: SeriesBundle, to item: SourceItem) -> SourceItem {
        let episode = item.episodeNumber.flatMap { bundle.episodes[$0] }
        var poster: ImageDescriptor?
        if let episode, let url = episode.stillURL, let path = nonEmpty(episode.stillPath) {
            poster = .remote(
                ownerID: item.ref.sourceID,
                url: url,
                // TMDB 图床是公开 CDN,不带认证头(`docs/TMDB_API.md` §8)
                headers: [:],
                cacheKey: ImageDescriptor.tmdbPosterKey(
                    sourceID: item.ref.sourceID,
                    posterPath: path,
                    size: TMDBImage.stillSize
                )
            )
        }
        return item.withScrapedMetadata(
            poster: poster,
            // 单集简介优先;这一集没有简介就退剧级简介(剧的简介对这一集也成立)
            overview: nonEmpty(episode?.overview) ?? bundle.series.overview,
            year: bundle.series.year,
            episodeTitle: nonEmpty(episode?.name)
        )
    }

    // MARK: - 单条电影 / 视频

    /// 电影 / 单条视频:各查一次 `/3/search/movie`。
    private func enrichSingles(items: [SourceItem], token: String) async -> [SourceItem] {
        let offsets = items.indices.filter {
            Self.isScrapable(items[$0]) && items[$0].kind != .episode
        }
        guard !offsets.isEmpty else { return items }

        let matches = await inBatches(offsets) { offset -> (Int, TMDBMatch?) in
            let item = items[offset]
            return (offset, await self.searchMatch(
                title: item.title, year: item.year, isSeries: false, token: token))
        }
        var result = items
        for (offset, match) in matches {
            guard let match else { continue }
            result[offset] = Self.apply(match, to: items[offset])
        }
        return result
    }

    // MARK: - 目录卡片(按剧查)

    /// 目录卡片:按**剧**查一次,只认标题完全一致的命中(见 `folderMatch`)。
    private func enrichFolders(items: [SourceItem], token: String) async -> [SourceItem] {
        let offsets = items.indices.filter { Self.isScrapableFolder(items[$0]) }
        guard !offsets.isEmpty else { return items }

        let matches = await inBatches(offsets) { offset -> (Int, TMDBMatch?) in
            let item = items[offset]
            return (offset, await self.folderMatch(folderTitle: item.title, token: token))
        }
        var result = items
        for (offset, match) in matches {
            guard let match else { continue }
            result[offset] = Self.apply(match, to: items[offset])
        }
        return result
    }

    /// 目录卡片按剧查,且**只认标题归一化后完全一致**的命中。
    ///
    /// ⚠️ 为什么比单条文件更严:目录名没有年份、也没有文件名那种发布标记帮特指,
    /// 一旦放宽(比如「唯一结果就认」),一个叫《Movies》的目录就可能套上某部同名剧的海报
    /// —— 那正是硬规则 4 要避免的假数据。对齐不上时**宁可不给封面**。
    ///
    /// ⛔ 只查剧端点:电影目录(片名做目录名的存法)这次**不刮** —— 一个目录查两次
    /// (剧 + 电影)会让 50 个目录的片库多烧一倍请求。这是**已知限制**,见 `docs/KNOWN_ISSUES.md`。
    private func folderMatch(folderTitle: String, token: String) async -> TMDBMatch? {
        // 复用剧集搜索的缓存与「选命中项」规则(键与剧集组相同)
        guard let match = await searchMatch(
            title: folderTitle, year: nil, isSeries: true, token: token) else {
            return nil
        }
        guard let title = match.title,
              Self.normalizedTitle(title) == Self.normalizedTitle(folderTitle) else {
            return nil
        }
        return match
    }

    // MARK: - 一次搜索

    /// 查一次「标题 + 年份 + 是不是剧」(带缓存)。不抛错 —— 失败折成 nil + `lastFailureDescription`。
    private func searchMatch(
        title: String,
        year: Int?,
        isSeries: Bool,
        token: String
    ) async -> TMDBMatch? {
        let key = QueryKey(title: title, year: year, isSeries: isSeries)
        // 注意:这里命中缓存时返回的可能是 nil(查过、没命中),那也要直接返回 ——
        // 所以判据是「键在不在」,不是「值是不是 nil」。用 `updateValue` 写、用下标读
        // 得到的 `TMDBMatch??` 恰好能区分这两件事。
        if let cached = searchCache[key] { return cached }

        let matches: [TMDBMatch]
        do {
            matches = try await client.search(
                title: title, year: year, isSeries: isSeries, token: token)
        } catch is CancellationError {
            // 用户换了目录 / 关页面:这次不算失败,也不写缓存(下次还要问)
            return nil
        } catch let error as TMDBError {
            // ⛔ 不静默吞:记下最后一条失败原因,但**不影响目录**
            lastFailureDescription = error.userMessage
            // 网络 / token 类失败不写缓存:下次进目录要能重试
            return nil
        } catch {
            lastFailureDescription = "刮削失败:\(error)"
            return nil
        }

        let selected = Self.selectMatch(matches, title: title, year: year)
        searchCache.updateValue(selected, forKey: key)
        return selected
    }

    // MARK: - 并发调度

    /// 分批并发跑(每批最多 `maxConcurrentRequests` 个),等这一批全回来再开下一批。
    ///
    /// ⚠️ 为什么要限:TMDB 上限约 40 次/秒,而一屏可能有三十个文件;
    /// 无节制地一次打出全屏请求既容易触顶,也会跟用户正在等的目录请求抢带宽。
    private func inBatches<Element: Sendable, Result: Sendable>(
        _ elements: [Element],
        _ body: @Sendable @escaping (Element) async -> Result
    ) async -> [Result] {
        var results: [Result] = []
        var cursor = 0
        while cursor < elements.count {
            let end = min(cursor + Self.maxConcurrentRequests, elements.count)
            let batch = Array(elements[cursor..<end])
            cursor = end
            await withTaskGroup(of: Result.self) { group in
                for element in batch {
                    group.addTask { await body(element) }
                }
                for await result in group { results.append(result) }
            }
        }
        return results
    }

    // MARK: - 命中判定(纯函数,可单测)

    /// 从搜索结果里挑一个**敢用**的命中项。
    ///
    /// 顺序即优先级(⛔ 不猜):
    /// 1. 年份解析出来了 → 只认**年份完全一致**的;一个都没有就不认 ——
    ///    同名翻拍片(`The Thing` / `沙丘`)靠年份区分,让步一步就会配错片;
    /// 2. 没有年份 → 标题归一化后完全一致的;
    /// 3. 再否则,**只有唯一一个结果**时才认(搜索能收敛到一条,说明够特指);
    /// 4. 都不满足 → `nil`(UI 保持图标卡)。
    static func selectMatch(_ matches: [TMDBMatch], title: String, year: Int?) -> TMDBMatch? {
        if let year {
            return matches.first { $0.year == year }
        }
        let normalized = normalizedTitle(title)
        if let exact = matches.first(where: { $0.title.map(normalizedTitle) == normalized }) {
            return exact
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// 标题归一化:大小写、空格、标点都不算差别(`Fight Club` = `fightclub`)。
    /// 中文字符按 `isLetter` 保留。
    static func normalizedTitle(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 空串与 `nil` 一样看待 —— TMDB 偶尔给 `""` 而不是 `null`(`docs/TMDB_API.md` §7)。
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// 这一条值不值得问 TMDB(**单条文件**:电影 / 剧集 / 视频)。
    ///
    /// - 只刮**可播的视频条目**:目录 / 图片 / 音频不发(音频走 TMDB 只会拿回一部同名的电影);
    /// - 标题必须是**从文件名解析出来的**(`metadataOrigin == .filename`)。
    ///   退回文件名的那一类(`video.mp4` / `IMG_0451.MOV`)问 TMDB 只会拿回一堆
    ///   风马牛不相及的封面 —— 那正是「用假数据占位」。
    static func isScrapable(_ item: SourceItem) -> Bool {
        guard item.metadataOrigin == .filename else { return false }
        switch item.kind {
        case .movie, .episode, .video: return !item.title.isEmpty
        case .audio, .image, .folder, .unknown: return false
        }
    }

    /// 目录卡片值不值得问 TMDB(按**剧**查)。
    ///
    /// 与 `isScrapable` 分开:目录恒为 `metadataOrigin == .none`(没有文件名可解析),
    /// 而它的标题**就是**目录名 —— 对「目录名是剧名」这种存法,那反而是最可靠的剧名来源。
    static func isScrapableFolder(_ item: SourceItem) -> Bool {
        item.kind == .folder && !item.title.isEmpty
    }

    /// 把剧级命中项折回条目(电影 / 视频 / 目录卡片用)。
    ///
    /// 封面按 `ImageDescriptor.remote` 走既有图片通路;`cacheKey` 用 `poster_path`
    /// 当版本段(`ImageDescriptor.tmdbPosterKey`)。
    private static func apply(_ match: TMDBMatch, to item: SourceItem) -> SourceItem {
        var poster: ImageDescriptor?
        if let url = match.posterURL, let path = match.posterPath {
            poster = .remote(
                ownerID: item.ref.sourceID,
                url: url,
                // TMDB 图床是公开 CDN,不带认证头(`docs/TMDB_API.md` §4)
                headers: [:],
                cacheKey: ImageDescriptor.tmdbPosterKey(
                    sourceID: item.ref.sourceID,
                    posterPath: path,
                    size: TMDBImage.posterSize
                )
            )
        }
        return item.withScrapedMetadata(
            poster: poster,
            overview: match.overview,
            year: match.year
        )
    }
}