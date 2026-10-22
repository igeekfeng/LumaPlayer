import SwiftUI

/// 文件树来源(百度网盘 / 本地文件夹)的目录海报墙。
///
/// - 封面本地合成(同目录 `<同名>.jpg` / `poster.jpg` / `folder.jpg`),配不到再由后台问 TMDB
///   (`BaiduPanMetadataScraper`,用户自己放的图优先)。都没有就降级成图标卡,⛔ 不伪造封面。
/// - 条目是媒体文件本身:点目录进目录,点文件就播。续播区例外,交互同 Emby 首页
///   (悬停播放按钮续播,点其余位置进详情页,见 `FileSourceResumeCardView`)。
/// - 顺序由客户端排(`BaiduPanSortOrder`),百度返回的是纯字符串序。
/// - 页顶标题是当前目录名(`PageHeader`;剧目录走详情页时不画)。返回上一层登记到主窗口顶栏
///   (`BrowseChromeController.pageBackAction`),只退到最外层(`canGoUp`);刷新用顶栏按钮
///   (`refreshToken`),其余配置在设置里(`BaiduPanSourceSettingsView`)。⛔ 不自绘路径栏。
struct FileSourceBrowserView: View {
    @Bindable var viewModel: FileSourceViewModel
    let store: PosterImageStore

    /// ⛔ 写 `AppState.nowPlaying` 与 `openWindow` 必须成对,窗口不会因请求自己出现
    @Environment(\.openWindow) private var openWindow
    @Environment(\.browseChrome) private var chrome

    @State private var pendingDeletion: SourceItem?

    /// 重命名请求。目录与 ViewModel ⛔ 必须装在同一个载荷里交给 `.sheet(item:)`:分成两个 `@State`
    /// 时 sheet 内容闭包可能读到上一次的值(首次空白面板,之后显示上一部剧)。
    /// `id` 用 `UUID` 而非 `fsID`:同一目录连改两次时 `@State didStart` 不能被复用。
    /// ⛔ 不在 sheet 闭包里新建 ViewModel:闭包会重算,进度会丢。
    private struct RenameRequest: Identifiable {
        let id = UUID()
        let directory: BaiduPanFile
        let viewModel: BaiduPanRenameSeriesViewModel
    }

    @State private var renameRequest: RenameRequest?
    /// 删除失败的原因,确认面板关掉后由 alert 报出
    @State private var actionErrorMessage: String?
    @State private var showsFolderPicker = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Metrics.posterMinWidth), spacing: Metrics.gridSpacing)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // 剧目录走详情页,它自己有剧名
            if viewModel.directoryShape.seriesStructure == nil {
                PageHeader(title: viewModel.currentDirectoryName) {
                    HStack(spacing: Metrics.spacingS) {
                        sortMenu
                        filterMenu
                    }
                }
            }
            if let notice = viewModel.notice {
                OnboardingNotice(text: notice, style: .warning)
                    .padding(.horizontal, Metrics.spacingL)
                    .padding(.vertical, Metrics.spacingS)
                Divider()
            }
            if let scrapeFailure = viewModel.scrapeFailure {
                // 刮削失败只影响封面,给提示而非错误页
                OnboardingNotice(text: scrapeFailure, style: .warning)
                    .padding(.horizontal, Metrics.spacingL)
                    .padding(.vertical, Metrics.spacingS)
                Divider()
            }
            content
        }
        // 「窗口」菜单与调度中心里的窗口名(页上的目录名在 `PageHeader`)
        .navigationTitle(viewModel.currentDirectoryName)
        // 到了最外层就不登记,顶栏没有返回按钮
        .onChange(of: viewModel.canGoUp, initial: true) { _, canGoUp in
            registerBackAction(canGoUp: canGoUp)
        }
        .onDisappear {
            chrome?.pageBackAction = nil
            chrome?.setRootHasHero(false, source: viewModel.sourceID)
        }
        // 剧目录走详情页(有 hero):顶栏栏底换成 hero 的压暗
        .onChange(of: viewModel.directoryShape.seriesStructure != nil, initial: true) { _, isSeries in
            chrome?.setRootHasHero(isSeries, source: viewModel.sourceID)
        }
        .sheet(item: $pendingDeletion) { item in
            FileSourceDeleteItemView(item: item, viewModel: viewModel) { message in
                actionErrorMessage = message
            }
        }
        .sheet(item: $renameRequest) { request in
            BaiduPanRenameSeriesView(
                viewModel: request.viewModel,
                directory: request.directory
            ) {
                // 改名后缓存里的旧目录已失效
                Task { await viewModel.refreshFiles() }
            }
        }
        .fileImporter(
            isPresented: $showsFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                Task { await viewModel.relinkFolder(to: url) }
            case .failure(let error):
                actionErrorMessage = "选择文件夹失败:\(error.localizedDescription)"
            }
        }
        // 同 `ServerListView`:确认面板关掉后再报失败
        .alert("操作失败", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    // MARK: - 返回上一层

    private func registerBackAction(canGoUp: Bool) {
        guard canGoUp else {
            chrome?.pageBackAction = nil
            return
        }
        let viewModel = viewModel
        chrome?.pageBackAction = {
            Task { await viewModel.goUp() }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoadingFiles, viewModel.items.isEmpty {
            VStack(spacing: Metrics.spacingS) {
                ProgressView()
                Text("正在读取目录…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure = viewModel.directoryFailure {
            failurePane(failure)
        } else if let structure = viewModel.directoryShape.seriesStructure {
            FileSourceSeriesDetailView(
                viewModel: viewModel,
                structure: structure,
                store: store
            )
        } else if viewModel.sortedItems.isEmpty, viewModel.resumeCards.isEmpty {
            // 判 `sortedItems` 而非 `items`:整层被隐藏时 `items` 非空,会既无网格也无空状态
            if isFilterHidingEverything {
                ContentUnavailableView {
                    Label("当前筛选下没有条目", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("这个目录里有内容,只是都被「\(viewModel.watchFilter.title)」这一档筛掉了。")
                } actions: {
                    Button("显示全部") { viewModel.setWatchFilter(.all) }
                }
            } else {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptySymbol)
                } description: {
                    Text(emptyHint)
                } actions: {
                    Button("刷新") { Task { await viewModel.refreshFiles() } }
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.spacingXL) {
                    if !viewModel.resumeCards.isEmpty {
                        resumeShelf
                    }
                    if !viewModel.recentItems.isEmpty {
                        recentShelf
                    }
                    if !viewModel.sortedItems.isEmpty {
                        LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                            ForEach(viewModel.sortedItems) { item in
                                card(for: item)
                            }
                        }
                    }
                }
                .padding(Metrics.spacingXL)
            }
        }
    }

    /// 主网格与「最近添加」共用,保证两处右键菜单一致
    private func card(for item: SourceItem) -> some View {
        FileSourceCard(
            item: item,
            store: store,
            resumeSeconds: viewModel.resumeSeconds(for: item),
            isWatched: viewModel.isFullyWatched(item),
            watchedEpisodeCount: viewModel.watchedEpisodeCount(for: item),
            episodeTotal: viewModel.episodeTotal(for: item)
        ) {
            open(item)
        }
        .contextMenu {
            // 只对能播的文件给:标目录要先列目录(配额),不在右键里悄悄做
            if item.kind.isPlayable {
                if viewModel.isWatched(item) {
                    Button("标记为未看", systemImage: "arrow.counterclockwise") {
                        Task { await viewModel.markPlayed([item], played: false) }
                    }
                } else {
                    Button("标记为已看", systemImage: "checkmark.circle") {
                        Task { await viewModel.markPlayed([item], played: true) }
                    }
                }
            }
            // 只对剧集目录给(单集文件没有剧 / 季上下文);只读来源不给
            if item.kind.isContainer, viewModel.source.supportsRenamingSeries,
               let file = viewModel.file(for: item) {
                Button("按 TMDB 命名重命名…", systemImage: "arrow.triangle.2.circlepath") {
                    renameRequest = RenameRequest(
                        directory: file,
                        viewModel: viewModel.makeRenameViewModel())
                }
            }
            Button("删除…", systemImage: "trash", role: .destructive) {
                pendingDeletion = item
            }
        }
    }

    /// 卡片宽度要自己钉住:`MediaShelf` 是横向 `LazyHStack`,没有列宽可借
    private var recentShelf: some View {
        MediaShelf(title: "最近添加") {
            ForEach(viewModel.recentItems) { item in
                card(for: item)
                    .frame(width: Metrics.posterMinWidth)
            }
        }
    }

    // MARK: - 排序 / 筛选

    /// 放页头而非主窗口工具栏(工具栏只留返回)。⛔ 换档不重新请求目录。
    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: Binding(
                get: { viewModel.sortOrder },
                set: { viewModel.setSortOrder($0) }
            )) {
                ForEach(BaiduPanSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button(
                viewModel.sortAscending ? "改为降序" : "改为升序",
                systemImage: viewModel.sortAscending ? "arrow.down" : "arrow.up"
            ) {
                viewModel.toggleSortDirection()
            }
        } label: {
            Label("排序", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("排序(只重排已取回的条目,不重新请求目录)")
        .accessibilityLabel("排序:\(viewModel.sortOrder.title)")
    }

    /// 按钮带图标:收起后只剩一个词,「已看」「未看」太像
    private var filterMenu: some View {
        Menu {
            Picker("筛选", selection: Binding(
                get: { viewModel.watchFilter },
                set: { viewModel.setWatchFilter($0) }
            )) {
                ForEach(BaiduPanWatchFilter.allCases) { filter in
                    Label(filter.title, systemImage: filter.symbol).tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(viewModel.watchFilter.title, systemImage: viewModel.watchFilter.symbol)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("按观看状态筛选(只筛已取回的条目,不重新请求目录)")
        .accessibilityLabel("筛选:\(viewModel.watchFilter.title)")
    }

    /// 被筛空要与目录真空分开提示,否则像片库坏了
    private var isFilterHidingEverything: Bool {
        viewModel.watchFilter != .all && !viewModel.items.isEmpty
    }

    // MARK: - 继续观看

    /// 跨目录续播区,数据来自本地续播库(`FileSourceViewModel.resumeCards`)
    private var resumeShelf: some View {
        MediaShelf(title: "继续观看") {
            ForEach(viewModel.resumeCards) { card in
                FileSourceResumeCardView(
                    card: card,
                    store: store,
                    isPreparing: viewModel.preparingPlaybackFileID == card.fileID,
                    onPlay: { play(card) },
                    onOpenDetail: { openDetail(card) }
                )
                .contextMenu {
                    Button("继续播放", systemImage: "play.fill") { play(card) }
                    Button("显示详情", systemImage: "info.circle") { openDetail(card) }
                    Divider()
                    Button("标记为已看", systemImage: "checkmark.circle") {
                        Task { await viewModel.markPlayed(card) }
                    }
                    Button("移出继续观看", systemImage: "eye.slash") {
                        Task { await viewModel.removeResumeCard(card) }
                    }
                }
            }
        }
    }

    // MARK: - 动作

    /// 图片等非媒体文件已被合成器滤掉
    private func open(_ item: SourceItem) {
        if item.kind.isContainer {
            Task { await viewModel.enter(item) }
        } else if item.kind.isPlayable {
            viewModel.play(item)
            openWindow(id: PlayerSceneRoot.windowID)
        }
    }

    /// 等 `viewModel.play(card)` 补列完目录再开窗,否则会先弹一个黑窗口
    private func play(_ card: FileSourceResumeCard) {
        Task {
            if await viewModel.play(card) {
                openWindow(id: PlayerSceneRoot.windowID)
            }
        }
    }

    /// 详情页在主窗口里,不 `openWindow`
    private func openDetail(_ card: FileSourceResumeCard) {
        Task { await viewModel.openDetail(for: card) }
    }

    /// 应用目录读不出 → 「核对应用目录名」(多半与控制台应用名不一致,重试无用);
    /// 本地访问权没了 → 「重新选择文件夹…」(外接盘插回后重试也能好);其余 → 错误 + 重试。
    private func failurePane(_ failure: FileSourceDirectoryFailure) -> some View {
        VStack(spacing: Metrics.spacingM) {
            if failure.needsFolderReselection {
                OnboardingFormHeader(
                    systemImage: "folder.badge.questionmark",
                    title: "打不开这个文件夹",
                    subtitle: failure.message
                )
                Button("重新选择文件夹…") { showsFolderPicker = true }
                    .buttonStyle(.borderedProminent)
            } else if failure.isApplicationRootUnavailable {
                OnboardingFormHeader(
                    systemImage: "folder.badge.questionmark",
                    title: "读不到应用目录",
                    subtitle: applicationRootHint
                )
                Button("核对应用目录名") {
                    Task { await viewModel.beginConfigurationEdit() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                OnboardingNotice(text: failure.message, style: .error)
            }
            Button("重试") { Task { await viewModel.refreshFiles() } }
        }
        .padding(Metrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 空目录引导。
    /// - 不存在的目录百度可能只返回空 `list`,所以「空的」与「还不存在」合在一段说,⛔ 不猜。
    /// - `/apps` 用户建不了(保留关键字),只能在「我的应用数据」里建与控制台应用名完全一致的文件夹;
    ///   ⛔ 不能引导去建 apps 文件夹。
    /// - 整层被隐藏要说明去哪恢复,⛔ 不能混成「没有可播的文件」。
    private var emptyTitle: String {
        viewModel.items.isEmpty ? "这里还没有可播的文件" : "这一层都被隐藏了"
    }

    private var emptySymbol: String {
        viewModel.items.isEmpty ? "folder" : "eye.slash"
    }

    private var emptyHint: String {
        guard viewModel.items.isEmpty else {
            return "这些条目只是在本机被隐藏了,\(viewModel.source.storageNoun)里的文件都还在。"
                + "设置 →「已隐藏」里可以逐条恢复。"
        }
        guard case .baiduPan = viewModel.source else {
            return "这一层没有可播的文件。把视频放进这个文件夹,再回来刷新。"
        }
        let name = viewModel.folderName ?? "应用目录"
        // 应用目录根是空的,多半是应用目录还没建出来
        guard viewModel.currentDirectory == viewModel.rootDirectory else {
            return "这一层没有可播的文件。往上一级看看,或者把视频放进这个目录再回来刷新。"
        }
        return "第三方应用只能访问网盘里的「我的应用数据/\(name)」,访问不到其它地方。"
            + "如果网盘里还看不到这个目录:打开百度网盘的「我的应用数据」,新建一个名为"
            + " \(name) 的文件夹(名字要与开放平台控制台里的「应用名称」完全一致,"
            + "包括大小写),再把视频放进去,然后回来刷新。"
            + "也可能它还没生成 —— 网盘通常在应用第一次读取时自动建出这个目录。"
    }

    private var applicationRootHint: String {
        let name = viewModel.folderName ?? "应用目录"
        return "百度没给出 /apps/\(name) 这个目录。请核对开放平台控制台里的「应用名称」"
            + "与本 App 里填的完全一致,并确认网盘里的「我的应用数据/\(name)」确实存在。"
    }
}

/// 视觉同 `MediaCard`:非玻璃、`.fill` 的图只当 overlay(否则撑乱网格)、续播用文字不只靠颜色
/// (DesignTokens.swift「界面规则」)。
private struct FileSourceCard: View {
    let item: SourceItem
    let store: PosterImageStore
    /// nil = 未看或已看完
    let resumeSeconds: Double?
    let isWatched: Bool
    /// 目录卡用,0 = 不显示
    let watchedEpisodeCount: Int
    /// 目录卡用,nil = 不知道(见 `FileSourceViewModel.episodeTotal(for:)`)
    let episodeTotal: Int?
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                // 尺寸由 Color.clear 钉死,图片只当 overlay
                Color.clear
                    .aspectRatio(imageAspectRatio, contentMode: .fit)
                    .overlay {
                        PosterImage(
                            descriptor: item.poster,
                            store: store,
                            placeholderSystemImage: placeholderSymbol
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .overlay(alignment: .topTrailing) {
                        if isWatched { WatchedBadge() }
                    }
                    .scaleEffect(isHovering ? Self.hoverScale : 1)
                    .shadow(
                        color: .black.opacity(isHovering ? 0.25 : 0),
                        radius: Metrics.spacingS,
                        y: Metrics.spacingXS
                    )
                textBlock
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private static var hoverScale: CGFloat { 1.03 }

    /// 分集用 16:9(TMDB 分集剧照是横图,`docs/TMDB_API.md` §8),其余 2:3 海报
    private var imageAspectRatio: Double {
        item.kind == .episode ? Metrics.landscapeAspectRatio : Metrics.posterAspectRatio
    }

    /// 高度固定(否则网格高低不齐):叠一份等行数的隐藏文本当尺子,⛔ 不写死像素(字体 / 缩放会变)。
    @ViewBuilder
    private var textBlock: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            ZStack(alignment: .topLeading) {
                Text(Self.placeholderTwoLines)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .accessibilityHidden(true)
                Text(displayTitle)
                    .font(.body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack(alignment: .topLeading) {
                Text(Self.placeholderOneLine)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .accessibilityHidden(true)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 用 ASCII:中文回退字体行高与 SF 不同,尺子会量歪
    private static let placeholderTwoLines = "X\nX"
    private static let placeholderOneLine = "X"

    /// 分集优先集名(剧名整目录都一样),没有时退回 `title`
    private var displayTitle: String {
        item.episodeTitle ?? item.title
    }

    /// 进度类信息优先,其次集号 / 时长 / 年份 / 目录集数。都没有就 nil,⛔ 不填占位符;
    /// 拿不到时长整段不出现,⛔ 不写「未知时长」。
    private var subtitle: String? {
        if let resumeSeconds, resumeSeconds > 0 {
            return "已看到 \(PlayerTime.text(resumeSeconds))"
        }
        if let episode = item.episodeNumber {
            let label = isWatched ? "第 \(episode) 集 · 已看" : "第 \(episode) 集"
            guard !isWatched, let runtime = MediaFormat.duration(seconds: item.durationSeconds ?? 0)
            else { return label }
            return "\(label) · \(runtime)"
        }
        if isWatched { return "已看" }
        if let runtime = MediaFormat.duration(seconds: item.durationSeconds ?? 0) {
            return runtime
        }
        if let year = item.year { return String(year) }
        if item.kind.isContainer {
            if let episodeTotal, watchedEpisodeCount > 0 {
                return "已看 \(watchedEpisodeCount) / 共 \(episodeTotal) 集"
            }
            if let episodeTotal { return "共 \(episodeTotal) 集" }
            return watchedEpisodeCount > 0 ? "已看 \(watchedEpisodeCount) 集" : "文件夹"
        }
        return nil
    }

    private var placeholderSymbol: String {
        switch item.kind {
        case .folder: return "folder.fill"
        case .audio: return "music.note"
        case .episode: return "tv"
        case .video, .movie: return "film"
        case .image: return "photo"
        case .unknown: return "doc"
        }
    }

    private var accessibilityText: String {
        var parts = [displayTitle]
        if item.kind.isContainer { parts.append("文件夹") }
        if let episode = item.episodeNumber { parts.append("第 \(episode) 集") }
        if isWatched { parts.append("已看") }
        if !isWatched, let runtime = MediaFormat.duration(seconds: item.durationSeconds ?? 0) {
            parts.append(runtime)
        }
        if item.kind.isContainer, watchedEpisodeCount > 0 {
            parts.append(
                episodeTotal.map { "本地记录已看 \(watchedEpisodeCount) 集,共 \($0) 集" }
                    ?? "本地记录已看 \(watchedEpisodeCount) 集")
        } else if item.kind.isContainer, let episodeTotal {
            parts.append("共 \(episodeTotal) 集")
        }
        if let year = item.year { parts.append(String(year)) }
        if let resumeSeconds, resumeSeconds > 0 {
            parts.append("已看到 \(PlayerTime.text(resumeSeconds))")
        }
        return parts.joined(separator: ",")
    }
}

/// 续播区横版卡片,交互同 Emby 的 `LandscapeCard`:悬停出播放按钮直接续播,点其余位置进详情页。
/// 有总时长时画进度条。
private struct FileSourceResumeCardView: View {
    let card: FileSourceResumeCard
    let store: PosterImageStore
    /// 正在补列目录:转圈 + 禁止重复点击
    var isPreparing = false
    let onPlay: () -> Void
    let onOpenDetail: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            // 尺寸由 Color.clear 钉死,其余只当 overlay
            Color.clear
                .aspectRatio(Metrics.landscapeAspectRatio, contentMode: .fit)
                .frame(width: Metrics.landscapeCardWidth)
                .overlay {
                    PosterImage(
                        descriptor: card.poster,
                        store: store,
                        placeholderSystemImage: "play.rectangle"
                    )
                }
                .overlay {
                    if isPreparing {
                        ZStack {
                            Color.black.opacity(0.45)
                            ProgressView()
                        }
                    }
                }
                .overlay {
                    // 卡上唯一「点了就播」的地方
                    if isHovering, !isPreparing {
                        Button(action: onPlay) {
                            Image(systemName: "play.fill")
                                .font(.title2)
                                .padding(Metrics.spacingM)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .help("继续播放")
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let fraction = progressFraction {
                        CardProgressBar(fraction: fraction)
                            .padding(Metrics.spacingS)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .scaleEffect(isHovering ? Self.hoverScale : 1)
                .shadow(
                    color: .black.opacity(isHovering ? 0.25 : 0),
                    radius: Metrics.spacingS,
                    y: Metrics.spacingXS
                )
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text(card.title)
                    .font(.body)
                    .lineLimit(1)
                Text(isPreparing ? "正在准备…" : card.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: Metrics.landscapeCardWidth, alignment: .leading)
        }
        // 播放按钮的命中优先于外层手势
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenDetail)
        // 两个都要:`.disabled` 管控件与辅助功能,主体是 `onTapGesture` 得靠 `allowsHitTesting`
        .disabled(isPreparing)
        .allowsHitTesting(!isPreparing)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.title),\(card.subtitle)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpenDetail() }
        .accessibilityAction(named: "播放") { onPlay() }
    }

    private static var hoverScale: CGFloat { 1.03 }

    /// 没有总时长或是「下一集」占位时不画,⛔ 不猜比例
    private var progressFraction: Double? {
        guard !card.isUpNext else { return nil }
        guard let duration = card.durationSeconds, duration > 0 else { return nil }
        return min(max(card.positionSeconds / duration, 0), 1)
    }
}
