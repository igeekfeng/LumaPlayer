import SwiftUI

/// 某一季的分集横排卡片,整季不把详情页撑长。
///
/// 点一集只换定位(播放按钮跟着换),所以定位集要有明确选中标记(高亮 + 描边 + `.isSelected`),
/// 且打开 / 切季时滚到可见。直接播某集:悬停缩略图上的播放按钮或右键菜单。
struct EpisodeListView: View {
    let episodes: [EmbyItem]
    /// nil = 还没定位
    let selectedEpisodeID: String?
    let serverID: UUID
    let store: PosterImageStore
    let updatingIDs: Set<String>
    let batchProgress: MediaDetailViewModel.BatchPlayedProgress?
    let onSelect: (EmbyItem) -> Void
    /// 第二个参数:是否从头播放
    let onPlay: (EmbyItem, Bool) -> Void
    let onTogglePlayed: (EmbyItem) -> Void
    let onMarkSeasonPlayed: (Bool) -> Void
    let onOpenBatchPicker: () -> Void

    @State private var position = ScrollPosition()
    @State private var geometry = ShelfGeometry()
    /// 指针在分集区域内时显示滚动条
    @State private var isHoveringEpisodes = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingM) {
                Text("共 \(episodes.count) 集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let batchProgress {
                    Text("正在标记 \(batchProgress.completed)/\(batchProgress.total) 集…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                batchMenu
                if geometry.isScrollable {
                    EpisodeJumpMenu(episodes: episodes, onJump: jump(to:))
                    ShelfPagingButtons(position: $position, geometry: geometry)
                }
            }
            VStack(spacing: Metrics.spacingXS) {
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
                // 鼠标用户没有横滑手势,给一条可直接拖到任意位置的滚动条
                if geometry.isScrollable {
                    EpisodeScrubber(
                        position: $position,
                        geometry: geometry,
                        isHovering: isHoveringEpisodes
                    )
                }
            }
            .onHover { isHoveringEpisodes = $0 }
        }
        .onAppear(perform: scrollToSelection)
        // 切季
        .onChange(of: episodes.first?.id) { _, _ in scrollToSelection() }
    }

    /// 只在初次出现与切季时对齐:点选后再自动滚动会把刚点的卡挪走
    private func scrollToSelection() {
        guard let selectedEpisodeID else { return }
        position.scrollTo(id: selectedEpisodeID, anchor: .leading)
    }

    /// 从菜单跳:换定位并滚到可见(不是点眼前的卡,滚动不会挪走它)。
    private func jump(to episode: EmbyItem) {
        onSelect(episode)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: Metrics.animationStandard)) {
            position.scrollTo(id: episode.id, anchor: .leading)
        }
    }

    /// 单季一键 + 勾选面板入口。只收集意图,逐条写在 `MediaDetailViewModel.runBatch`;
    /// 没有待写的集时菜单项禁用。
    private var batchMenu: some View {
        let pendingPlayed = episodes.filter { !$0.isPlayed }.count
        let pendingUnplayed = episodes.count - pendingPlayed
        let isBusy = batchProgress != nil
        return Menu {
            Button("整季标记为已看", systemImage: "checkmark.circle") {
                onMarkSeasonPlayed(true)
            }
            .disabled(pendingPlayed == 0)
            Button("整季标记为未看", systemImage: "circle") {
                onMarkSeasonPlayed(false)
            }
            .disabled(pendingUnplayed == 0)
            Divider()
            Button("选择分集…", systemImage: "checklist") {
                onOpenBatchPicker()
            }
        } label: {
            Label("批量标记", systemImage: "checkmark.circle.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isBusy)
        .help(isBusy ? "正在标记,请稍候" : "整季或选中的分集一次性标记已看 / 未看")
        .accessibilityLabel("批量标记")
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

/// 分集横排下方的滚动条,贴近系统覆盖式滚动条:无轨道底条,只在悬停或滚动时出现、停下后延迟淡出。
/// 按下轨道任意处滑块跳过去,接着拖连续滚。集数极多时 `shelfScrubberThumbMinWidth` 保证滑块点得中。
private struct EpisodeScrubber: View {
    @Binding var position: ScrollPosition
    let geometry: ShelfGeometry
    /// 由外层传入
    let isHovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 决定滑块深浅
    @State private var isHoveringThumb = false
    @State private var isScrolling = false
    @State private var hideTask: Task<Void, Never>?

    private var isVisible: Bool { isHovering || isHoveringThumb || isScrolling }

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = proxy.size.width
            let thumbWidth = thumbWidth(trackWidth: trackWidth)
            let travel = max(0, trackWidth - thumbWidth)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHoveringThumb
                                                ? Metrics.shelfScrubberThumbOpacityHover
                                                : Metrics.shelfScrubberThumbOpacity))
                    .frame(width: thumbWidth, height: Metrics.shelfScrubberThumbHeight)
                    .offset(x: travel * progress)
            }
            // 必须 .leading:ZStack 固有宽度只剩滑块,.center 会先居中再叠 offset,位置全偏
            .frame(width: trackWidth, height: proxy.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(scrubGesture(trackWidth: trackWidth, thumbWidth: thumbWidth))
        }
        .frame(height: Metrics.shelfScrubberHitHeight)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: Metrics.animationStandard), value: isVisible)
        .animation(.easeOut(duration: Metrics.animationFast), value: isHoveringThumb)
        .onHover { isHoveringThumb = $0 }
        .onChange(of: geometry.offset) { _, _ in flashWhileScrolling() }
        .onDisappear { hideTask?.cancel() }
        .accessibilityElement()
        .accessibilityLabel("分集滚动条")
        .accessibilityValue("已滚动 \(Int((progress * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: page(by: 1)
            case .decrement: page(by: -1)
            @unknown default: break
            }
        }
    }

    private func flashWhileScrolling() {
        isScrolling = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(Metrics.shelfScrubberHideDelay))
            guard !Task.isCancelled else { return }
            isScrolling = false
        }
    }

    /// 滑块中心跟手:按下即跳、拖动即连续滚。
    private func scrubGesture(trackWidth: CGFloat, thumbWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard geometry.maxOffset > 0 else { return }
                let travel = max(1, trackWidth - thumbWidth)
                let half = thumbWidth / 2
                let x = min(max(value.location.x, half), trackWidth - half)
                let progress = (x - half) / travel
                position.scrollTo(x: progress * geometry.maxOffset)
            }
    }

    /// 容器占内容的比例;内容宽度未知时先占满
    private func thumbWidth(trackWidth: CGFloat) -> CGFloat {
        guard geometry.contentWidth > 0 else { return trackWidth }
        let ratio = geometry.containerWidth / geometry.contentWidth
        return max(Metrics.shelfScrubberThumbMinWidth, min(trackWidth, trackWidth * ratio))
    }

    /// 0...1
    private var progress: CGFloat {
        guard geometry.maxOffset > 0 else { return 0 }
        return min(max(geometry.offset / geometry.maxOffset, 0), 1)
    }

    /// 键盘 / VoiceOver 调节,一次翻大半屏(同翻页按钮)
    private func page(by direction: CGFloat) {
        let step = geometry.containerWidth * Self.pageFraction * direction
        let target = min(max(0, geometry.offset + step), geometry.maxOffset)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: Metrics.animationStandard)) {
            position.scrollTo(x: target)
        }
    }

    private static var pageFraction: CGFloat { 0.8 }
}

/// 「跳转选集」菜单。集数多时按 100 集分子菜单,少时平铺。
private struct EpisodeJumpMenu: View {
    let episodes: [EmbyItem]
    let onJump: (EmbyItem) -> Void

    var body: some View {
        Menu {
            if episodes.count <= Self.directListLimit {
                items(episodes)
            } else {
                ForEach(buckets, id: \.lowerBound) { range in
                    Menu(bucketLabel(for: range)) {
                        items(Array(episodes[range]))
                    }
                }
            }
        } label: {
            Label("跳转选集", systemImage: "list.number")
        }
        .fixedSize()
        .help("跳到指定的一集")
        .accessibilityLabel("跳转选集")
    }

    @ViewBuilder
    private func items(_ list: [EmbyItem]) -> some View {
        ForEach(list) { episode in
            Button(itemLabel(for: episode)) { onJump(episode) }
        }
    }

    private var buckets: [Range<Int>] {
        stride(from: 0, to: episodes.count, by: Self.bucketSize).map {
            $0 ..< min($0 + Self.bucketSize, episodes.count)
        }
    }

    private func bucketLabel(for range: Range<Int>) -> String {
        "第 \(range.lowerBound + 1)–\(range.upperBound) 集"
    }

    /// 同 `EpisodeCard.title`
    private func itemLabel(for episode: EmbyItem) -> String {
        guard let index = episode.indexNumber else { return episode.name }
        return "\(index). \(episode.name)"
    }

    private static let directListLimit = 40
    private static let bucketSize = 100
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
        // 选中:整块高亮 + 描边(卡片挨得近,只靠底色分不清)
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

    /// 「3. 集名」;没有 `IndexNumber` 只显示集名,⛔ 不猜集号。
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
