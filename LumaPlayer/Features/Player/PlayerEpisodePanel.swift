import SwiftUI

/// 播放页右侧滑出的「选集」抽屉(B2):本季 / 本目录的有序剧集,一行一集,
/// 带 16:9 剧照、集号与集名,当前集高亮并滚到可见,点任意一集直接切。
///
/// **为什么是右侧抽屉,而不是第一版的 popover 小浮层:**
/// popover 装不下「剧集页」那种一眼扫过去的封面墙 —— 它要贴着按钮、要小。
/// Plex / Netflix 的分集是**从右滑出、和画面并存**的:一边看一边挑下一集,
/// 图能开大,当前集在几十集里也定位得住。宽度 `Metrics.episodePanelWidth`
/// 是刻意留出左侧画面的(⛔ 不铺满)。
///
/// 数据就是 `PlayerViewModel.episodes`(剧集队列),⛔ 这里不发任何请求 ——
/// 百度的兄弟集是**起播那一刻**装进请求的(`BaiduPanSourceViewModel.episodeQueue`),
/// 回头再列一次网盘会烧配额(未审核应用 10 次/小时,`docs/BAIDU_PAN_API.md`)。
/// 封面走 `PosterImage`(唯一允许发图请求的地方),缓存与海报墙共用。
struct PlayerEpisodePanel: View {
    let episodes: [PlaybackEpisode]
    /// 当前这一集的来源内 id(高亮 + 打开时滚到它)
    let currentID: String?
    let store: PosterImageStore
    let onSelect: (PlaybackEpisode) -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // 左侧留白让画面露出来:抽屉是「并存」不是「覆盖」。
            // Spacer 不参与命中测试,点左侧照样落到下面的画面交互层(单击暂停)。
            Spacer(minLength: 0)
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
        // 深色材质压一层:视频亮度不可控,靠玻璃的自适应保证文字始终可读
        // (与 `PlayerControlsView` 的压暗衬底同一考量)。
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(Metrics.episodePanelDimOpacity))
        .overlay(alignment: .leading) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("选集面板")
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
                // 打开时把当前集摆到中间:几十集往后翻时,不滚过去就看不到自己在哪
                guard let currentID else { return }
                proxy.scrollTo(currentID, anchor: .center)
            }
        }
    }
}

/// 抽屉里的一行:16:9 剧照 + 集号 / 集名 + 当前集的对勾。
///
/// 整行是一个按钮 —— 与详情页 `EpisodeCard` 的「整卡可点」一致,不用只点缩略图。
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

    /// 16:9 剧照。没有可用图时 `PosterImage` 自己降级成占位图(⛔ 不假装有封面)。
    private var thumbnail: some View {
        PosterImage(
            descriptor: episode.poster,
            store: store,
            placeholderSystemImage: "tv"
        )
        .frame(width: Metrics.episodeThumbnailWidth, height: Self.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }

    /// 当前集整行高亮;其余悬停时给一层淡底 —— 与详情页分集卡同一套。
    private var background: some View {
        RoundedRectangle(cornerRadius: Radius.card)
            .fill(isCurrent
                  ? Color.accentColor.opacity(0.18)
                  : Color.primary.opacity(isHovering ? 0.08 : 0))
    }

    /// 缩略图高度由宽度与 16:9 宽高比推得(与 `PosterImage` 的 fill 裁切配合)。
    private static var thumbnailHeight: CGFloat {
        Metrics.episodeThumbnailWidth / Metrics.landscapeAspectRatio
    }
}
