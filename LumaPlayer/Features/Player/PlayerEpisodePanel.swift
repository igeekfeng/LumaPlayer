import SwiftUI

/// 播放页右侧滑出的选集抽屉:与画面并存,宽度刻意留出左侧画面(⛔ 不铺满)。
///
/// 数据就是 `PlayerViewModel.episodes`,⛔ 这里不发任何请求(百度配额见 `docs/BAIDU_PAN_API.md` §7)。
///
/// 收起入口两个:表头 ✕ 与左缘把手。把手必须有:选集按钮在控制栏最右端,抽屉一开就被盖住。
struct PlayerEpisodePanel: View {
    let episodes: [PlaybackEpisode]
    /// 高亮并在打开时滚到它
    let currentID: String?
    let store: PosterImageStore
    let onSelect: (PlaybackEpisode) -> Void
    let onClose: () -> Void

    @State private var isHoveringCollapseHandle = false

    var body: some View {
        HStack(spacing: 0) {
            // Spacer 不参与命中测试,点左侧照样落到画面交互层(单击暂停)
            Spacer(minLength: 0)
            // 把手与抽屉并排,不压剧照、不占列表宽度
            collapseHandle
            drawer
        }
    }

    private var drawer: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .frame(width: Metrics.episodePanelWidth)
        .frame(maxHeight: .infinity)
        // 视频亮度不可控,材质 + 压暗保证文字可读
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(Metrics.episodePanelDimOpacity))
        .overlay(alignment: .leading) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("选集面板")
    }

    /// 浮在视频上,用材质而非纯色底才能保证箭头始终读得出来。
    private var collapseHandle: some View {
        Button(action: onClose) {
            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .frame(
                    width: Metrics.episodePanelCollapseHandleWidth,
                    height: Metrics.episodePanelCollapseHandleHeight
                )
                .background(.ultraThinMaterial, in: .rect(cornerRadius: Radius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card)
                        .fill(.white.opacity(isHoveringCollapseHandle ? 0.18 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringCollapseHandle = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHoveringCollapseHandle)
        .help("收起选集")
        .accessibilityLabel("收起选集")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingS) {
            Text("选集")
                .font(.headline)
            Text("共 \(episodes.count) 集")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: Metrics.playerButtonSize, height: Metrics.playerButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭选集")
            .accessibilityLabel("关闭选集")
        }
        .padding(.leading, Metrics.spacingL)
        .padding(.trailing, Metrics.spacingS)
        .padding(.vertical, Metrics.spacingS)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.spacingXS) {
                    ForEach(episodes) { episode in
                        EpisodePanelRow(
                            episode: episode,
                            isCurrent: episode.id == currentID,
                            store: store
                        ) {
                            onSelect(episode)
                        }
                        .id(episode.id)
                    }
                }
                .padding(.horizontal, Metrics.spacingM)
                .padding(.vertical, Metrics.spacingM)
            }
            .scrollIndicators(.automatic)
            .onAppear {
                guard let currentID else { return }
                proxy.scrollTo(currentID, anchor: .center)
            }
        }
    }
}

/// 整行可点,与详情页 `EpisodeCard` 一致。
private struct EpisodePanelRow: View {
    let episode: PlaybackEpisode
    let isCurrent: Bool
    let store: PosterImageStore
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Metrics.spacingM) {
                thumbnail
                VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                    if let label = episode.label {
                        Text(label)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(episode.title)
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(Metrics.spacingS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .help(episode.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : AccessibilityTraits())
    }

    private var thumbnail: some View {
        PosterImage(
            descriptor: episode.poster,
            store: store,
            placeholderSystemImage: "tv"
        )
        .frame(width: Metrics.episodeThumbnailWidth, height: Self.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: Radius.card)
            .fill(isCurrent
                  ? Color.accentColor.opacity(0.18)
                  : Color.primary.opacity(isHovering ? 0.08 : 0))
    }

    private static var thumbnailHeight: CGFloat {
        Metrics.episodeThumbnailWidth / Metrics.landscapeAspectRatio
    }
}
