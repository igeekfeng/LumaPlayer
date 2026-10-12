import Foundation

/// `EmbyItem` → 统一条目 `SourceItem` 的映射。
///
/// ## 为什么现在就写(还没有消费者)
///
/// Emby 的浏览链路(首页 / 媒体库 / 搜索 / 详情)目前仍直接用 `EmbyItem`,
/// 整体换成 `SourceItem` 是另一次大重构,眼下没有收益。但
/// 「Emby 的元数据映射到统一形状」这件事**只能有一个答案** ——
/// 等到首页「继续观看」要聚合两个来源时(`docs/SOURCE_ABSTRACTION_PLAN.md` P6),
/// 才发现映射规则没定,就会有人就地写一份 `if isEmby`。
///
/// ⚠️ 与百度的差别,如实说清楚:Emby 这边**全是服务端给的**
/// (`metadataOrigin = .server`),没有一处是解析出来的 —— 这是它的优势。
extension EmbyItem {

    /// 海报取的宽度。与百度侧 `BaiduPanSourceProvider.coverMaxWidth` 同值,
    /// 免得同一个来源里两种卡片请求两种尺寸。
    static let sourcePosterMaxWidth = 400

    func asSourceItem(sourceID: UUID) -> SourceItem {
        SourceItem(
            ref: SourceItemRef(sourceID: sourceID, itemID: id),
            title: name,
            kind: Self.sourceKind(for: kind),
            overview: overview,
            year: productionYear,
            // Emby 的分集在剧集页里单独展示,不走这条投影;⛔ 不猜 IndexNumber
            episodeNumber: nil,
            seasonNumber: nil,
            // 集名同理:Emby 的 `Name` 已经进了 `title`,这一格留给分集专用名
            episodeTitle: nil,
            durationSeconds: runTimeTicks.flatMap { TickConverter.seconds(fromTicks: $0) },
            poster: coverImage.map { cover in
                .emby(
                    ImageSpec(
                        serverID: sourceID,
                        itemID: cover.itemID,
                        type: cover.type,
                        tag: cover.tag,
                        maxWidth: Self.sourcePosterMaxWidth
                    )
                )
            },
            metadataOrigin: .server
        )
    }

    /// `EmbyItemKind` → `SourceItemKind`。
    ///
    /// ⚠️ 剧集(`series`)与季(`season`)映射成 `.folder`:它们在 Emby 里
    /// **不可直接播放**(播哪一集要进详情页定位),在本模型里就是「能进去的容器」。
    private static func sourceKind(for kind: EmbyItemKind) -> SourceItemKind {
        switch kind {
        case .movie: return .movie
        case .episode: return .episode
        case .series, .season: return .folder
        case .other: return .unknown
        }
    }
}
