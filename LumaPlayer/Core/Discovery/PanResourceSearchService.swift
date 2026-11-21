import Foundation
import os

/// 聚合搜索的编排:并发跑所有启用的源 → 归一化 → 去重 → 排序。
///
/// 借了 PanSou 的三条做法,但按「本机客户端」的体量简化了:
/// 1. **并发扇出 + 单源超时**:一个源挂住不拖垮整次搜索(`sourceTimeout`)。
/// 2. **按分享地址去重,保留信息更全的一条**:同一条资源被多个源收录时只留一条,
///    标题更长 / 带时间 / 链接更多的那条胜出。
/// 3. **失败归因**:失败的源单独回传,⛔ 不把「某个源挂了」伪装成「没有资源」。
///
/// 没搬的部分(PanSou 有、这里没做):两级缓存、SJF 调度、后台补齐。
/// 理由:那套是为「一次问 100+ 个源、几秒内要回包」的服务器场景设计的;
/// 本机只有个位数源,直接并发等齐更简单,也不会留下「4 秒后偷偷补数据」的状态。
actor PanResourceSearchService {
    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "resource-search")

    /// 单个源最长等多久。超时就记成失败并继续 —— 搜索页不能因为一个慢源整页卡住。
    static let sourceTimeout: TimeInterval = 15

    private let registry: ResourceSourceAdapterRegistry
    private let sourcesStore: ResourceSourceStore

    init(registry: ResourceSourceAdapterRegistry, sourcesStore: ResourceSourceStore) {
        self.registry = registry
        self.sourcesStore = sourcesStore
    }

    /// 跑一次搜索。`sources` 由调用方给(设置页刚改完要立即生效,不等落盘)。
    func search(keyword: String, sources: [ResourceSource]) async -> PanResourceSearchResult {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PanResourceSearchResult(keyword: keyword, resources: [], searchedSourceIDs: [], failures: [])
        }
        let enabled = sources.filter(\.isEnabled)

        // 一个源一次;失败折成 failure,⛔ 不中断其它源
        let outcomes = await withTaskGroup(
            of: (ResourceSource, Result<[PanResource], PanResourceSearchError>).self
        ) { group in
            for source in enabled {
                group.addTask { [registry] in
                    (source, await Self.run(source, keyword: trimmed, registry: registry))
                }
            }
            var collected: [(ResourceSource, Result<[PanResource], PanResourceSearchError>)] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        var resources: [PanResource] = []
        var failures: [PanResourceSourceFailure] = []
        var searched: [String] = []
        // 顺序按配置来,⛔ 不按完成先后(否则同一关键词两次搜出来的顺序会跳)
        let bySourceID = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.0.id, $0) })
        for source in enabled {
            guard let (_, outcome) = bySourceID[source.id] else { continue }
            searched.append(source.id)
            switch outcome {
            case .success(let found):
                resources.append(contentsOf: found)
            case .failure(let error):
                failures.append(PanResourceSourceFailure(
                    sourceID: source.id,
                    displayName: source.displayName,
                    message: error.userMessage))
            }
        }

        let merged = Self.merge(resources)
        return PanResourceSearchResult(
            keyword: trimmed,
            resources: Self.filterRelevant(merged, keyword: trimmed),
            searchedSourceIDs: searched,
            failures: failures)
    }
    /// 单源执行 + 超时。超时**取消**任务,⛔ 不留下还在跑的请求。
    private static func run(
        _ source: ResourceSource,
        keyword: String,
        registry: ResourceSourceAdapterRegistry
    ) async -> Result<[PanResource], PanResourceSearchError> {
        guard source.validationFailure == nil else {
            return .failure(.sourceFailed(
                sourceID: source.id, statusCode: nil, message: source.validationFailure))
        }
        do {
            let adapter = try registry.adapter(for: source)
            return try await withThrowingTaskGroup(of: [PanResource].self) { group in
                group.addTask {
                    try await adapter.search(keyword: keyword, source: source)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(sourceTimeout))
                    throw CancellationError()
                }
                do {
                    let first = try await group.next() ?? []
                    group.cancelAll()
                    return .success(first)
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } catch is CancellationError {
            return .failure(.sourceFailed(
                sourceID: source.id, statusCode: nil, message: "超时(\(Int(sourceTimeout)) 秒没有回包)"))
        } catch let error as PanResourceSearchError {
            return .failure(error)
        } catch {
            let nsError = error as NSError
            return .failure(.sourceFailed(
                sourceID: source.id,
                statusCode: nil,
                message: SecretRedactor.redacted("\(nsError.domain) \(nsError.code)")))
        }
    }

    // MARK: - 降噪

    /// 标题 / 摘要与关键词的相关性过滤。
    ///
    /// 为什么要这一道:频道是「什么都发」的,搜「仙逆」经常混进同频道里别的剧
    /// (搜索结果按频道内的相关度排,不保证每条都含关键词)。PanSou 那种全量扇出
    /// 之所以显得「杂」,一半原因就在这。
    ///
    /// 口径刻意放宽:
    /// - 关键词按空白切成词,**命中任意一个词**就保留(中文整串命中也算)。
    /// - 单个词 < 2 个字符时不参与判断(「4K」这种太泛,不该成为唯一依据)。
    /// - **一条都不剩时退回原结果**:宁可杂一点,也不能因为启发式让用户看到「没搜到」。
    static func filterRelevant(_ resources: [PanResource], keyword: String) -> [PanResource] {
        let tokens = keyword
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.lowercased() }
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return resources }
        let filtered = resources.filter { resource in
            let haystack = (resource.title + " " + (resource.summary ?? "")).lowercased()
            return tokens.contains { haystack.contains($0) }
        }
        return filtered.isEmpty ? resources : filtered
    }

    // MARK: - 去重与排序

    /// 按分享地址去重,重复项留「信息更全」的一条。
    ///
    /// 打分口径(与 PanSou 的 `mergeSearchResults` 同思路):
    /// 链接多 > 有摘要 > 标题长 > 有时间。相等时保留先出现的(配置顺序靠前的源优先)。
    static func merge(_ resources: [PanResource]) -> [PanResource] {
        var byKey: [String: PanResource] = [:]
        var order: [String] = []
        for resource in resources {
            let key = resource.deduplicationKey
            guard let existing = byKey[key] else {
                byKey[key] = resource
                order.append(key)
                continue
            }
            if score(resource) > score(existing) {
                byKey[key] = resource
            }
        }
        let merged = order.compactMap { byKey[$0] }
        return merged.sorted(by: Self.isOrderedBefore)
    }

    private static func score(_ resource: PanResource) -> Int {
        var score = resource.links.count * 100
        if let summary = resource.summary, !summary.isEmpty { score += 20 }
        if resource.publishedAt != nil { score += 10 }
        score += min(resource.title.count, 30)
        return score
    }

    /// 新的在前;时间相同的按标题排,保证同一份数据两次渲染顺序一致。
    private static func isOrderedBefore(_ lhs: PanResource, _ rhs: PanResource) -> Bool {
        switch (lhs.publishedAt, rhs.publishedAt) {
        case let (l?, r?) where l != r:
            return l > r
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            break
        }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.id < rhs.id
    }

    // MARK: - 按网盘类型分组

    /// 搜索结果页的「按网盘筛选」用。`nil` = 不过滤。
    ///
    /// ⚠️ 一条资源可能同时有百度 + 夸克链接,所以分组不是划分集合 ——
    /// 这里返回「带这类链接的资源」,同一条资源可以出现在多个分组里。
    static func filter(_ resources: [PanResource], cloudType: PanCloudType?) -> [PanResource] {
        guard let cloudType else { return resources }
        return resources.filter { resource in
            resource.links.contains { $0.cloudType == cloudType }
        }
    }

    /// 结果里出现过的网盘类型,按数量降序(给筛选器排序)
    static func availableCloudTypes(in resources: [PanResource]) -> [PanCloudType] {
        var counts: [PanCloudType: Int] = [:]
        for resource in resources {
            for type in Set(resource.links.map(\.cloudType)) {
                counts[type, default: 0] += 1
            }
        }
        return counts.keys.sorted { lhs, rhs in
            let l = counts[lhs] ?? 0
            let r = counts[rhs] ?? 0
            if l != r { return l > r }
            return lhs.rawValue < rhs.rawValue
        }
    }
}
