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
    /// 点开的图片墙(剧级 / 季 / 集);nil = 没打开
    @State private var imageRequest: FileSourceImageRequest?

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
        .sheet(item: $imageRequest) { request in
            FileSourceImageGalleryView(
                request: request,
                sourceID: viewModel.seriesSourceID ?? UUID(),
                store: store,
                load: { request in
                    try await viewModel.loadImageSet(
                        season: request.season, episode: request.episode)
                }
            )
        }
    }

    // MARK: - Hero

    /// 背景 + 海报 + 标题区。
    /// ⚠️ 与 Emby 的 `DetailHero` 不同:只有竖版海报;背景优先用 TMDB 的横版 backdrop(§9),
    /// 没有 backdrop 才退回海报放大模糊压暗;连海报都没有就退成一层很淡的渐变,
    /// ⛔ 不拿占位图撑出一大块灰。
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
        if let descriptor = viewModel.seriesBackdrop {
            // 真正的横版背景图:不用重度模糊,只轻压暗让文字可读
            PosterImage(descriptor: descriptor, store: store, placeholderSystemImage: "tv")
                .aspectRatio(Metrics.landscapeAspectRatio, contentMode: .fill)
                .overlay {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(Metrics.heroBackdropDimOpacity)
                }
                .accessibilityHidden(true)
        } else if let descriptor = viewModel.seriesItem?.poster {
            // 没有 backdrop:竖版海报放大模糊压暗(原来的退路)
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

    /// 「2024 · 共 2 季 · 共 73 集 · ★ 7.8 · 已完结」。缺哪一段就不显示哪一段(`CLAUDE.md` 硬规则 4)。
    /// ⚠️ 集数是 TMDB 记的全剧总数,不是当前文件夹里的文件数;后者只决定分集列表。
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
        let match = viewModel.seriesProfile?.match
        // 季数 / 集数以 TMDB 为准(全剧);没配 token / 没命中时退回网盘目录数出来的季数,
        // 集数则只在单季时拿当前季的凑合,⛔ 不拿一季冒充全剧。
        let seasons = match?.numberOfSeasons ?? (structure.seasons.count > 1 ? structure.seasons.count : nil)
        if let seasons, seasons > 0 { parts.append("共 \(seasons) 季") }
        if let episodes = match?.numberOfEpisodes, episodes > 0 {
            parts.append("共 \(episodes) 集")
        } else if structure.isSingleSeason, !viewModel.episodes.isEmpty {
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
    /// 「图片」按钮只在认出 TMDB 身份后出现 —— 没身份就不给点了没反应的入口。
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Metrics.spacingM) {
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
            if viewModel.seriesImageIdentity != nil {
                Button {
                    imageRequest = FileSourceImageRequest(
                        title: viewModel.seriesItem?.title ?? "剧集",
                        season: nil, episode: nil)
                } label: {
                    Label("图片", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("浏览 TMDB 的背景图 / 海报 / Logo")
            }
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
                if let date = MediaFormat.date(episode.airDate) {
                    Text("播出 \(date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                isMultiSeason: !structure.isSingleSeason,
                seasonNumber: viewModel.selectedSeason?.number,
                canShowImages: viewModel.seriesImageIdentity != nil,
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
                },
                // ⚠️ 每集一次请求,只在点开这一集时才发(§12)
                onShowImages: { episode in
                    guard let season = viewModel.selectedSeason?.number,
                          let number = episode.episodeNumber else { return }
                    imageRequest = FileSourceImageRequest(
                        title: "第 \(season) 季 · 第 \(number) 集",
                        season: season, episode: number)
                },
                onSeasonImages: { season in
                    imageRequest = FileSourceImageRequest(
                        title: "第 \(season) 季", season: season, episode: nil)
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
        let match = profile.match
        if let date = MediaFormat.date(match.firstAirDate) {
            facts.append((match.kind == .tv ? "首播" : "首映", date))
        }
        // 完结日只有 tv 给;与首播同一天(单集特别篇)就不重复列。
        if let last = MediaFormat.date(match.lastAirDate),
           last != MediaFormat.date(match.firstAirDate) {
            facts.append(("最后播出", last))
        }
        if let episodes = match.numberOfEpisodes, episodes > 0 {
            facts.append(("TMDB 总集数", "\(episodes) 集"))
        }
        if let seasons = match.numberOfSeasons, seasons > 0 {
            facts.append(("TMDB 总季数", "\(seasons) 季"))
        }
        if let runtime = match.episodeRunTime.first, runtime > 0 {
            facts.append(("单集片长", "\(runtime) 分钟"))
        }
        let directors = profile.crewNames(withJob: "Director")
        if !directors.isEmpty { facts.append(("导演", directors.joined(separator: "、"))) }
        let writers = profile.crewNames(withJob: "Writer")
        if !writers.isEmpty { facts.append(("编剧", writers.joined(separator: "、"))) }
        let companies = match.productionCompanies
        if !companies.isEmpty { facts.append(("制片公司", companies.joined(separator: "、"))) }
        // ⚠️ 电视台是剧才有的字段(`docs/TMDB_API.md` §9),电影侧恒空
        let networks = match.networks
        if !networks.isEmpty { facts.append(("电视台", networks.joined(separator: "、"))) }
        return facts
    }

    // MARK: - 演职人员

    /// 演员 + 剧组两排(头像 + 姓名 + 角色 / 职务),全量不截断;两个都空时整块不显示。
    /// ⚠️ 剧集走 `aggregate_credits`(全剧汇总,§10),切季不改变这一排。
    @ViewBuilder
    private var castSection: some View {
        let cast = viewModel.seriesProfile?.cast ?? []
        let crew = viewModel.seriesProfile?.crew ?? []
        if !cast.isEmpty || !crew.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingL) {
                Text("演职人员")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                if !cast.isEmpty {
                    personShelf(title: "演员", people: cast)
                }
                if !crew.isEmpty {
                    personShelf(title: "幕后", people: crew)
                }
            }
        }
    }

    @ViewBuilder
    private func personShelf(title: String, people: [TMDBPerson]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            Text("\(title) · \(people.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.spacingL) {
                    ForEach(people) { person in
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

/// 一张演职员卡:圆形头像 + 姓名 + 角色 / 职务(+ aggregate 的参演集数)。
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
            if let count = person.totalEpisodeCount, count > 0 {
                Text("参演 \(count) 集")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
    /// 多季时这一排只是「本季」,头部元信息行的「共 N 集」是 TMDB 全剧总数,别让两处看起来打架。
    let isMultiSeason: Bool
    /// 当前季号;分集图片端点要它,nil(未分季)时不给入口
    let seasonNumber: Int?
    let canShowImages: Bool
    let store: PosterImageStore
    let resumeSeconds: (SourceItem) -> Double?
    let isWatched: (SourceItem) -> Bool
    let onPlay: (SourceItem) -> Void
    /// 单集标记:参数是「标成已看(true)/ 未看(false)」
    let onMark: (SourceItem, Bool) -> Void
    /// 整季标记(分集已经在手上,零请求)
    let onMarkAll: (Bool) -> Void
    /// ⚠️ 每集一次请求,只在这一集被点开时触发(§12)
    let onShowImages: (SourceItem) -> Void
    /// 季海报:点开才发一次请求(§12)
    let onSeasonImages: ((Int) -> Void)?

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
                    // 季海报只在认出季号 + TMDB 身份时给:一次请求,点开才发
                    if canShowImages, let seasonNumber {
                        Divider()
                        Button("查看本季海报", systemImage: "photo") {
                            onSeasonImages?(seasonNumber)
                        }
                    }
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
                            canShowImages: canShowImages
                                && seasonNumber != nil && episode.episodeNumber != nil,
                            onPlay: { onPlay(episode) },
                            onMark: { played in onMark(episode, played) },
                            onShowImages: { onShowImages(episode) }
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

    /// 「共 12 集」/「本季 12 集 · 已看 3 集」。
    /// ⚠️ 这个数是**本季实际文件数**,与头部 TMDB 全剧总数不是一个口径;
    /// ⚠️ 这里的「已看」是准的(分集在手上),目录卡片那个只数得到本地有记录的。
    private var countText: String {
        let watched = episodes.filter(isWatched).count
        let total = isMultiSeason ? "本季 \(episodes.count) 集" : "共 \(episodes.count) 集"
        guard watched > 0 else { return total }
        return "\(total) · 已看 \(watched) 集"
    }
}

private struct FileSourceEpisodeCard: View {
    let episode: SourceItem
    let store: PosterImageStore
    /// 本地续播位置(秒);nil = 没看到一半(未看 / 已看完都是 nil)
    let resumeSeconds: Double?
    let isWatched: Bool
    let canShowImages: Bool
    let onPlay: () -> Void
    let onMark: (Bool) -> Void
    let onShowImages: () -> Void

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
                if let episodeMeta {
                    Text(episodeMeta)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
            if canShowImages {
                Divider()
                Button("查看本集剧照", systemImage: "photo") { onShowImages() }
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

    /// 「2011-04-17 · 60 分钟 · ★ 7.8」。缺哪段不显示哪段,整段没有就 nil(`CLAUDE.md` 硬规则 4)。
    /// ⚠️ 来自 TMDB 季详情(§7),不是本地文件的时长。
    private var episodeMeta: String? {
        var parts: [String] = []
        if let date = MediaFormat.date(episode.airDate) { parts.append(date) }
        if let runtime = episode.episodeRuntime, runtime > 0 { parts.append("\(runtime) 分钟") }
        if let rating = MediaFormat.rating(episode.episodeVoteAverage) { parts.append("★ \(rating)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
