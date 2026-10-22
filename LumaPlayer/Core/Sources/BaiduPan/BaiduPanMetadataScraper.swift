import Foundation

/// 百度来源的在线刮削:拿合成器(`BaiduPanMetadataSynthesizer`)的条目问 TMDB,
/// 补封面 / 简介 / 年份 / 集名(`docs/TMDB_API.md`)。只读,不下载图片(交给 `PosterImage`)。
///
/// | 条目 | 怎么问 | 回填 |
/// |---|---|---|
/// | 剧集 | `/3/search/tv` + `/3/tv/{id}/season/{n}` | 分集剧照 / 集名 / 单集简介;剧级字段兜底 |
/// | 电影 / 单条视频 | `/3/search/movie` | 海报 / 简介 / 年份 |
/// | 目录卡片 | `/3/search/tv`,标题严格一致 | 剧级海报 / 简介 / 首播年 |
///
/// 名称带 `{tmdbid-N}` 的跳过搜索直接按 id 取;标签不分影 / 剧:剧集按剧查,
/// 目录卡片先剧后电影,单条视频先电影后剧(前一个 404 才查后一个)。
/// 剧集必须钻到季:搜索只给剧级海报,分集剧照 / 集名只有季详情给(§7)。
///
/// - 不伪造:年份 / 标题 / 季对不上就不填,⛔ 不端出别的片子的海报(`CLAUDE.md` 硬规则 4)。
/// - 不打断浏览:失败只记 `lastFailureDescription`,目录照常。
/// - 不重复问:内存缓存连「查过没命中」与 404 一起记;取消、传输、认证类失败不记,下次能重试。
actor BaiduPanMetadataScraper {

    /// TMDB 上限约 40 次/秒(`docs/TMDB_API.md` §6);压到 4,不与目录请求抢带宽。
    static let maxConcurrentRequests = 4

    /// 季号解析不出时按第 1 季问(同 Emby 口径;局限见 `docs/KNOWN_ISSUES.md`)。认得出季号时一律以认出的为准。
    static let seasonWhenUnknown = 1

    private let credentials: CredentialStore
    private let client: TMDBClient
    /// 按条目记最终补丁、跨重启有效的落盘缓存;下面的内存缓存按请求去重、活到进程结束。nil = 不落盘。
    private let cache: BaiduPanScrapeCache?

    /// 剧集条目与同名目录卡片共用同一个键,同一次搜索不问两遍。
    struct QueryKey: Hashable, Sendable {
        let title: String
        let year: Int?
        let isSeries: Bool
    }

    struct SeasonKey: Hashable, Sendable {
        let seriesID: Int
        let season: Int
    }

    /// 影与剧分开:同一个数字 id 在两个端点下是不同作品。
    struct DetailsKey: Hashable, Sendable {
        let id: Int
        let isSeries: Bool
    }

    /// 同一组共用一次搜索 + 一次季详情。`tmdbID` 非空时直接按 id 取,`title` / `year` 只用于分组。
    struct SeriesKey: Hashable, Sendable {
        let title: String
        let year: Int?
        let season: Int
        let tmdbID: Int?

        init(title: String, year: Int?, season: Int?, tmdbID: Int? = nil) {
            self.title = title
            self.year = year
            self.season = season ?? BaiduPanMetadataScraper.seasonWhenUnknown
            self.tmdbID = tmdbID
        }
    }

    /// 值 nil = 查过没命中。⛔ 写入用 `updateValue(_:forKey:)`:下标赋 nil 是删键。
    private var searchCache: [QueryKey: TMDBMatch?] = [:]

    /// 值 nil = 这个端点 404
    private var detailsCache: [DetailsKey: TMDBMatch?] = [:]

    /// 集号 → 分集;404 记成空表
    private var seasonCache: [SeasonKey: [Int: TMDBEpisode]] = [:]

    /// 详情页专用(`seriesProfile`);值 nil = 404
    private var creditsCache: [DetailsKey: TMDBCredits?] = [:]

    /// 只给界面提一句,⛔ 不进模型层
    private(set) var lastFailureDescription: String?

    init(
        credentials: CredentialStore,
        client: TMDBClient = TMDBClient(),
        cache: BaiduPanScrapeCache? = nil
    ) {
        self.credentials = credentials
        self.client = client
        self.cache = cache
    }

    // MARK: - 入口

    /// 不抛错(目录已列出后的第二趟)。返回顺序与入参一致。
    func enrich(_ items: [SourceItem]) async -> [SourceItem] {
        // 落盘缓存命中的条目不再发请求
        let (cached, cachedIDs) = await applyCached(items)
        let pending = cached.filter {
            !cachedIDs.contains($0.ref.itemID) && Self.isCacheable($0)
        }

        let token: String
        do {
            guard let stored = try await credentials.tmdbReadAccessToken(),
                  !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // 没填 token = 没开刮削,不是失败
                return cached
            }
            token = stored
        } catch {
            // 读凭据失败不当作「没配置」
            lastFailureDescription = "读取 TMDB 凭据失败"
            return cached
        }
        guard !pending.isEmpty else { return cached }
        lastFailureDescription = nil
        // 三步各只碰自己的 `kind`,互不重叠
        let episodes = await enrichEpisodes(items: pending, token: token)
        let singles = await enrichSingles(items: episodes, token: token)
        let enriched = await enrichFolders(items: singles, token: token)
        await storeCache(enriched)
        // 按身份并回,保持入参顺序
        let byID = Dictionary(
            enriched.map { ($0.ref.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        return cached.map { byID[$0.ref.itemID] ?? $0 }
    }

    // MARK: - 落盘缓存

    private static func isCacheable(_ item: SourceItem) -> Bool {
        isScrapable(item) || isScrapableFolder(item)
    }

    /// - Returns: 贴好的条目 + 命中的 id 集合。
    /// 只用 `withScrapedMetadata` 贴:它只补空位,不盖掉网盘里用户放的封面。
    private func applyCached(_ items: [SourceItem]) async -> ([SourceItem], Set<String>) {
        guard let cache else { return (items, []) }
        var result = items
        var hits: Set<String> = []
        for (offset, item) in items.enumerated() where Self.isCacheable(item) {
            guard let entry = await cache.entry(
                sourceID: item.ref.sourceID, fsID: item.ref.itemID) else { continue }
            result[offset] = item.withScrapedMetadata(
                poster: entry.poster.map(ImageDescriptor.init(snapshot:)),
                overview: entry.overview,
                year: entry.year,
                episodeTitle: entry.episodeTitle,
                tmdbID: entry.tmdbID
            )
            hits.insert(item.ref.itemID)
        }
        return (result, hits)
    }

    private func storeCache(_ items: [SourceItem]) async {
        guard let cache else { return }
        var perSource: [UUID: [String: BaiduPanScrapeCache.Entry]] = [:]
        for item in items where Self.isCacheable(item) {
            let entry = BaiduPanScrapeCache.Entry(
                // ⛔ 百度封面(`dlink` 8 小时过期)不进这份 30 天的缓存
                poster: item.poster?.hasExpiringURL == false ? item.poster?.snapshot : nil,
                overview: item.overview,
                year: item.year,
                episodeTitle: item.episodeTitle,
                tmdbID: item.tmdbID,
                savedAt: Date()
            )
            guard !entry.isEmpty else { continue }
            perSource[item.ref.sourceID, default: [:]][item.ref.itemID] = entry
        }
        for (sourceID, entries) in perSource {
            await cache.store(sourceID: sourceID, entries: entries)
        }
    }

    // MARK: - 剧集(剧 + 季详情)

    private func enrichEpisodes(items: [SourceItem], token: String) async -> [SourceItem] {
        var offsetsByKey: [SeriesKey: [Int]] = [:]
        for (offset, item) in items.enumerated()
        where item.kind == .episode && Self.isScrapable(item) {
            let key = SeriesKey(
                title: item.title, year: item.year, season: item.seasonNumber, tmdbID: item.tmdbID)
            offsetsByKey[key, default: []].append(offset)
        }
        guard !offsetsByKey.isEmpty else { return items }

        let bundles = await inBatches(Array(offsetsByKey.keys)) { key in
            (key, await self.seriesBundle(for: key, token: token))
        }
        var bundleByKey: [SeriesKey: SeriesBundle] = [:]
        for (key, bundle) in bundles {
            // 没命中剧 → 这一组什么都不补
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

    private struct SeriesBundle: Sendable {
        let series: TMDBMatch
        /// 空 = 季详情取不到,剧级信息照补
        let episodes: [Int: TMDBEpisode]
    }

    private func seriesBundle(for key: SeriesKey, token: String) async -> SeriesBundle? {
        let series: TMDBMatch?
        if let id = key.tmdbID {
            series = await detailsMatch(id: id, isSeries: true, token: token)
        } else {
            series = await searchMatch(
                title: key.title, year: key.year, isSeries: true, token: token)
        }
        guard let series else { return nil }
        let episodes = await seasonEpisodes(
            seriesID: series.tmdbID, season: key.season, token: token)
        return SeriesBundle(series: series, episodes: episodes)
    }

    /// 按显式 id 直取。失败折成 nil + `lastFailureDescription`。
    private func detailsMatch(id: Int, isSeries: Bool, token: String) async -> TMDBMatch? {
        let key = DetailsKey(id: id, isSeries: isSeries)
        if let cached = detailsCache[key] { return cached }

        let match: TMDBMatch
        do {
            match = try await client.details(id: id, isSeries: isSeries, token: token)
        } catch is CancellationError {
            // 换目录 / 关页面:不算失败,不写缓存
            return nil
        } catch let error as TMDBError {
            lastFailureDescription = error.userMessage
            if case .notFound = error { detailsCache.updateValue(nil, forKey: key) }
            return nil
        } catch {
            lastFailureDescription = "刮削失败:\(error)"
            return nil
        }
        detailsCache.updateValue(match, forKey: key)
        return match
    }

    /// ⛔ 按 `episode_number` 建表,不按数组下标(`docs/TMDB_API.md` §7)
    private func seasonEpisodes(seriesID: Int, season: Int, token: String) async -> [Int: TMDBEpisode] {
        let key = SeasonKey(seriesID: seriesID, season: season)
        if let cached = seasonCache[key] { return cached }

        let episodes: [TMDBEpisode]
        do {
            episodes = try await client.seasonDetails(
                seriesID: seriesID, seasonNumber: season, token: token)
        } catch is CancellationError {
            return [:]
        } catch let error as TMDBError {
            lastFailureDescription = error.userMessage
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

    /// 分集剧照 → 封面,集名 → `episodeTitle`,单集简介(退剧级)→ `overview`。
    /// ⛔ 剧级海报不往分集上套;没有剧照就留空。
    private static func applyEpisode(_ bundle: SeriesBundle, to item: SourceItem) -> SourceItem {
        let episode = item.episodeNumber.flatMap { bundle.episodes[$0] }
        var poster: ImageDescriptor?
        if let episode, let url = episode.stillURL, let path = nonEmpty(episode.stillPath) {
            poster = .remote(
                ownerID: item.ref.sourceID,
                url: url,
                // 公开 CDN,不带认证头(`docs/TMDB_API.md` §8)
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
            overview: nonEmpty(episode?.overview) ?? bundle.series.overview,
            year: bundle.series.year,
            episodeTitle: nonEmpty(episode?.name)
        )
    }

    // MARK: - 单条电影 / 视频

    private func enrichSingles(items: [SourceItem], token: String) async -> [SourceItem] {
        let offsets = items.indices.filter {
            Self.isScrapable(items[$0]) && items[$0].kind != .episode
        }
        guard !offsets.isEmpty else { return items }

        let matches = await inBatches(offsets) { offset -> (Int, TMDBMatch?) in
            let item = items[offset]
            if let id = item.tmdbID {
                if let movie = await self.detailsMatch(id: id, isSeries: false, token: token) {
                    return (offset, movie)
                }
                return (offset, await self.detailsMatch(id: id, isSeries: true, token: token))
            }
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

    private func enrichFolders(items: [SourceItem], token: String) async -> [SourceItem] {
        let offsets = items.indices.filter { Self.isScrapableFolder(items[$0]) }
        guard !offsets.isEmpty else { return items }

        let matches = await inBatches(offsets) { offset -> (Int, TMDBMatch?) in
            let item = items[offset]
            return (offset, await self.folderMatch(item: item, token: token))
        }
        var result = items
        for (offset, match) in matches {
            guard let match else { continue }
            result[offset] = Self.apply(match, to: items[offset], fillTMDBID: true)
        }
        return result
    }

    /// 只认标题归一化后完全一致的命中:目录名没有年份等特指信息,放宽(如「唯一结果就认」)
    /// 会让《Movies》目录套上同名剧的海报。
    /// 只查剧端点,电影目录不刮(查两次会让请求翻倍,已知限制见 `docs/KNOWN_ISSUES.md`)。
    /// 例外:带 `{tmdbid-N}` 时按 id 取,先剧后电影。
    private func folderMatch(item: SourceItem, token: String) async -> TMDBMatch? {
        if let id = item.tmdbID {
            if let series = await detailsMatch(id: id, isSeries: true, token: token) {
                return series
            }
            return await detailsMatch(id: id, isSeries: false, token: token)
        }
        // 与剧集组同一个搜索键,共用缓存
        guard let match = await searchMatch(
            title: item.title, year: nil, isSeries: true, token: token) else {
            return nil
        }
        guard let title = match.title,
              Self.normalizedTitle(title) == Self.normalizedTitle(item.title) else {
            return nil
        }
        return match
    }

    // MARK: - 一次搜索

    /// 带缓存;失败折成 nil + `lastFailureDescription`
    private func searchMatch(
        title: String,
        year: Int?,
        isSeries: Bool,
        token: String
    ) async -> TMDBMatch? {
        let key = QueryKey(title: title, year: year, isSeries: isSeries)
        // 下标读出 `TMDBMatch??`:键在即返回,哪怕值是 nil(查过没命中)
        if let cached = searchCache[key] { return cached }

        let matches: [TMDBMatch]
        do {
            matches = try await client.search(
                title: title, year: year, isSeries: isSeries, token: token)
        } catch is CancellationError {
            return nil
        } catch let error as TMDBError {
            lastFailureDescription = error.userMessage
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

    /// 每批最多 `maxConcurrentRequests` 个,一批全回来再开下一批
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

    /// 顺序即优先级(⛔ 不猜):
    /// 1. 有年份 → 只认年份一致的,没有就不认(同名翻拍靠年份区分);
    /// 2. 无年份 → 标题归一化后一致的;
    /// 3. 否则只有唯一结果时才认;
    /// 4. 都不满足 → nil。
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

    /// 忽略大小写、空格、标点(`Fight Club` = `fightclub`);中文按 `isLetter` 保留
    static func normalizedTitle(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// TMDB 偶尔给 `""` 而不是 `null`(`docs/TMDB_API.md` §7)
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// 单条文件:只刮视频类,且标题须从文件名解析出来(`.filename`);
    /// `IMG_0451.MOV` 这类退回原名的问 TMDB 只会配错。音频问 TMDB 只会拿回同名电影。
    static func isScrapable(_ item: SourceItem) -> Bool {
        guard item.metadataOrigin == .filename else { return false }
        switch item.kind {
        case .movie, .episode, .video: return !item.title.isEmpty
        case .audio, .image, .folder, .unknown: return false
        }
    }

    /// 目录恒为 `metadataOrigin == .none`,但目录名本身就是可靠的剧名来源,所以与 `isScrapable` 分开
    static func isScrapableFolder(_ item: SourceItem) -> Bool {
        item.kind == .folder && !item.title.isEmpty
    }

    /// 剧级海报。⛔ 目录卡片与详情页(`FileSourceViewModel`)必须共用这里的拼法,否则两个入口海报不一致。
    static func posterDescriptor(for match: TMDBMatch, sourceID: UUID) -> ImageDescriptor? {
        guard let url = match.posterURL, let path = match.posterPath else { return nil }
        return .remote(
            ownerID: sourceID,
            url: url,
            // 公开 CDN,不带认证头(`docs/TMDB_API.md` §4)
            headers: [:],
            cacheKey: ImageDescriptor.tmdbPosterKey(
                sourceID: sourceID,
                posterPath: path,
                size: TMDBImage.posterSize
            )
        )
    }

    /// - Parameter fillTMDBID: 只有目录卡片要(详情页按它取 `seriesProfile`)。分集 / 单条视频填了
    ///   会让下次刮削改走按 id 直取,白多一次请求。
    private static func apply(
        _ match: TMDBMatch,
        to item: SourceItem,
        fillTMDBID: Bool = false
    ) -> SourceItem {
        item.withScrapedMetadata(
            poster: posterDescriptor(for: match, sourceID: item.ref.sourceID),
            overview: match.overview,
            year: match.year,
            tmdbID: fillTMDBID ? match.tmdbID : nil
        )
    }

    // MARK: - 剧级扩展信息(详情页专用)

    /// 详情页专用的剧级扩展信息(类型 / 评分 / 标语 / 状态 / 制片公司)+ 演职员。
    /// ⛔ 不要并进 `enrich`:那是每次列目录都跑的,并进去一屏会多几十次请求。
    ///
    /// 有 `tmdbID` 直接按 id 取(先剧后电影,credits 跟命中的一边);没有就按标题 + 年份搜,
    /// 搜索键与 `enrichEpisodes` 相同,所以命中的就是分集上那部剧,且通常命中缓存零请求。
    /// 不抛错,失败时详情页不显示这些块。
    ///
    /// - Parameter title: 没给 id 时用于搜索;空串 = 搜不了。
    func seriesProfile(tmdbID: Int?, title: String, year: Int?) async -> TMDBSeriesProfile? {
        let token: String
        do {
            guard let stored = try await credentials.tmdbReadAccessToken(),
                  !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            token = stored
        } catch {
            lastFailureDescription = "读取 TMDB 凭据失败"
            return nil
        }

        let match: TMDBMatch?
        if let tmdbID {
            match = await seriesMatch(id: tmdbID, token: token)
        } else {
            guard !title.isEmpty,
                  let searched = await searchMatch(
                    title: title, year: year, isSeries: true, token: token) else {
                return nil
            }
            // 类型等字段只有详情端点给(`docs/TMDB_API.md` §9);详情失败就退回搜索命中
            match = await seriesMatch(id: searched.tmdbID, token: token) ?? searched
        }
        guard let match else { return nil }
        let credits = await creditsMatch(
            id: match.tmdbID, isSeries: match.kind == .tv, token: token)
        return TMDBSeriesProfile(
            match: match,
            cast: credits?.cast ?? [],
            crew: credits?.crew ?? []
        )
    }

    /// 先剧,404 再电影
    private func seriesMatch(id: Int, token: String) async -> TMDBMatch? {
        if let series = await detailsMatch(id: id, isSeries: true, token: token) {
            return series
        }
        return await detailsMatch(id: id, isSeries: false, token: token)
    }

    /// 缓存口径同 `detailsMatch`
    private func creditsMatch(id: Int, isSeries: Bool, token: String) async -> TMDBCredits? {
        let key = DetailsKey(id: id, isSeries: isSeries)
        if let cached = creditsCache[key] { return cached }

        let credits: TMDBCredits
        do {
            credits = try await client.credits(id: id, isSeries: isSeries, token: token)
        } catch is CancellationError {
            return nil
        } catch let error as TMDBError {
            lastFailureDescription = error.userMessage
            if case .notFound = error { creditsCache.updateValue(nil, forKey: key) }
            return nil
        } catch {
            lastFailureDescription = "刮削失败:\(error)"
            return nil
        }
        creditsCache.updateValue(credits, forKey: key)
        return credits
    }
}