import SwiftUI

/// 播放页的「选集」浮层:本季 / 本目录的有序剧集,当前集高亮,点任意一集直接切。
///
/// 数据就是 `PlayerViewModel.episodes`(剧集队列),⛔ 这里不发任何请求 ——
/// 百度的兄弟集是**起播那一刻**装进请求的(`BaiduPanSourceViewModel.episodeQueue`),
/// 回头再列一次网盘会烧配额(未审核应用 10 次/小时,`docs/BAIDU_PAN_API.md`)。
///
/// 形态与详情页的 `EpisodeJumpMenu` 不同(那个是菜单,集数多时按 100 集分组):
/// 播放页要的是「一眼看到前后几集 + 能滚」,所以是可滚动列表而不是分层菜单。
struct PlayerEpisodePicker: View {
    let episodes: [PlaybackEpisode]
    /// 当前这一集的来源内 id(高亮 + 打开时滚到它)
    let currentID: String?
    let onSelect: (PlaybackEpisode) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(episodes) { episode in
                        EpisodePickerRow(
                            episode: episode,
                            isCurrent: episode.id == currentID
                        ) {
                            onSelect(episode)
                        }
                        .id(episode.id)
                    }
                }
                .padding(.vertical, Metrics.spacingXS)
            }
            // 一屏放得下十来集,再多靠滚动 —— ⛔ 不做成铺满整屏的面板。
            .frame(width: Self.width, height: Self.height)
            .onAppear {
                // 打开时把当前集摆到中间:几十集往后翻时,不滚过去就看不到自己在哪
                guard let currentID else { return }
                proxy.scrollTo(currentID, anchor: .center)
            }
        }
    }

    private static let width: CGFloat = 280
    private static let height: CGFloat = 320
}

/// 浮层里的一行:集标识 + 集名 + 当前集的对勾。
private struct EpisodePickerRow: View {
    let episode: PlaybackEpisode
    let isCurrent: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Metrics.spacingM) {
                if let label = episode.label {
                    Text(label)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                }
                Text(episode.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(.horizontal, Metrics.spacingM)
            .padding(.vertical, Metrics.spacingS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(episode.title)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isCurrent ? .isSelected : AccessibilityTraits())
    }

    /// 当前集常亮;其余悬停时给一层淡底 —— 与分集卡片的选中 / 悬停同一套。
    private var background: Color {
        if isCurrent { return Color.accentColor.opacity(0.15) }
        return Color.primary.opacity(isHovering ? 0.08 : 0)
    }

    private var accessibilityLabel: String {
        [episode.label, episode.title].compactMap { $0 }.joined(separator: ",")
    }

    /// 集标识列固定宽,集名才不会参差不齐
    private static let labelWidth: CGFloat = 56
}
