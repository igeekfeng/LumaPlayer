import SwiftUI

/// 某一季的分集:横向排列、可滚动的一排卡片(UI_DESIGN.md 6.2 的可扫描性优先)。
///
/// 一集一张卡,卡内的信息不减(剧照 + 集号与集名 + 时长 / 日期 / 剩余 + 简介 +
/// 进度条 + ✓),只是把「一行一集」的纵向列表改成横向一条 —— 整季不再把详情页撑长,
/// 顺序往下看时当前集和后面几集就在眼前,要跳远的集滚一下就行。
///
/// 点一集是**就地换定位**(详情页的播放按钮跟着换),不是跳页,所以当前
/// 定位的那一集要有明确的选中标记 —— 整卡高亮 + 描边 + `.isSelected` 语义。
/// 打开或切季时把它滚到可见,否则定位的那一集在屏幕外,和播放按钮对不上。
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

    @State private var position = ScrollPosition()
    @State private var geometry = ShelfGeometry()

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingM) {
                Text("共 \(episodes.count) 集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if geometry.isScrollable {
                    ShelfPagingButtons(position: $position, geometry: geometry)
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.spacingL) {
                    ForEach(episodes) { episode in
                        EpisodeCard(
                            episode: episode,
                            isSelected: episode.id == selectedEpisodeID,
                            serverID: serverID,
                            store: store,
                            onPlay: { onPlay(episode, false) }
                        )
                        .id(episode.id)
                        .onTapGesture { onSelect(episode) }
                        .contextMenu { menu(for: episode) }
                    }
                }
                .padding(.vertical, Metrics.spacingS)
            }
            .scrollIndicators(.hidden)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ShelfGeometry.self) { proxy in
                ShelfGeometry(
                    offset: proxy.contentOffset.x,
                    contentWidth: proxy.contentSize.width,
                    containerWidth: proxy.containerSize.width
                )
            } action: { _, new in
                geometry = new
            }
        }
        .onAppear(perform: scrollToSelection)
        // 切季时整段换掉,定位的集也跟着变 —— 重新对齐一次
        .onChange(of: episodes.first?.id) { _, _ in scrollToSelection() }
    }

    /// 只在初次出现与切季时对齐:点选某一集后再自动滚动,会把刚点的那张卡挪走
    private func scrollToSelection() {
        guard let selectedEpisodeID else { return }
        position.scrollTo(id: selectedEpisodeID, anchor: .leading)
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

private struct EpisodeCard: View {
    let episode: EmbyItem
    let isSelected: Bool
    let serverID: UUID
    let store: PosterImageStore
    let onPlay: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            thumbnail
            VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(2)
                if let meta {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(Self.overviewLineLimit)
                }
            }
        }
        .padding(Metrics.spacingS)
        .frame(width: Metrics.landscapeCardWidth, alignment: .topLeading)
        // 系统惯例:选中是整块高亮,再加一圈描边 —— 卡片挨得近时只靠底色分不清
        .background {
            RoundedRectangle(cornerRadius: Radius.panel)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.15)
                      : Color.primary.opacity(isHovering ? 0.05 : 0))
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.panel)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : AccessibilityTraits())
        .accessibilityAction(named: "播放") { onPlay() }
    }

    private static let overviewLineLimit = 3

    private var thumbnail: some View {
        ZStack {
            PosterImage(
                spec: episode.landscapeImage.map {
                    ImageSpec(
                        serverID: serverID,
                        itemID: $0.itemID,
                        type: $0.type,
                        tag: $0.tag,
                        maxWidth: Int(Metrics.landscapeCardWidth * 2)
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
        .aspectRatio(Metrics.landscapeAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
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
