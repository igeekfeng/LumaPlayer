import SwiftUI

/// 某一季的分集:横向排列、可滚动的一排卡片(DesignTokens.swift「界面规则」的可扫描性优先)。
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
    /// 指针在分集区域(横排或滚动条)内。滚动条据此显示 —— 与系统覆盖式滚动条一致
    @State private var isHoveringEpisodes = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingM) {
                Text("共 \(episodes.count) 集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if geometry.isScrollable {
                    // 几百上千集时一屏一屏翻太慢:直接从菜单选集,横排滚过去
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
                // 横排下面的滚动条:拖它可快速左右滚动(鼠标用户没有横滑手势,
                // 一屏一屏翻又太慢 —— 这条能直接拖到任意位置)
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
        // 切季时整段换掉,定位的集也跟着变 —— 重新对齐一次
        .onChange(of: episodes.first?.id) { _, _ in scrollToSelection() }
    }

    /// 只在初次出现与切季时对齐:点选某一集后再自动滚动,会把刚点的那张卡挪走
    private func scrollToSelection() {
        guard let selectedEpisodeID else { return }
        position.scrollTo(id: selectedEpisodeID, anchor: .leading)
    }

    /// 从菜单跳到某一集:既换定位(播放按钮跟着换),也把它滚到可见 ——
    /// 这里不是「用户点了眼前那张卡」,自动滚动不会把要看的卡挪走。
    private func jump(to episode: EmbyItem) {
        onSelect(episode)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: Metrics.animationStandard)) {
            position.scrollTo(id: episode.id, anchor: .leading)
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

/// 分集横排下方的滚动条:只有一条滑块,拖它直接滚到任意位置。
///
/// 外观与行为都贴近系统覆盖式滚动条:不画轨道底条,颜色很浅,且**只在悬停分集
/// 区域或正在滚动时出现**,停止滚动后延迟淡出。滑块宽度按「容器宽 / 内容宽」的
/// 比例算、位置按滚动偏移算 —— 和系统滚动条同一套映射。按下滑块所在轨道任意处
/// 滑块就跳过去(scrubber 行为),接着拖即可连续滚动。集数极多时滑块会很细,
/// `shelfScrubberThumbMinWidth` 保一个能点中的下限。
private struct EpisodeScrubber: View {
    @Binding var position: ScrollPosition
    let geometry: ShelfGeometry
    /// 指针是否在分集区域内(由外层传入)。在,则显示
    let isHovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 指针是否正压在滚动条自己身上(决定滑块深浅)
    @State private var isHoveringThumb = false
    /// 最近是否滚动过(滚动时显示,停下后延迟淡出)
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
            // 必须 .leading:去掉轨道后 ZStack 的固有宽度只剩滑块,
            // 用默认的 .center 会把滑块先居中、再叠加 offset,位置就全偏了
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
        // 滚动(含拖滚动条本身)时点亮,停下后延迟淡出
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

    /// 滚动时保持可见,最后一次滚动之后再等 `shelfScrubberHideDelay` 才淡出
    private func flashWhileScrolling() {
        isScrolling = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(Metrics.shelfScrubberHideDelay))
            guard !Task.isCancelled else { return }
            isScrolling = false
        }
    }

    /// 滑块中心跟手:把手指的 x 映射回滚动偏移,按下即跳、拖动即连续滚。
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

    /// 滑块宽度:容器占内容的比例;内容未知时先占满整条(等布局完成再收窄)
    private func thumbWidth(trackWidth: CGFloat) -> CGFloat {
        guard geometry.contentWidth > 0 else { return trackWidth }
        let ratio = geometry.containerWidth / geometry.contentWidth
        return max(Metrics.shelfScrubberThumbMinWidth, min(trackWidth, trackWidth * ratio))
    }

    /// 当前滚动进度 0...1
    private var progress: CGFloat {
        guard geometry.maxOffset > 0 else { return 0 }
        return min(max(geometry.offset / geometry.maxOffset, 0), 1)
    }

    /// 键盘 / VoiceOver 的左右调节:一次翻大半屏(与翻页按钮一致)
    private func page(by direction: CGFloat) {
        let step = geometry.containerWidth * Self.pageFraction * direction
        let target = min(max(0, geometry.offset + step), geometry.maxOffset)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: Metrics.animationStandard)) {
            position.scrollTo(x: target)
        }
    }

    private static var pageFraction: CGFloat { 0.8 }
}

/// 「跳转选集」菜单:一季几百上千集时,一屏一屏翻要翻很久,直接从菜单点一集。
///
/// 集数多时按每 100 集分组(子菜单),菜单不会一次铺开上千项;集数少时直接平铺,
/// 少一层点击。菜单项用与卡片一致的「集号. 集名」,没有集号就只显示集名。
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

    /// 每 100 集一组(如 0..<100、100..<200),最后一组按实际集数收尾
    private var buckets: [Range<Int>] {
        stride(from: 0, to: episodes.count, by: Self.bucketSize).map {
            $0 ..< min($0 + Self.bucketSize, episodes.count)
        }
    }

    private func bucketLabel(for range: Range<Int>) -> String {
        "第 \(range.lowerBound + 1)–\(range.upperBound) 集"
    }

    /// 与 `EpisodeCard.title` 一致:集号来自服务端,没有就只显示集名(不猜、不占位)。
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
