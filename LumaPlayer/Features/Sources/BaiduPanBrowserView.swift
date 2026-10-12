import SwiftUI

/// 百度网盘目录浏览(**海报墙**)。
///
/// ## 封面从哪来
///
/// 百度不给视频封面,所以封面是**本地合成**的:同目录的
/// `<同名>.jpg` / `poster.jpg` / `folder.jpg`(`docs/SOURCE_ABSTRACTION_PLAN.md` §6.3)。
/// 本地配不到时,再由后台第二趟问 TMDB 补(设置里填了 token 才走,
/// 见 `BaiduPanMetadataScraper`;用户自己放的图优先,⛔ 不被盖掉)。
/// 两样都没有就不伪造 —— 卡片降级成图标卡,⛔ 绝不留一片空白占位图假装有封面。
///
/// ## 为什么点一下就是播放
///
/// 这里的条目是**媒体文件本身**,不是 Emby 那种「进详情页再选集」的结构。
/// 点目录就进目录,点文件就播 —— 与文件管理器一致,不需要中间那一层。
struct BaiduPanBrowserView: View {
    let viewModel: BaiduPanSourceViewModel
    let store: PosterImageStore

    /// ⛔ 唤起播放窗口。**写请求与开窗必须成对出现**:`AppState.nowPlaying`
    /// 只是「请播放器播这一项」的请求,窗口不会因为写了请求自己出现 ——
    /// 少了 `openWindow` 就是点了播放毫无动静(Emby 那 4 个调用点同理)。
    @Environment(\.openWindow) private var openWindow

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Metrics.posterMinWidth), spacing: Metrics.gridSpacing)]
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            if let notice = viewModel.notice {
                OnboardingNotice(text: notice, style: .warning)
                    .padding(.horizontal, Metrics.spacingL)
                    .padding(.vertical, Metrics.spacingS)
                Divider()
            }
            if let scrapeFailure = viewModel.scrapeFailure {
                // 刮削失败只影响封面:目录照常能看,所以是提示而不是错误页
                // (CLAUDE.md 硬规则 4「不静默吞错」:失败原因如实说出来)。
                OnboardingNotice(text: scrapeFailure, style: .warning)
                    .padding(.horizontal, Metrics.spacingL)
                    .padding(.vertical, Metrics.spacingS)
                Divider()
            }
            content
        }
    }

    // MARK: - 路径栏

    private var pathBar: some View {
        HStack(spacing: Metrics.spacingS) {
            Button {
                Task { await viewModel.goUp() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!viewModel.canGoUp)
            .help("返回上一层")

            if let account = viewModel.authorization?.accountName {
                Label(account, systemImage: "person.crop.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            libraryRootMark

            Text(viewModel.relativePath ?? "/")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            libraryRootButton

            Button {
                Task { await viewModel.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(viewModel.isLoadingFiles)
            .help("刷新")

            Button("解除授权") {
                Task { await viewModel.signOut() }
            }
            .help("清除本机保存的百度授权,回到扫码那一屏")
        }
        .padding(.horizontal, Metrics.spacingL)
        .padding(.vertical, Metrics.spacingS)
    }

    // MARK: - 片库根

    /// 当前目录就是片库根时,在路径前面挂一个书签标记。
    @ViewBuilder
    private var libraryRootMark: some View {
        if viewModel.isCurrentDirectoryLibraryRoot {
            Image(systemName: "bookmark.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("这里是片库根:每次打开百度网盘都会先落在这个目录")
        }
    }

    @ViewBuilder
    private var libraryRootButton: some View {
        if viewModel.canSetLibraryRoot {
            Button("设为片库根", systemImage: "bookmark") {
                Task { await viewModel.setLibraryRootToCurrentDirectory() }
            }
            .help("把当前目录设为进入百度网盘时的起点")
        } else if viewModel.isCurrentDirectoryLibraryRoot {
            Button("取消片库根", systemImage: "bookmark.slash") {
                Task { await viewModel.clearLibraryRoot() }
            }
            .help("回到应用目录作为进入时的起点")
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
        } else if viewModel.items.isEmpty, viewModel.resumeCards.isEmpty {
            ContentUnavailableView {
                Label("这里还没有可播的文件", systemImage: "folder")
            } description: {
                Text(emptyHint)
            } actions: {
                Button("刷新") { Task { await viewModel.loadFiles() } }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.spacingXL) {
                    if !viewModel.resumeCards.isEmpty {
                        resumeShelf
                    }
                    if !viewModel.items.isEmpty {
                        LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                            ForEach(viewModel.items) { item in
                                BaiduPanCard(
                                    item: item,
                                    store: store,
                                    resumeSeconds: viewModel.resumeSeconds(for: item)
                                ) {
                                    open(item)
                                }
                            }
                        }
                    }
                }
                .padding(Metrics.spacingXL)
            }
        }
    }

    // MARK: - 继续观看

    /// 顶部「继续观看」区:跨目录把看过的东西捞出来(Emby 首页那一行的对位物)。
    /// 数据来自本地续播库(百度没有服务端进度),见 `BaiduPanSourceViewModel.resumeCards`。
    private var resumeShelf: some View {
        MediaShelf(title: "继续观看") {
            ForEach(viewModel.resumeCards) { card in
                BaiduResumeCardView(card: card, store: store) {
                    open(card)
                }
                .contextMenu {
                    Button("移出继续观看", systemImage: "eye.slash") {
                        Task { await viewModel.removeResumeCard(card) }
                    }
                }
            }
        }
    }

    // MARK: - 动作

    /// 目录 → 进去;可播文件 → 播;其余(图片等)不在这里出现(合成器已滤掉)。
    private func open(_ item: SourceItem) {
        if item.kind.isContainer {
            Task { await viewModel.enter(item) }
        } else if item.kind.isPlayable {
            viewModel.play(item)
            openWindow(id: PlayerSceneRoot.windowID)
        }
    }

    /// 续播卡片 → 直接续播(起播位置由本地续播库给)。
    private func open(_ card: BaiduResumeCard) {
        viewModel.play(card)
        openWindow(id: PlayerSceneRoot.windowID)
    }

    /// 目录读失败。分两种处置:
    ///
    /// - **应用目录本身读不出来** → 给「核对应用目录名」(改那个名字),
    ///   而不是「重试」。因为这种失败九成是目录名与控制台里的应用名不一致,
    ///   重试多少次都是同一个结果(可访问范围完全由那一个值决定)。
    /// - 其余(子目录、网络、token)→ 老实的错误 + 重试。
    private func failurePane(_ failure: BaiduPanDirectoryFailure) -> some View {
        VStack(spacing: Metrics.spacingM) {
            if failure.isApplicationRootUnavailable {
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
            Button("重试") { Task { await viewModel.loadFiles() } }
        }
        .padding(Metrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 空目录的引导。
    ///
    /// ⚠️ 刻意把「空的」与「还不存在」合在一段里说:对一个**不存在**的目录,
    /// 百度未必返回错误码 —— 也可能就是一个空 `list`。
    /// ⛔ 不猜它属于哪一种,把两种成因和各自的做法都摆出来。
    ///
    /// 另一件必须讲清的事:**`/apps` 这一层用户建不了**(百度把 `apps` 当保留
    /// 关键字,自建会报「apps 为关键字,无法创建」)。用户能碰的只有
    /// 「我的应用数据」**里面** —— 在那里新建一个与控制台应用名**完全一致**
    /// (含大小写)的文件夹。⛔ 绝不能写成「去网盘里建一个 apps 文件夹」。
    private var emptyHint: String {
        let name = viewModel.folderName ?? "应用目录"
        guard viewModel.relativePath == "/" else {
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

/// 百度来源的一张卡片。
///
/// 视觉与 `MediaCard`(Emby 那边)保持一致:非玻璃卡片、`.fill` 的图只当 overlay
/// 绘制(否则会按自己的比例报告溢出尺寸、把网格撑乱)、续播用文字而不是只靠颜色
/// (DesignTokens.swift「界面规则」)。
private struct BaiduPanCard: View {
    let item: SourceItem
    let store: PosterImageStore
    /// 本地续播位置(秒);nil = 没看过
    let resumeSeconds: Double?
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                // 尺寸由 Color.clear 钉死,图片只当 overlay(与 `MediaCard` 同一个理由)
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
                    .scaleEffect(isHovering ? Self.hoverScale : 1)
                    .shadow(
                        color: .black.opacity(isHovering ? 0.25 : 0),
                        radius: Metrics.spacingS,
                        y: Metrics.spacingXS
                    )
                VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                    Text(displayTitle)
                        .font(.body)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

    /// 分集用 16:9 横版,其余用海报比例(2:3)。
    ///
    /// ⚠️ 为什么分集要换:分集拿的是**分集剧照**(16:9 横图,`docs/TMDB_API.md` §8),
    /// 塞进竖版框会被裁掉一大半画面。一屏全是分集的剧集目录因此长成 Emby 的分集视图。
    private var imageAspectRatio: Double {
        item.kind == .episode ? Metrics.landscapeAspectRatio : Metrics.posterAspectRatio
    }

    /// 主标题:分集优先显示**集名** —— 集名才是这一集的标识,
    /// 而剧名(`琅琊榜`)整目录每一张都一样、看了等于没看。
    /// 没有集名(TMDB 未命中 / 未配置 token)时退回 `title`。
    private var displayTitle: String {
        item.episodeTitle ?? item.title
    }

    /// 副标题:有续播就报「已看到 mm:ss」(百度没有服务端进度,这条来自本地库);
    /// 其次是集号(分集的主标题是集名,不报集号就分不清是哪一集);
    /// 再次是年份(从文件名解析出来的);目录则标明它是文件夹。
    /// ⛔ 都没有就不显示,不填占位符。
    @ViewBuilder
    private var subtitle: some View {
        if let resumeSeconds, resumeSeconds > 0 {
            Text("已看到 \(PlayerTime.text(resumeSeconds))")
        } else if let episode = item.episodeNumber {
            Text("第 \(episode) 集")
        } else if let year = item.year {
            Text(String(year))
        } else if item.kind.isContainer {
            Text("文件夹")
        }
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
        if let year = item.year { parts.append(String(year)) }
        if let resumeSeconds, resumeSeconds > 0 {
            parts.append("已看到 \(PlayerTime.text(resumeSeconds))")
        }
        return parts.joined(separator: ",")
    }
}

/// 「继续观看」区的一张横版卡片。
///
/// 与 `BaiduPanCard` 的差别:横版(续播用剧照比例,与 Emby 侧 `LandscapeCard` 一致)、
/// 副标题固定报「已看到 mm:ss」、有总时长时在图上画进度条。
private struct BaiduResumeCardView: View {
    let card: BaiduResumeCard
    let store: PosterImageStore
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                // 尺寸由 Color.clear 钉死,图片与进度条只当 overlay(与 `BaiduPanCard` 同理)
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
                    Text("已看到 \(PlayerTime.text(card.positionSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: Metrics.landscapeCardWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.title),已看到 \(PlayerTime.text(card.positionSeconds))")
    }

    private static var hoverScale: CGFloat { 1.03 }

    /// 进度条比例。百度侧**可能没有总时长**(续播库里 `durationSeconds` 为 nil),
    /// 那就**不画**进度条 —— ⛔ 不猜一个比例。
    private var progressFraction: Double? {
        guard let duration = card.durationSeconds, duration > 0 else { return nil }
        return min(max(card.positionSeconds / duration, 0), 1)
    }
}
