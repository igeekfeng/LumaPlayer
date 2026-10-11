import SwiftUI

/// 右键菜单能做的事。媒体库页全给;搜索页只给播放与详情(不传写操作回调)。
struct ItemGridActions {
    var play: ((EmbyItem, _ fromBeginning: Bool) -> Void)?
    var togglePlayed: ((EmbyItem) -> Void)?
    var toggleFavorite: ((EmbyItem) -> Void)?
    /// 正在写 UserData 的条目(对应菜单项禁用,防止连点发出相反的两次请求)
    var updatingIDs: Set<String> = []
}

/// 海报网格(DesignTokens.swift 的网格 token;卡片不用玻璃)。
///
/// 滚动时不为每个卡片创建玻璃容器(DesignTokens.swift「界面规则」)。
struct ItemGridView: View {
    let items: [EmbyItem]
    let serverID: UUID
    let store: PosterImageStore
    /// 打开某一项的详情(主窗口 push 详情页)
    var onOpenItem: (EmbyItem) -> Void
    var actions = ItemGridActions()

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Metrics.posterMinWidth), spacing: Metrics.gridSpacing)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
            ForEach(items) { item in
                Button {
                    onOpenItem(item)
                } label: {
                    MediaCard(item: item, serverID: serverID, store: store)
                }
                .buttonStyle(.plain)
                .contextMenu { menu(for: item) }
            }
        }
        .padding(Metrics.spacingXL)
    }

    @ViewBuilder
    private func menu(for item: EmbyItem) -> some View {
        // 剧集 / 季本身不可播(播哪一集要进详情页定位),只有电影与单集给「播放」
        if let play = actions.play, item.kind == .movie || item.kind == .episode {
            Button(item.progressFraction == nil ? "播放" : "继续播放", systemImage: "play.fill") {
                play(item, false)
            }
            if item.progressFraction != nil {
                Button("从头播放", systemImage: "arrow.counterclockwise") {
                    play(item, true)
                }
            }
            Divider()
        }
        Button("显示详情", systemImage: "info.circle") {
            onOpenItem(item)
        }
        if actions.togglePlayed != nil || actions.toggleFavorite != nil {
            Divider()
        }
        if let togglePlayed = actions.togglePlayed {
            Button(item.isPlayed ? "标记为未看" : "标记为已看",
                   systemImage: item.isPlayed ? "circle" : "checkmark.circle") {
                togglePlayed(item)
            }
            .disabled(actions.updatingIDs.contains(item.id))
        }
        if let toggleFavorite = actions.toggleFavorite {
            Button(item.isFavorite ? "取消收藏" : "收藏",
                   systemImage: item.isFavorite ? "heart.slash" : "heart") {
                toggleFavorite(item)
            }
            .disabled(actions.updatingIDs.contains(item.id))
        }
    }
}
