import SwiftUI

/// 「看什么」页:豆瓣榜单 + TMDB 榜单(配了 token 才有)。每条可以直接跳去「找资源」搜同名资源。
///
/// 为什么这一页不在来源里:它不属于任何一个网盘 / Emby 来源 ——
/// 换来源不该让「今晚看什么」跟着换。所以它是主窗口的一个**独立目的地**,
/// 顶栏的来源切换器在这一页隐藏。
struct DiscoveryView: View {
    let container: AppContainer
    /// 点卡片上的「找资源」
    var onSearchResource: (String) -> Void
    /// 点「查看全部」:push 那一组的网格页
    var onSeeAll: (DiscoverBoard) -> Void

    @State private var viewModel: DiscoveryViewModel

    @MainActor
    init(
        container: AppContainer,
        onSearchResource: @escaping (String) -> Void,
        onSeeAll: @escaping (DiscoverBoard) -> Void
    ) {
        self.container = container
        self.onSearchResource = onSearchResource
        self.onSeeAll = onSeeAll
        self._viewModel = State(initialValue: DiscoveryViewModel(providers: container.discoverProviders))
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "看什么")
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("看什么")
        .task { await viewModel.appear() }
        .reportsPageLoading(viewModel.isLoading, page: .home, to: container.state)
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.boards.isEmpty {
            emptyContent
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.spacingXL) {
                    ForEach(viewModel.boards) { board in
                        boardSection(board)
                    }
                    if let failure = viewModel.lastFailure {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Metrics.spacingXL)
                    }
                }
                .padding(.vertical, Metrics.spacingM)
            }
        }
    }

    /// 一组榜单都出不来时的引导页。⛔ 不显示一堆永远空着的货架。
    @ViewBuilder
    private var emptyContent: some View {
        if viewModel.unavailable.contains(where: \.needsToken) {
            ContentUnavailableView {
                Label("需要 TMDB Token", systemImage: "theatermasks")
            } actions: {
                // ⛔ 不用 `NSApp.sendAction("showSettingsWindow:")`:那个 selector 名随系统版本变过,
                // 项目里已有的入口统一走 `SettingsLink` / `openSettings`
                SettingsLink {
                    Text("打开设置…")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("暂时没有榜单", systemImage: "theatermasks")
            } actions: {
                Button("重试") {
                    Task { await viewModel.reload() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func boardSection(_ board: DiscoverBoard) -> some View {
        switch viewModel.states[board.id] {
        case .none, .some(.idle):
            EmptyView()
        case .some(.loading):
            MediaShelf(title: board.title) {
                ForEach(0..<6, id: \.self) { _ in
                    // 与真实卡片同形:海报位 + 两行文字,数据到达时是「填进去」而不是跳一下
                    VStack(alignment: .leading, spacing: Metrics.spacingS) {
                        Color.clear
                            .aspectRatio(Metrics.posterAspectRatio, contentMode: .fit)
                            .overlay { SkeletonBlock() }
                        SkeletonBlock(cornerRadius: Radius.tag)
                            .frame(height: Metrics.spacingM)
                        SkeletonBlock(cornerRadius: Radius.tag)
                            .frame(width: Metrics.posterMinWidth / 2, height: Metrics.spacingM)
                    }
                    .frame(width: Metrics.posterMinWidth)
                }
            }
            .padding(.horizontal, Metrics.spacingXL)
        case .some(.failed(let failure)):
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text(board.title).font(.title3.bold())
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Metrics.spacingXL)
        case .some(.loaded(let titles)):
            if titles.isEmpty {
                EmptyView()
            } else {
                // 「查看全部」只在还有下一页时出现:否则点进去就是同一屏,白多一次导航
                MediaShelf(
                    title: board.title,
                    seeAll: viewModel.hasMore[board.id] == true ? { onSeeAll(board) } : nil
                ) {
                    ForEach(titles) { title in
                        DiscoveryCard(
                            title: title,
                            store: container.posters,
                            onSearch: { onSearchResource(title.searchKeyword) })
                    }
                }
                .padding(.horizontal, Metrics.spacingXL)
            }
        }
    }
}

/// 发现页的一张卡。点击 = 去搜资源(这一页没有「播放」这个动作 —— 资源还没在网盘里)。
struct DiscoveryCard: View {
    let title: DiscoverTitle
    let store: PosterImageStore
    var onSearch: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSearch) {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Color.clear
                    .aspectRatio(Metrics.posterAspectRatio, contentMode: .fit)
                    .overlay {
                        PosterImage(
                            descriptor: title.posterDescriptor,
                            store: store,
                            placeholderSystemImage: "theatermasks")
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .scaleEffect(isHovering ? 1.03 : 1)
                    .shadow(
                        color: .black.opacity(isHovering ? 0.25 : 0),
                        radius: Metrics.spacingS, y: Metrics.spacingXS)
                VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                    Text(title.title)
                        .font(.body)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(title.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // 豆瓣的 `card_subtitle`:地区 / 类型 / 主创,比「2026 · 8.6 分」有用得多
                    if let cardSubtitle = title.cardSubtitle {
                        Text(cardSubtitle)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    // 更新进度单独一行并高亮:这是「追不追」的关键信息,不该混在灰字里
                    if let episodes = title.episodesInfoLine {
                        Text(episodes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                // 行数不固定(有没有 card_subtitle / episodes_info),钉住最小高度让同行卡片对齐
                .frame(minHeight: Metrics.discoverCardTextHeight, alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .frame(width: Metrics.posterMinWidth)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
    }

    /// 悬停提示带完整信息:卡片上每行都截断了,`card_subtitle` 与更新进度的全文在这里。
    private var helpText: String {
        var lines = ["搜索「\(title.searchKeyword)」的网盘资源"]
        if let cardSubtitle = title.cardSubtitle { lines.insert(cardSubtitle, at: 0) }
        if let episodes = title.episodesInfo { lines.insert(episodes, at: 0) }
        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        var parts = [title.title]
        if !title.subtitle.isEmpty { parts.append(title.subtitle) }
        if let cardSubtitle = title.cardSubtitle { parts.append(cardSubtitle) }
        if let episodes = title.episodesInfo { parts.append(episodes) }
        return parts.joined(separator: ",") + "。搜索网盘资源"
    }
}
