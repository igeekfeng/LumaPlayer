import SwiftUI

/// 百度网盘的剧集详情页:海报 / 标题 / 简介 / 季 / 分集。
///
/// 百度只有目录树,但存法本身已经表达了剧集结构 —— 剧目录下直接摆着集文件算第 1 季,摆着季文件夹则一层一季。
/// 判定在 `BaiduPanSeriesLayout`,这里只负责呈现。
///
/// 字段的降级口径:**TMDB 能给的就显示,给不了的就整块不显示**(⛔ 不留空占位、⛔ 不用别的字段凑)。
/// 没配 token 或没命中时,这一页就是「一张剧名 + 一列集号」,仍然能用,只是朴素。
/// ⚠️ 演职员是整部作品的(TMDB `credits` 没有分季版本),所以切季不改变那一排。
struct FileSourceSeriesDetailView: View {
    @Bindable var viewModel: FileSourceViewModel
    let structure: BaiduPanSeriesStructure
    let store: PosterImageStore

    /// ⛔ 唤起播放窗口:与 `FileSourceBrowserView` 同一纪律,播放请求与开窗必须成对。
    @Environment(\.openWindow) private var openWindow

    @State private var isOverviewExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacingXL) {
                hero
                VStack(alignment: .leading, spacing: Metrics.spacingXL) {
                    seasonSection
                    episodesSection
                    factsSection
                    castSection
                }
                .padding(.horizontal, Metrics.spacingXL)
                .padding(.bottom, Metrics.spacingXL)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // hero 铺到窗口最上沿(与 Emby 详情页一致),不铺则顶栏那段露出窗口底色
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Hero

    /// 背景 + 海报 + 标题区。
    /// ⚠️ 与 Emby 的 `DetailHero` 不同:只有竖版海报,背景用海报放大模糊压暗;
    /// 没有海报就退成一层很淡的渐变,⛔ 不拿占位图撑出一大块灰。
    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            backdrop
                .frame(height: heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.35),
                            .init(color: Color(nsColor: .windowBackgroundColor), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            HStack(alignment: .bottom, spacing: Metrics.spacingXL) {
                poster
                header
            }
            .padding(.horizontal, Metrics.spacingXL)
            .padding(.top, -heroHeight * Metrics.heroOverlapRatio)
        }
    }

    private var heroHeight: CGFloat {
        Metrics.contentMaxWidth * Metrics.heroAspectRatio
    }

    @ViewBuilder
    private var backdrop: some View {
        if let descriptor = viewModel.seriesItem?.poster {
            PosterImage(descriptor: descriptor, store: store, placeholderSystemImage: "tv")
                .scaleEffect(Metrics.heroBackdropScale)
                .blur(radius: Metrics.heroBackdropBlur)
                .overlay {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(Metrics.heroBackdropDimOpacity)
                }
                .accessibilityHidden(true)
        } else {
            LinearGradient(
                colors: [Color.secondary.opacity(0.18), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var poster: some View {
        PosterImage(
            descriptor: viewModel.seriesItem?.poster,
            store: store,
            placeholderSystemImage: "tv"
        )
        .aspectRatio(Metrics.posterAspectRatio, contentMode: .fit)
        .frame(width: Metrics.posterMinWidth)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .shadow(color: .black.opacity(0.3), radius: Metrics.spacingM, y: Metrics.spacingXS)
        .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            Text(viewModel.seriesItem?.title ?? "剧集")
                .font(.largeTitle.bold())
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            metaLine
            genresLine
            actions
            focusedEpisodeSummary
            tagline
            overview
        }
        .frame(maxWidth: Metrics.contentMaxWidth, alignment: .leading)
    }

    // MARK: - 元信息行

    /// 「2024 · 共 2 季 · 共 24 集 · ★ 7.8 · 已完结」。缺哪一段就不显示哪一段(`CLAUDE.md` 硬规则 4)。
    @ViewBuilder
    private var metaLine: some View {
        let parts = metaParts
        let rating = MediaFormat.rating(viewModel.seriesProfile?.match.voteAverage)
        let status = viewModel.seriesProfile?.match.statusText
        if !parts.isEmpty || rating != nil || status != nil {
            HStack(spacing: Metrics.spacingS) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Text("·").accessibilityHidden(true) }
                    Text(part)
                }
                if let rating {
                    if !parts.isEmpty { Text("·").accessibilityHidden(true) }
                    Label(rating, systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .symbolRenderingMode(.multicolor)
                        .accessibilityLabel("评分 \(rating)")
                }
                if let status {
                    if !parts.isEmpty || rating != nil { Text("·").accessibilityHidden(true) }
                    Text(status)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let year = viewModel.seriesItem?.year { parts.append(String(year)) }
        if structure.seasons.count > 1 { parts.append("共 \(structure.seasons.count) 季") }
        // ⛔ 只有「单季且分集已到手」才算总数,不拿当前季的集数冒充全剧
        if structure.isSingleSeason, !viewModel.episodes.isEmpty {
            parts.append("共 \(viewModel.episodes.count) 集")
        }
        return parts
    }

    /// 类型(「剧情 · 奇幻」)。⚠️ 只来自详情端点(`docs/TMDB_API.md` §9),搜索端点只给 `genre_ids`。
    @ViewBuilder
    private var genresLine: some View {
        let genres = viewModel.seriesProfile?.match.genres ?? []
        if !genres.isEmpty {
            Text(genres.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 标语(TMDB `tagline`)。没有就整块不显示 —— ⛔ 不拿简介的头一句凑。
    @ViewBuilder
    private var tagline: some View {
        if let text = viewModel.seriesProfile?.match.tagline, !text.isEmpty {
            Text(text)
                .font(.headline)
                .italic()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 操作

    /// 播放主按钮:作用于定位的那一集(有进度的那集,否则第一集)。分集还没到手时整块不画,⛔ 不给空按钮。
    @ViewBuilder
    private var actions: some View {
        if let episode = viewModel.focusedEpisode {
            GlassEffectContainer(spacing: Metrics.spacingM) {
                HStack(spacing: Metrics.spacingM) {
                    Button {
                        play(episode)
                    } label: {
                        Label(playTitle(for: episode), systemImage: "play.fill")
                            .padding(.horizontal, Metrics.spacingS)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    if hasProgress(episode) {
                        Button {
                            play(episode, fromBeginning: true)
                        } label: {
                            Label("从头播放", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }
            }
        } else if viewModel.isLoadingEpisodes {
            Text("正在读取分集…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func playTitle(for episode: SourceItem) -> String {
        let verb = hasProgress(episode) ? "继续播放" : "播放"
        guard let number = episode.episodeNumber else { return verb }
        return "\(verb) 第 \(number) 集"
    }

    private func hasProgress(_ episode: SourceItem) -> Bool {
        (viewModel.resumeSeconds(for: episode) ?? 0) > 0
    }

    @ViewBuilder
    private var focusedEpisodeSummary: some View {
        if let episode = viewModel.focusedEpisode {
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                if let name = episode.episodeTitle, !name.isEmpty {
                    Text([episodeLabel(episode), name].compactMap { $0 }.joined(separator: " · "))
                        .font(.headline)
                }
                if let text = episode.overview, !text.isEmpty {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func episodeLabel(_ episode: SourceItem) -> String? {
        episode.episodeNumber.map { "第 \($0) 集" }
    }

    @ViewBuilder
    private var overview: some View {
        if let text = viewModel.seriesItem?.overview, !text.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text(text)
                    .font(.body)
                    .lineLimit(isOverviewExpanded ? nil : Self.overviewCollapsedLines)
                    .textSelection(.enabled)
                if text.count > Self.overviewExpandableLength {
                    Button(isOverviewExpanded ? "收起" : "更多") {
                        isOverviewExpanded.toggle()
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private static let overviewCollapsedLines = 4
    private static let overviewExpandableLength = 160

    // MARK: - 季

    @ViewBuilder
    private var seasonSection: some View {
        if !structure.isSingleSeason {
            seasonPicker
        }
    }

    private var seasonPicker: some View {
        let selection = Binding(
            get: { viewModel.selectedSeason?.id ?? structure.seasons.first?.id ?? "" },
            set: { id in
                guard let season = structure.seasons.first(where: { $0.id == id }) else { return }
                Task { await viewModel.selectSeason(season) }
            }
        )
        let picker = Picker("季", selection: selection) {
            ForEach(structure.seasons) { season in
                Text(season.title).tag(season.id)
            }
        }
        .labelsHidden()
        return Group {
            if structure.seasons.count <= Self.segmentedSeasonLimit {
                picker.pickerStyle(.segmented).fixedSize()
            } else {
                picker.pickerStyle(.menu).fixedSize()
            }
        }
    }

    private static let segmentedSeasonLimit = 6

    // MARK: - 分集

    @ViewBuilder
    private var episodesSection: some View {
        if viewModel.isLoadingEpisodes {
            SkeletonEpisodeStrip()
        } else if let failure = viewModel.episodeFailure {
            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                OnboardingNotice(text: failure, style: .error)
                Button("重试") {
                    Task { await viewModel.selectSeason(viewModel.selectedSeason) }
                }
            }
        } else if viewModel.episodes.isEmpty {
            Text("这一季还没有可播的分集。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            FileSourceEpisodeShelf(
                episodes: viewModel.episodes,
                store: store,
                resumeSeconds: { viewModel.resumeSeconds(for: $0) },
                isWatched: { viewModel.isWatched($0) },
                onPlay: { play($0) },
                // 观看状态只有本地这一份(百度无此类接口):⛔ 不发请求,标完直接重读本地库
                onMark: { episode, played in
                    Task { await viewModel.markPlayed([episode], played: played) }
                },
                onMarkAll: { played in
                    Task { await viewModel.markSeasonPlayed(played) }
                }
            )
        }
    }

    // MARK: - 剧级信息(导演 / 编剧 / 制片公司 / 电视台)

    /// 与 Emby 详情页的 `DetailFacts` 同形,四项都没有时整块不显示。
    /// ⚠️ 字段来自详情端点 + 演职员端点(`docs/TMDB_API.md` §9 / §10),列表卡片拿不到,⛔ 不为它改列表链路。
    @ViewBuilder
    private var factsSection: some View {
        let facts = self.facts
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text("信息")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Grid(
                    alignment: .leadingFirstTextBaseline,
                    horizontalSpacing: Metrics.spacingL,
                    verticalSpacing: Metrics.spacingXS
                ) {
                    ForEach(facts, id: \.0) { label, value in
                        GridRow {
                            Text(label).foregroundStyle(.secondary)
                            Text(value).textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private var facts: [(String, String)] {
        guard let profile = viewModel.seriesProfile else { return [] }
        var facts: [(String, String)] = []
        let directors = profile.crewNames(withJob: "Director")
        if !directors.isEmpty { facts.append(("导演", directors.joined(separator: "、"))) }
        let writers = profile.crewNames(withJob: "Writer")
        if !writers.isEmpty { facts.append(("编剧", writers.joined(separator: "、"))) }
        let companies = profile.match.productionCompanies
        if !companies.isEmpty { facts.append(("制片公司", companies.joined(separator: "、"))) }
        // ⚠️ 电视台是剧才有的字段(`docs/TMDB_API.md` §9),电影侧恒空
        let networks = profile.match.networks
        if !networks.isEmpty { facts.append(("电视台", networks.joined(separator: "、"))) }
        return facts
    }

    // MARK: - 演职人员

    /// 演员横排(头像 + 姓名 + 角色),上限与 Emby 详情页一致;一个都没有时整块不显示。
    /// ⚠️ TMDB 的 credits 是整部作品的(`docs/TMDB_API.md` §10),切季不改变这一排。
    @ViewBuilder
    private var castSection: some View {
        let cast = Array((viewModel.seriesProfile?.cast ?? []).prefix(TMDBSeriesProfile.maxCastShown))
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text("演职人员")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Metrics.spacingL) {
                        ForEach(cast) { person in
                            FileSourcePersonCard(
                                person: person,
                                descriptor: profileDescriptor(for: person),
                                store: store
                            )
                        }
                    }
                    .padding(.vertical, Metrics.spacingXS)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// 一位演职员头像的图片描述符(TMDB 图床公开,不带认证头)。
    /// ⛔ 没有 `profile_path` 就返回 nil,卡片退成 `person.fill`,不拿占位图顶替;
    /// `cacheKey` 与海报同一拼法,只有档位不同(`w185`)。
    private func profileDescriptor(for person: TMDBPerson) -> ImageDescriptor? {
        guard let path = person.profilePath,
              let url = person.profileURL,
              let sourceID = viewModel.seriesSourceID else { return nil }
        return .remote(
            ownerID: sourceID,
            url: url,
            headers: [:],
            cacheKey: ImageDescriptor.tmdbPosterKey(
                sourceID: sourceID, posterPath: path, size: TMDBImage.profileSize)
        )
    }

    // MARK: - 动作

    private func play(_ episode: SourceItem, fromBeginning: Bool = false) {
        viewModel.play(episode, fromBeginning: fromBeginning)
        openWindow(id: PlayerSceneRoot.windowID)
    }
}

// MARK: - 一位演职员

/// 一张演职员卡:圆形头像 + 姓名 + 角色(与 Emby 的 `DetailPeopleRow` 同形)。
private struct FileSourcePersonCard: View {
    let person: TMDBPerson
    let descriptor: ImageDescriptor?
    let store: PosterImageStore

    private static let avatarSize = Metrics.posterMinWidth / 2

    var body: some View {
        VStack(spacing: Metrics.spacingXS) {
            PosterImage(
                descriptor: descriptor,
                store: store,
                placeholderSystemImage: "person.fill"
            )
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .clipShape(Circle())
            Text(person.name)
                .font(.caption)
                .lineLimit(1)
            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: Self.avatarSize * 1.3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 分集横排

/// 一季的分集:横向可滚动的一排卡片(与 Emby 的 `EpisodeListView` 同形)。
/// ⚠️ 百度不给时长,画不出进度条(⛔ 不猜比例),只显示「已看到 mm:ss」。
private struct FileSourceEpisodeShelf: View {
    let episodes: [SourceItem]
    let store: PosterImageStore
    let resumeSeconds: (SourceItem) -> Double?
    let isWatched: (SourceItem) -> Bool
    let onPlay: (SourceItem) -> Void
    /// 单集标记:参数是「标成已看(true)/ 未看(false)」
    let onMark: (SourceItem, Bool) -> Void
    /// 整季标记(分集已经在手上,零请求)
    let onMarkAll: (Bool) -> Void

    @State private var position = ScrollPosition()
    @State private var geometry = ShelfGeometry()

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingM) {
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu {
                    Button("标记本季全部已看", systemImage: "checkmark.circle") { onMarkAll(true) }
                    Button("标记本季全部未看", systemImage: "arrow.counterclockwise") { onMarkAll(false) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("本季的观看状态")
                if geometry.isScrollable {
                    ShelfPagingButtons(position: $position, geometry: geometry)
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.spacingL) {
                    ForEach(episodes) { episode in
                        FileSourceEpisodeCard(
                            episode: episode,
                            store: store,
                            resumeSeconds: resumeSeconds(episode),
                            isWatched: isWatched(episode),
                            onPlay: { onPlay(episode) },
                            onMark: { played in onMark(episode, played) }
                        )
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
    }

    /// 「共 12 集」/「共 12 集 · 已看 3 集」。
    /// ⚠️ 这里的「已看」是准的(分集在手上),目录卡片那个只数得到本地有记录的。
    private var countText: String {
        let watched = episodes.filter(isWatched).count
        guard watched > 0 else { return "共 \(episodes.count) 集" }
        return "共 \(episodes.count) 集 · 已看 \(watched) 集"
    }
}

private struct FileSourceEpisodeCard: View {
    let episode: SourceItem
    let store: PosterImageStore
    /// 本地续播位置(秒);nil = 没看到一半(未看 / 已看完都是 nil)
    let resumeSeconds: Double?
    let isWatched: Bool
    let onPlay: () -> Void
    let onMark: (Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            thumbnail
            VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(2)
                if let progressText {
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
        .background {
            RoundedRectangle(cornerRadius: Radius.panel)
                .fill(Color.primary.opacity(isHovering ? 0.05 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .onHover { isHovering = $0 }
        .contextMenu {
            if isWatched {
                Button("标记为未看", systemImage: "arrow.counterclockwise") { onMark(false) }
            } else {
                Button("标记为已看", systemImage: "checkmark.circle") { onMark(true) }
            }
        }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, progressText].compactMap { $0 }.joined(separator: ","))
        .accessibilityAction(named: "播放") { onPlay() }
    }

    private static let overviewLineLimit = 3

    private var thumbnail: some View {
        ZStack {
            PosterImage(
                descriptor: episode.poster,
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
        .overlay(alignment: .topTrailing) {
            if isWatched { WatchedBadge() }
        }
    }

    /// 「3. 集名」。没有集名时退回「第 3 集」,⛔ 不拿剧名顶上去(整目录都一样)。
    private var title: String {
        if let name = episode.episodeTitle, !name.isEmpty {
            guard let number = episode.episodeNumber else { return name }
            return "\(number). \(name)"
        }
        guard let number = episode.episodeNumber else { return episode.title }
        return "第 \(number) 集"
    }

    /// 百度没有服务端进度,这一行来自本地续播库(时长由 `filemetas` 带回)。
    /// 看完报「已看」,否则报时长;两样都没有就不显示,⛔ 不写「未知」。
    private var progressText: String? {
        if isWatched { return "已看" }
        if let resumeSeconds, resumeSeconds > 0 {
            return "已看到 \(PlayerTime.text(resumeSeconds))"
        }
        return MediaFormat.duration(seconds: episode.durationSeconds ?? 0)
    }
}
