import SwiftUI

/// 媒体详情:电影详情 / 剧集的季与分集。
///
/// 布局参照 Emby Web 的信息结构(海报 + 标题 + 元信息 + 播放 / ✓ / ♡),
/// 呈现上按 macOS 原生做:整幅背景图做 hero(`backgroundExtensionEffect`
/// 让它延伸到工具栏下面)、播放主按钮用带 tint 的玻璃(UI_DESIGN.md 4.1)。
///
/// 剧集是**单页**:季、分集和播放按钮都在这一页里,
/// 页面只有**一个**播放主按钮,它作用于当前定位的那一集
/// (`MediaDetailViewModel.focusedEpisode`)。点分集行只换定位,不跳页。
struct MediaDetailView: View {
    let container: AppContainer
    let server: ServerProfile
    let item: EmbyItem
    /// 打开另一项(相似推荐):主窗口往导航栈上再 push 一页,返回栈可逐级退回。
    var onOpenItem: (EmbyItem) -> Void = { _ in }
    /// 变化即重新加载(工具栏「刷新」)。同一项再次加载是原地刷新,保留已有内容。
    var refreshToken: Int = 0

    /// 每个 push 出来的详情页自带一份:栈上同时存在多页时各读各的项,
    /// 共用一个 ViewModel 会让上层页面显示下层那一项的内容。
    @State private var viewModel: MediaDetailViewModel
    @State private var isOverviewExpanded = false
    @Environment(\.openWindow) private var openWindow

    init(
        container: AppContainer,
        server: ServerProfile,
        item: EmbyItem,
        onOpenItem: @escaping (EmbyItem) -> Void = { _ in },
        refreshToken: Int = 0
    ) {
        self.container = container
        self.server = server
        self.item = item
        self.onOpenItem = onOpenItem
        self.refreshToken = refreshToken
        self._viewModel = State(initialValue: MediaDetailViewModel(container: container))
    }

    var body: some View {
        Group {
            switch viewModel.detailState {
            case .idle, .loading:
                // 首屏还没有内容:灰色骨架占位,不闪白屏(刷新时 detailState 仍是 .loaded)
                SkeletonDetail()
            case .failed(let failure):
                ErrorStateView(
                    failure: failure,
                    retry: { viewModel.load(item: item, server: server) },
                    login: { container.state.serverNeedingLogin = server }
                )
            case .loaded(let detail):
                detailContent(detail)
            }
        }
        // 栈顶再 push 一页(相似推荐)时,返回按钮要有个名字可显示
        .navigationTitle(item.name)
        // 加载 / 刷新中整页不可点(刷新按钮也在转圈),避免对旧内容做操作
        .allowsHitTesting(!viewModel.isLoading)
        .task(id: "\(server.id.uuidString)-\(item.id)-\(refreshToken)") {
            viewModel.load(item: item, server: server)
        }
        .reportsPageLoading(viewModel.isLoading, page: .detail, to: container.state)
        // Q22:续播位置、已看状态以服务端为准。播放器在独立窗口里,
        // 收尾上报发完后经 AppState 广播;只要是这台服务器上的播放就重读一次
        // (播的可能是本页的某一集,也可能是从播放器里连播过去的下一集)。
        .onChange(of: container.state.lastFinishedPlayback) { _, finished in
            guard finished?.serverID == server.id else { return }
            viewModel.refreshAfterPlayback(server: server)
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { viewModel.userDataError != nil },
                set: { if !$0 { viewModel.userDataError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.userDataError ?? "")
        }
    }

    private func play(_ item: EmbyItem, fromBeginning: Bool = false) {
        container.play(item, on: server, fromBeginning: fromBeginning)
        openWindow(id: PlayerSceneRoot.windowID)
    }

    // MARK: - 内容

    private func detailContent(_ detail: EmbyItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacingXL) {
                DetailHero(detail: detail, server: server, store: container.posters) {
                    header(detail)
                }
                VStack(alignment: .leading, spacing: Metrics.spacingXL) {
                    if detail.kind == .series {
                        seriesSections
                    }
                    DetailMediaInfo(streams: detail.mediaStreams ?? [])
                    DetailPeopleRow(people: detail.people ?? [], server: server, store: container.posters)
                    DetailFacts(detail: detail)
                    similarSection
                }
                .padding(.horizontal, Metrics.spacingXL)
                .padding(.bottom, Metrics.spacingXL)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - 头部:标题 / 元信息 / 操作 / 简介

    private func header(_ detail: EmbyItem) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            DetailTitle(detail: detail, server: server, store: container.posters)
            DetailMetaLine(detail: detail)
            if let genres = detail.genres, !genres.isEmpty {
                Text(genres.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            actions(detail)
            if detail.kind == .series {
                focusedEpisodeSummary
            } else if detail.kind != .season {
                progressLine(detail)
            }
            overview(detail)
        }
        .frame(maxWidth: Metrics.contentMaxWidth, alignment: .leading)
    }

    /// 播放主按钮 + 从头播放 + ✓ + ♡。作用对象:剧集是定位的那一集(✓ ♡ 作用于整部剧),
    /// 电影 / 单集是它自己;季本身不可播,不给一个点了没反应的按钮。
    @ViewBuilder
    private func actions(_ detail: EmbyItem) -> some View {
        let playable: EmbyItem? = detail.kind == .series
            ? viewModel.focusedEpisode
            : (detail.kind == .season ? nil : detail)
        GlassEffectContainer(spacing: Metrics.spacingM) {
            HStack(spacing: Metrics.spacingM) {
                if let playable {
                    Button {
                        play(playable)
                    } label: {
                        Label(playTitle(for: playable, in: detail), systemImage: "play.fill")
                            .padding(.horizontal, Metrics.spacingS)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    if playable.progressFraction != nil {
                        Button {
                            play(playable, fromBeginning: true)
                        } label: {
                            Label("从头播放", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                } else if detail.kind == .series {
                    SkeletonBlock(cornerRadius: Radius.card)
                        .frame(width: Metrics.spacingXL, height: Metrics.spacingXL)
                    Text("正在定位要播放的那一集…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                userDataButtons(for: detail)
            }
        }
    }

    private func userDataButtons(for detail: EmbyItem) -> some View {
        let busy = viewModel.updatingItemIDs.contains(detail.id)
        return HStack(spacing: Metrics.spacingM) {
            Button {
                viewModel.togglePlayed(detail, server: server)
            } label: {
                Label(detail.isPlayed ? "标记为未看" : "标记为已看",
                      systemImage: detail.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                    .labelStyle(.iconOnly)
            }
            .help(detail.isPlayed ? "标记为未看" : "标记为已看")
            .foregroundStyle(detail.isPlayed ? Color.accentColor : Color.primary)
            Button {
                viewModel.toggleFavorite(detail, server: server)
            } label: {
                Label(detail.isFavorite ? "取消收藏" : "收藏",
                      systemImage: detail.isFavorite ? "heart.fill" : "heart")
                    .labelStyle(.iconOnly)
            }
            .help(detail.isFavorite ? "取消收藏" : "收藏")
            .foregroundStyle(detail.isFavorite ? Color.red : Color.primary)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(busy)
    }

    private func playTitle(for playable: EmbyItem, in detail: EmbyItem) -> String {
        let verb = playable.progressFraction == nil ? "播放" : "继续播放"
        guard detail.kind == .series, let label = playable.episodeLabel else { return verb }
        return "\(verb) \(label)"
    }

    @ViewBuilder
    private func progressLine(_ item: EmbyItem) -> some View {
        if let progress = item.progressFraction {
            HStack(spacing: Metrics.spacingM) {
                ProgressView(value: progress)
                    .frame(maxWidth: Metrics.posterMinWidth * 1.5)
                Text(progressCaption(item, progress: progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func progressCaption(_ item: EmbyItem, progress: Double) -> String {
        let percent = "已观看 \(Int(progress * 100))%"
        guard let remaining = MediaFormat.remaining(for: item) else { return percent }
        return "\(percent) · 剩余 \(remaining)"
    }

    /// 剧集:定位的那一集是谁,它的简介与进度(播放主按钮作用于它)。
    @ViewBuilder
    private var focusedEpisodeSummary: some View {
        if let episode = viewModel.focusedEpisode {
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text([episode.episodeLabel, episode.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                progressLine(episode)
            }
        }
    }

    @ViewBuilder
    private func overview(_ detail: EmbyItem) -> some View {
        if let tagline = detail.taglines?.first, !tagline.isEmpty {
            Text(tagline)
                .font(.headline)
                .italic()
                .foregroundStyle(.secondary)
        }
        if let overview = detail.overview, !overview.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text(overview)
                    .font(.body)
                    .lineLimit(isOverviewExpanded ? nil : Self.overviewCollapsedLines)
                    .textSelection(.enabled)
                if overview.count > Self.overviewExpandableLength {
                    Button(isOverviewExpanded ? "收起" : "更多") {
                        isOverviewExpanded.toggle()
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private static let overviewCollapsedLines = 4
    /// 超过这个字数才给「更多」按钮(按中文约 4 行估算,不精确测量排版)
    private static let overviewExpandableLength = 160

    // MARK: - 剧集:季与分集

    @ViewBuilder
    private var seriesSections: some View {
        switch viewModel.seasonsState {
        case .idle, .loading:
            SkeletonEpisodeStrip()
        case .failed(let failure):
            ErrorStateView(
                failure: failure,
                retry: { retrySeasons() },
                login: { container.state.serverNeedingLogin = server }
            )
            .frame(height: Metrics.posterMinWidth)
        case .loaded(let seasons):
            if seasons.isEmpty {
                Text("这部剧还没有季。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Metrics.spacingM) {
                    seasonPicker(seasons)
                    episodesSection
                }
            }
        }
    }

    /// 季不多时用分段控件一眼看全(Apple TV / Infuse 的做法),多了退回下拉菜单。
    @ViewBuilder
    private func seasonPicker(_ seasons: [EmbyItem]) -> some View {
        let selection = Binding(
            get: { viewModel.selectedSeason?.id ?? seasons.first?.id ?? "" },
            set: { id in
                if let season = seasons.first(where: { $0.id == id }) {
                    viewModel.selectSeason(season, server: server)
                }
            }
        )
        let picker = Picker("季", selection: selection) {
            ForEach(seasons) { season in
                Text(season.name).tag(season.id)
            }
        }
        .labelsHidden()
        if seasons.count <= Self.segmentedSeasonLimit {
            picker.pickerStyle(.segmented).fixedSize()
        } else {
            picker.pickerStyle(.menu).fixedSize()
        }
    }

    private static let segmentedSeasonLimit = 6

    @ViewBuilder
    private var episodesSection: some View {
        switch viewModel.episodesState {
        case .idle, .loading:
            SkeletonEpisodeStrip()
        case .failed(let failure):
            ErrorStateView(
                failure: failure,
                retry: { viewModel.retryEpisodes(server: server) },
                login: { container.state.serverNeedingLogin = server }
            )
            .frame(height: Metrics.posterMinWidth)
        case .loaded(let episodes):
            if episodes.isEmpty {
                Text("这一季还没有分集。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 点集只换定位(按钮与简介就地更新),不再把整页换成另一个详情页
                EpisodeListView(
                    episodes: episodes,
                    selectedEpisodeID: viewModel.focusedEpisode?.id,
                    serverID: server.id,
                    store: container.posters,
                    updatingIDs: viewModel.updatingItemIDs,
                    onSelect: { viewModel.selectEpisode($0) },
                    onPlay: { play($0, fromBeginning: $1) },
                    onTogglePlayed: { viewModel.togglePlayed($0, server: server) }
                )
            }
        }
    }

    private func retrySeasons() {
        // 季失败时重跑一次完整流程即可补上。用最初打开的项而不是已加载的剧:
        // 从分集点进来时,重试后仍要定位回那一集。
        viewModel.load(item: item, server: server)
    }

    // MARK: - 相似推荐

    @ViewBuilder
    private var similarSection: some View {
        // 失败 / 为空时整块不显示:附加信息,不占错误页(见 ViewModel 注释)
        if case .loaded(let items) = viewModel.similarState, !items.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text("更多类似")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Metrics.gridSpacing) {
                        ForEach(items) { similar in
                            Button {
                                onOpenItem(similar)
                            } label: {
                                MediaCard(item: similar, serverID: server.id, store: container.posters)
                                    .frame(width: Metrics.posterMinWidth)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, Metrics.spacingS)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}
