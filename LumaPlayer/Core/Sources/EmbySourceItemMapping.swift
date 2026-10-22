import Foundation

/// `EmbyItem` → 统一条目 `SourceItem` 的映射。Emby 浏览链路仍直接用 `EmbyItem`;
/// 需要跨来源聚合时用这里,⛔ 不就地另写 `if isEmby`。元数据全是服务端给的(`metadataOrigin = .server`)。
extension EmbyItem {

    /// 与 `BaiduPanSourceProvider.coverMaxWidth` 同值。
    static let sourcePosterMaxWidth = 400

    func asSourceItem(sourceID: UUID) -> SourceItem {
        SourceItem(
            ref: SourceItemRef(sourceID: sourceID, itemID: id),
            title: name,
            kind: Self.sourceKind(for: kind),
            overview: overview,
            year: productionYear,
            tmdbID: nil,
            // 分集在剧集页单独展示,不走这条投影;⛔ 不猜 IndexNumber
            episodeNumber: nil,
            seasonNumber: nil,
            // `Name` 已进 `title`
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

    /// 剧集与季映射成 `.folder`:不可直接播放,是能进去的容器。
    private static func sourceKind(for kind: EmbyItemKind) -> SourceItemKind {
        switch kind {
        case .movie: return .movie
        case .episode: return .episode
        case .series, .season: return .folder
        case .other: return .unknown
        }
    }
}
