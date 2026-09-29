import SwiftUI

/// 某一季的分集列表(UI_DESIGN.md 6.2 的可扫描性优先)。
///
/// 整行不加玻璃(4.2 禁止区域);未看完的集有稳定的进度条标记、看完的集
/// 有 ✓ 角标,不只靠颜色或透明度。
///
/// 点一集是**就地换定位**(详情页的播放按钮跟着换),不是跳页,所以当前
/// 定位的那一集要有明确的选中标记 —— 整行高亮 + `.isSelected` 语义。
/// 想直接播某一集:悬停时缩略图上的播放按钮,或右键菜单。
struct EpisodeListView: View {
    let episodes: [EmbyItem]
    /// 当前定位的那一集(播放按钮作用于它);nil 表示还没定位
    let selectedEpisodeID: String?
    let serverID: UUID
    let store: PosterImageStore
    /// 正在写 UserData 的集(右键菜单里的已看切换据此禁用)
    let updatingIDs: Set<String>
    let onSelect: (EmbyItem) -> Void
    /// 第二个参数:是否从头播放
    let onPlay: (EmbyItem, Bool) -> Void
    let onTogglePlayed: (EmbyItem) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Metrics.spacingXS) {
            ForEach(episodes) { episode in
                EpisodeRow(
                    episode: episode,
                    isSelected: episode.id == selectedEpisodeID,
                    serverID: serverID,
                    store: store,
                    onPlay: { onPlay(episode, false) }
                )
                .onTapGesture { onSelect(episode) }
                .contextMenu { menu(for: episode) }
            }
        }
    }

    @ViewBuilder
    private func menu(for episode: EmbyItem) -> some View {
        Button(episode.progressFraction == nil ? "播放" : "继续播放", systemImage: "play.fill") {
            onPlay(episode, false)
        }
        if episode.progressFraction != nil {
            Button("从头播放", systemImage: "arrow.counterclockwise") {
                onPlay(episode, true)
            }
        }
        Divider()
        Button(episode.isPlayed ? "标记为未看" : "标记为已看",
               systemImage: episode.isPlayed ? "circle" : "checkmark.circle") {
            onTogglePlayed(episode)
        }
        .disabled(updatingIDs.contains(episode.id))
    }
}

private struct EpisodeRow: View {
    let episode: EmbyItem
    let isSelected: Bool
    let serverID: UUID
    let store: PosterImageStore
    let onPlay: () -> Void

    @State private var isHovering = false

    private static let thumbnailWidth = Metrics.posterMinWidth * 1.2

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacingL) {
            thumbnail
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let meta {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Metrics.spacingS)
        }
        .padding(Metrics.spacingS)
        // 系统惯例:选中是整行高亮;悬停给一层更淡的底,告诉用户这一行可以点
        .background {
            RoundedRectangle(cornerRadius: Radius.panel)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.15)
                      : Color.primary.opacity(isHovering ? 0.05 : 0))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : AccessibilityTraits())
        .accessibilityAction(named: "播放") { onPlay() }
    }

    private var thumbnail: some View {
        ZStack {
            PosterImage(
                spec: episode.landscapeImage.map {
                    ImageSpec(
                        serverID: serverID,
                        itemID: $0.itemID,
                        type: $0.type,
                        tag: $0.tag,
                        maxWidth: Int(Self.thumbnailWidth * 2)
                    )
                },
                store: store,
                placeholderSystemImage: "tv"
            )
            if isHovering {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .padding(Metrics.spacingM)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("播放这一集")
                .transition(.opacity)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(width: Self.thumbnailWidth)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay(alignment: .bottom) {
            if let progress = episode.progressFraction {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .padding(Metrics.spacingS)
                    .accessibilityLabel("已观看 \(Int(progress * 100))%")
            }
        }
        .overlay(alignment: .topTrailing) {
            if episode.isPlayed {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.title3)
                    .padding(Metrics.spacingXS)
                    .accessibilityLabel("已看")
            }
        }
    }

    /// 「3. 集名」。集号来自服务端 `IndexNumber`,没有就只显示集名(不猜、不占位)。
    private var title: String {
        guard let index = episode.indexNumber else { return episode.name }
        return "\(index). \(episode.name)"
    }

    private var meta: String? {
        let parts = [
            MediaFormat.runtime(ticks: episode.runTimeTicks),
            MediaFormat.date(episode.premiereDate),
            MediaFormat.remaining(for: episode).map { "剩余 \($0)" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
