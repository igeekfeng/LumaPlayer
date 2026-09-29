import SwiftUI
import AppKit

/// 播放器窗口的根视图(独立窗口,ARCHITECTURE.md 7.5)。
///
/// 窗口是单实例的:内容由 `AppState.nowPlaying` 决定,换请求就按新 `id`
/// 重建播放页(旧的随 `onDisappear` 走完收尾上报)。没有请求时关窗 ——
/// 切换 / 删除服务器会清空请求(UI_DESIGN.md 7.1)。
struct PlayerSceneRoot: View {
    static let windowID = "player"

    let container: AppContainer
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let request = container.state.nowPlaying {
                PlayerWindowView(container: container, request: request)
                    .id(request.id)
            } else {
                Color.black
            }
        }
        // 只在「有请求 → 无请求」的跳变上关窗,不能挂在 Color.black 的 onAppear 上:
        // 用户关窗时 tearDown 把请求清空,但窗口已关、这次更新没渲染出来;
        // 下次 openWindow 时 SwiftUI 补上积压的 onAppear,刚打开的窗口立刻被关掉,
        // 新请求也随 tearDown 一起清空 —— 表现为再点播放没反应(本机最小复现实测)。
        .onChange(of: container.state.nowPlaying?.id) { old, new in
            if old != nil, new == nil { dismissWindow(id: Self.windowID) }
        }
        // 深色环境:视频背景亮度不可控,玻璃与文字按深色外观取色才稳定可读(UI_DESIGN.md 8.1)
        .environment(\.colorScheme, .dark)
    }
}

/// 播放页(画面、控制栏、快捷键、自动隐藏)。
///
/// 视频层走 `MPVView`(libmpv 的 OpenGL 渲染路径,不经过 SwiftUI 管线),
/// 其余是覆盖在上面的 SwiftUI 控件层。
struct PlayerWindowView: View {
    let container: AppContainer
    let request: PlaybackRequest

    @State private var viewModel: PlayerViewModel
    @State private var nowPlaying = NowPlayingController()
    @State private var window = WindowBox()
    @State private var trackpad = TrackpadScrubMonitor()

    /// 控制层(标题栏 + 控制栏 + 红绿灯)是否可见
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    /// 鼠标停在控制栏上时不自动隐藏
    @State private var isHoveringControls = false
    /// 倍速浮层打开中:控制栏要一直留着,否则它会在自动隐藏时连浮层一起带走
    @State private var isSpeedPopoverPresented = false
    /// 正在显示的屏显提示(比 `viewModel.osd` 晚一拍清空)
    @State private var shownOSD: PlayerOSD?
    @FocusState private var isFocused: Bool
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(container: AppContainer, request: PlaybackRequest) {
        self.container = container
        self.request = request
        self._viewModel = State(
            initialValue: PlayerViewModel(
                container: container,
                server: request.server,
                item: request.item,
                startFromBeginning: request.startFromBeginning
            )
        )
    }

    var body: some View {
        ZStack {
            Color.black
            if let player = viewModel.player {
                MPVView(player: player)
            }
            interactionLayer
            overlay
        }
        .ignoresSafeArea()
        .frame(minWidth: 640, minHeight: 360)
        .background(WindowReader {
            window.window = $0
            window.setFloating(viewModel.floatsOnTop)
        })
        .navigationTitle(windowTitle)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .focusedSceneValue(\.playerViewModel, viewModel)
        .onAppear {
            isFocused = true
            installTrackpadScrubbing()
        }
        .task { viewModel.start() }
        .task { await loadNowPlayingArtwork() }
        .onDisappear(perform: tearDown)
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .onChange(of: viewModel.isPaused) { _, paused in
            // 暂停时常驻;恢复播放后多等一会儿再隐藏(UI_DESIGN.md 2.1 autoHideResumeDelay)
            if paused { revealControls(autoHide: false) } else { revealControls(delay: Metrics.autoHideResumeDelay) }
            nowPlaying.update(from: viewModel)
        }
        .onChange(of: viewModel.phase) { _, phase in
            if phase == .playing { revealControls() }
            nowPlaying.update(from: viewModel)
        }
        .onChange(of: viewModel.speed) { nowPlaying.update(from: viewModel) }
        .onChange(of: viewModel.durationSeconds) { nowPlaying.update(from: viewModel) }
        .onChange(of: Int(viewModel.positionSeconds) / Self.nowPlayingResyncSeconds) {
            // 系统「正在播放」按 rate 自己外推进度,只需定期校准,不必跟着每 0.2s 的 time-pos 走
            nowPlaying.update(from: viewModel)
        }
        .onChange(of: viewModel.isEnded) { _, ended in
            if ended { revealControls(autoHide: false) }
            nowPlaying.update(from: viewModel)
        }
        .onChange(of: controlsVisible) { _, visible in
            window.setTitlebarButtonsVisible(visible)
        }
        .onChange(of: viewModel.floatsOnTop) { _, floats in
            window.setFloating(floats)
        }
        .onChange(of: viewModel.scrubPreviewSeconds) { _, preview in
            // 横滑拖进度时把控制栏叫出来,进度条跟着预览位置走
            if preview != nil { revealControls() }
        }
        .onChange(of: isSpeedPopoverPresented) { _, presented in
            // 打开时钉住控制栏;关掉后按正常节奏重新计时隐藏
            if presented { revealControls(autoHide: false) } else { revealControls() }
        }
        .onChange(of: viewModel.previousEpisode?.id) { nowPlaying.update(from: viewModel) }
        .onChange(of: viewModel.nextEpisode?.id) { nowPlaying.update(from: viewModel) }
        .task(id: viewModel.osd?.id) { await showOSD() }
        // 快捷键按 UI_DESIGN.md 5.3。Space / M / [ ] / ⌘→ 同时挂在菜单栏「播放」菜单
        // (PlayerCommands):菜单启用时按键先被菜单吃掉,下面的同名处理不会重复触发;
        // 这里保留它们,是为菜单未就绪(焦点值尚未传到菜单)时按键仍然可用。
        // 方向键只取 .down:按住不放时 .repeat 会连续触发 seek,而转码模式下
        // 一次 seek 就是一次重新起流。
        .onKeyPress(.space) { viewModel.togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow, phases: .down) { press in
            viewModel.skip(by: press.modifiers.contains(.shift)
                ? -Metrics.seekStepLarge : -Metrics.seekStep)
            return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            viewModel.skip(by: press.modifiers.contains(.shift)
                ? Metrics.seekStepLarge : Metrics.seekStep)
            return .handled
        }
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
            viewModel.adjustVolume(by: Metrics.volumeStep)
            return .handled
        }
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
            viewModel.adjustVolume(by: -Metrics.volumeStep)
            return .handled
        }
        .onKeyPress("m") { viewModel.toggleMute(); return .handled }
        .onKeyPress("s") {
            // S = 跳过片头(Netflix 的键位);不在片头区间时放行
            guard viewModel.isSkipIntroAvailable else { return .ignored }
            viewModel.skipIntro()
            return .handled
        }
        .onKeyPress("i") { viewModel.toggleStatistics(); return .handled }
        .onKeyPress("f") { toggleFullScreen(); return .handled }
        .onKeyPress(.escape) {
            guard window.isFullScreen else { return .ignored }
            toggleFullScreen()
            return .handled
        }
    }

    /// 系统「正在播放」的进度校准间隔(秒)
    private static let nowPlayingResyncSeconds = 5

    // MARK: - 交互层

    /// 画面本身的点击:单击暂停 / 继续,双击切全屏(QuickTime / IINA 的习惯)。
    /// 顶部留一条可拖动窗口的区域 —— 隐藏标题栏后,没有它窗口就拖不动。
    private var interactionLayer: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: Metrics.spacingXL * 2)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { toggleFullScreen() }
                .onTapGesture {
                    viewModel.togglePlayPause()
                    revealControls()
                }
        }
        .accessibilityHidden(true)
    }

    // MARK: - 覆盖层

    @ViewBuilder
    private var overlay: some View {
        if let failure = viewModel.failure {
            PlaybackErrorView(
                failure: failure,
                retry: { viewModel.retry() },
                dismiss: { close() },
                login: loginAction(for: failure)
            )
        } else {
            ZStack {
                if isBusy || viewModel.isBuffering {
                    statusView
                }
                if viewModel.isEnded {
                    endCard
                }
                if let preview = viewModel.scrubPreviewSeconds {
                    PlayerScrubPreview(
                        target: preview,
                        current: viewModel.positionSeconds,
                        duration: viewModel.durationSeconds
                    )
                }
                if viewModel.showsStatistics, let statistics = viewModel.statistics {
                    PlayerStatisticsView(statistics: statistics)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, Metrics.spacingXL * 3)
                        .padding(.leading, Metrics.spacingXL)
                }
                promptLayer
                controlsLayer
            }
            .animation(controlsAnimation, value: controlsVisible)
            .animation(osdAnimation, value: shownOSD)
        }
    }

    private var controlsAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: Metrics.animationStandard)
    }

    private var osdAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: Metrics.animationFast)
    }

    private var endCard: some View {
        PlayerEndCard(
            nextEpisode: viewModel.nextEpisode,
            countdown: viewModel.upNextCountdown,
            playNext: { viewModel.playNextEpisode() },
            cancelCountdown: { viewModel.dismissUpNext() },
            replay: { viewModel.replay() },
            close: { close() }
        )
    }

    /// 右下角的情境按钮:片头里是「跳过片头」,片尾是「下一集」提示。
    /// 控制栏隐藏时它们照样显示(本身就是要人点的),位置随控制栏让开。
    @ViewBuilder
    private var promptLayer: some View {
        Group {
            if viewModel.isSkipIntroAvailable {
                Button("跳过片头", systemImage: "forward.fill") { viewModel.skipIntro() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("跳过片头(S)")
                    .transition(.opacity)
            } else if viewModel.isUpNextPromptVisible, let next = viewModel.nextEpisode {
                PlayerUpNextPrompt(
                    nextEpisode: next,
                    countdown: viewModel.upNextCountdown,
                    playNext: { viewModel.playNextEpisode() },
                    dismiss: { viewModel.dismissUpNext() }
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, Metrics.spacingXL)
        .padding(.bottom, controlsVisible ? Metrics.playerPromptBottomInset : Metrics.spacingXL)
        .animation(controlsAnimation, value: viewModel.isSkipIntroAvailable)
        .animation(controlsAnimation, value: viewModel.isUpNextPromptVisible)
    }

    private var controlsLayer: some View {
        VStack(spacing: 0) {
            if controlsVisible {
                PlayerTitleBar(viewModel: viewModel)
                    .transition(.opacity)
            }
            if let shownOSD {
                PlayerOSDView(osd: shownOSD)
                    .padding(.top, controlsVisible ? 0 : Metrics.spacingXL * 2)
                    .transition(.opacity)
            }
            Spacer()
            if controlsVisible, viewModel.session != nil {
                controlBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var controlBar: some View {
        let viewModel = viewModel
        let playNext: (() -> Void)? = viewModel.nextEpisode == nil
            ? nil
            : { viewModel.playNextEpisode() }
        return PlayerControlsView(
            viewModel: viewModel,
            toggleFullScreen: { toggleFullScreen() },
            playNext: playNext,
            isSpeedPopoverPresented: $isSpeedPopoverPresented
        )
        .frame(maxWidth: Metrics.contentMaxWidth * 1.5)
        .padding(.horizontal, Metrics.spacingXL)
        .padding(.bottom, Metrics.controlBarBottomInset)
        .onHover { hovering in
            isHoveringControls = hovering
            if !hovering { revealControls() }
        }
    }

    private var statusView: some View {
        VStack(spacing: Metrics.spacingS) {
            ProgressView()
            Text(statusText)
                .font(.caption)
        }
        .padding(Metrics.spacingL)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.panel))
        .allowsHitTesting(false)
    }

    private var isBusy: Bool {
        viewModel.isPreparing || viewModel.phase == .loading
    }

    private var statusText: String {
        if viewModel.isRestarting { return "正在从新位置起流…" }
        if viewModel.isPreparing { return "正在获取播放信息…" }
        let detail = [
            viewModel.bufferingPercent.map { "\($0)%" },
            viewModel.cacheSpeedBytesPerSecond.map(PlayerStatistics.speedText),
        ].compactMap { $0 }
        return detail.isEmpty ? "正在缓冲…" : "正在缓冲… " + detail.joined(separator: " · ")
    }

    private var windowTitle: String {
        let item = viewModel.playingItem
        if item.kind == .episode, let series = item.seriesName {
            return [series, item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        }
        return item.name
    }

    // MARK: - 自动隐藏

    /// 显示控制层;`autoHide` 时在无交互 `delay` 秒后再隐藏(UI_DESIGN.md 5.1)。
    private func revealControls(autoHide: Bool = true, delay: TimeInterval = Metrics.autoHideDelay) {
        if !controlsVisible { controlsVisible = true }
        hideTask?.cancel()
        guard autoHide else { return }
        hideTask = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard canAutoHide else { return }
            controlsVisible = false
            // 指针跟着控制栏一起藏起来;一动鼠标就回来(系统行为)
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// 暂停、出错、加载 / 缓冲、播完,以及鼠标停在控制栏上时都不自动隐藏(5.1)。
    private var canAutoHide: Bool {
        viewModel.phase == .playing
            && !viewModel.isPaused
            && !viewModel.isBuffering
            && !viewModel.isEnded
            && viewModel.failure == nil
            && !isBusy
            && !isHoveringControls
            && !isSpeedPopoverPresented
            && viewModel.scrubPreviewSeconds == nil
    }

    private func showOSD() async {
        guard let osd = viewModel.osd else { return }
        shownOSD = osd
        do { try await Task.sleep(for: .seconds(Metrics.osdDuration)) } catch { return }
        if shownOSD?.id == osd.id { shownOSD = nil }
    }

    // MARK: - 动作

    private func close() {
        dismissWindow(id: PlayerSceneRoot.windowID)
    }

    private func toggleFullScreen() {
        window.toggleFullScreen()
    }

    private func installTrackpadScrubbing() {
        let viewModel = viewModel
        let window = window
        trackpad.install(
            window: { window.window },
            onScrub: { viewModel.previewScrub(by: $0) },
            onEnd: { viewModel.commitScrub() }
        )
    }

    /// 系统「正在播放」的封面:分集用剧照,电影用横版图 / 海报。
    /// 走 `PosterImageStore`(带认证头,与海报墙共用缓存);没有图或加载失败就不设封面。
    private func loadNowPlayingArtwork() async {
        let item = request.item
        let source = item.landscapeImage
            ?? item.primaryImageTagValue.map { (itemID: item.id, type: EmbyImageType.primary, tag: $0) }
        guard let source else { return }
        let spec = ImageSpec(
            serverID: request.server.id,
            itemID: source.itemID,
            type: source.type,
            tag: source.tag,
            maxWidth: Self.artworkMaxWidth
        )
        do {
            let image = try await container.posters.image(for: spec)
            nowPlaying.setArtwork(image)
            nowPlaying.update(from: viewModel)
        } catch {
            // 封面是锦上添花:取不到就用系统默认图标,不打断播放、不提示
            return
        }
    }

    private static let artworkMaxWidth = 600

    /// 401 才给重新登录入口;其它失败重试就够了(API_CONTRACT.md 2.5)。
    private func loginAction(for failure: LoadFailure) -> (() -> Void)? {
        guard failure.needsLogin else { return nil }
        return {
            container.state.serverNeedingLogin = request.server
            close()
        }
    }

    /// 视图离开(关窗 / 换集 / 切服务器)即拆播放器:MPVView 的
    /// dismantleNSView 也会触发,两条路径都指向可重入的 shutdown()。
    /// stop() 内部会补最后一次 Progress + Stopped(ARCHITECTURE.md 6.6),
    /// 发完后广播给详情页 / 首页重读进度(Q22)。
    private func tearDown() {
        hideTask?.cancel()
        trackpad.uninstall()
        nowPlaying.deactivate()
        window.setTitlebarButtonsVisible(true)
        viewModel.stop()
        let state = container.state
        let request = request
        // 用户直接关窗:清掉请求,下次 openWindow 不会把这一集又放一遍。
        // 换集时 nowPlaying 已是新请求,不能动它。
        if state.nowPlaying?.id == request.id {
            state.nowPlaying = nil
        }
        let viewModel = viewModel
        Task {
            await viewModel.waitUntilReportingFinished()
            state.lastFinishedPlayback = FinishedPlayback(
                requestID: request.id,
                serverID: request.server.id,
                itemID: request.item.id
            )
        }
    }
}

// MARK: - 标题栏 / 屏显提示 / 播完卡片

/// 顶部标题:剧名 + 「S1E2 · 集名」+ 播放方式与预计结束时间。
/// 居中放置,避开左上角的红绿灯。
struct PlayerTitleBar: View {
    let viewModel: PlayerViewModel

    var body: some View {
        VStack(spacing: Metrics.spacingXS) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
            }
            PlayerInfoLine(viewModel: viewModel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.spacingS)
        .padding(.horizontal, Metrics.spacingXL * 4)
        .padding(.bottom, Metrics.spacingXL * 2)
        .background(
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
        )
        .allowsHitTesting(false)
    }

    private var item: EmbyItem { viewModel.playingItem }

    private var title: String {
        item.kind == .episode ? (item.seriesName ?? item.name) : item.name
    }

    private var subtitle: String? {
        guard item.kind == .episode else { return nil }
        return [item.episodeLabel, item.seriesName == nil ? nil : item.name]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }
}

/// 「直接串流 · MKV · 1.25× · 21:35 结束」。单独成视图:它读播放位置,
/// 每 0.2s 重算一次,不该把整个标题栏带着一起重算。
private struct PlayerInfoLine: View {
    let viewModel: PlayerViewModel

    var body: some View {
        Text(parts.joined(separator: " · "))
    }

    private var parts: [String] {
        var parts: [String] = []
        if let session = viewModel.session {
            parts.append(session.plan.method.displayName)
            if let container = session.mediaSource.container, !container.isEmpty {
                parts.append(container.uppercased())
            }
        }
        if abs(viewModel.speed - 1) > 0.001 {
            parts.append(PlayerViewModel.speedText(viewModel.speed))
        }
        if let endsAt {
            parts.append("\(endsAt.formatted(date: .omitted, time: .shortened)) 结束")
        }
        return parts
    }

    /// 按剩余时长与倍速推算的结束时刻;时长未知或已播完时不显示。
    private var endsAt: Date? {
        let remaining = viewModel.durationSeconds - viewModel.positionSeconds
        guard viewModel.durationSeconds > 0, remaining > 0, viewModel.speed > 0, !viewModel.isEnded else {
            return nil
        }
        return Date().addingTimeInterval(remaining / viewModel.speed)
    }
}

/// 屏显提示:小型非交互玻璃胶囊(UI_DESIGN.md 4.1)。
struct PlayerOSDView: View {
    let osd: PlayerOSD

    var body: some View {
        Label(osd.text, systemImage: osd.systemImage)
            .font(.callout)
            .monospacedDigit()
            .padding(.horizontal, Metrics.spacingL)
            .padding(.vertical, Metrics.spacingS)
            .glassEffect(.regular, in: .capsule)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// 播完后的卡片:有下一集时主操作是「播放下一集」,否则是「重新播放」。
struct PlayerEndCard: View {
    let nextEpisode: EmbyItem?
    /// 自动播放下一集的倒计时;nil = 不自动播
    var countdown: Int?
    var playNext: () -> Void
    var cancelCountdown: () -> Void
    var replay: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            if let nextEpisode {
                Text("下一集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text([nextEpisode.episodeLabel, nextEpisode.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                    .lineLimit(2)
            } else {
                Text("已播放完毕")
                    .font(.headline)
            }
            GlassEffectContainer(spacing: Metrics.spacingM) {
                HStack(spacing: Metrics.spacingM) {
                    if nextEpisode != nil {
                        Button(countdown.map { "播放下一集(\($0))" } ?? "播放下一集",
                               systemImage: "play.fill", action: playNext)
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                            .monospacedDigit()
                    }
                    if countdown != nil {
                        Button("取消", action: cancelCountdown)
                            .buttonStyle(.glass)
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button("重新播放", systemImage: "arrow.counterclockwise", action: replay)
                            .buttonStyle(.glass)
                        Button("关闭", action: close)
                            .buttonStyle(.glass)
                    }
                }
            }
        }
        .padding(Metrics.spacingXL)
        .frame(maxWidth: Metrics.contentMaxWidth / 1.5, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.panel))
    }
}

/// 片尾的「下一集」提示(Netflix / Plex 的 Up Next):显示下一集名,
/// 开着自动播放时带倒计时。取消后本次播放不再出现。
struct PlayerUpNextPrompt: View {
    let nextEpisode: EmbyItem
    let countdown: Int?
    var playNext: () -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("下一集")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text([nextEpisode.episodeLabel, nextEpisode.name].compactMap { $0 }.joined(separator: " · "))
                .font(.headline)
                .lineLimit(1)
            GlassEffectContainer(spacing: Metrics.spacingS) {
                HStack(spacing: Metrics.spacingS) {
                    Button(countdown.map { "立即播放(\($0))" } ?? "立即播放",
                           systemImage: "play.fill", action: playNext)
                        .buttonStyle(.glassProminent)
                        .monospacedDigit()
                    Button("取消", action: dismiss)
                        .buttonStyle(.glass)
                }
            }
        }
        .padding(Metrics.spacingL)
        .frame(maxWidth: Metrics.contentMaxWidth / 2, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.panel))
    }
}

/// 触控板横滑时画面中央的目标时间:「12:34 / 45:00」+ 相对当前的偏移。
struct PlayerScrubPreview: View {
    let target: Double
    let current: Double
    let duration: Double

    var body: some View {
        VStack(spacing: Metrics.spacingXS) {
            Text("\(PlayerTime.text(target)) / \(PlayerTime.text(duration))")
                .font(.title2)
            Text(offsetText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .padding(.horizontal, Metrics.spacingXL)
        .padding(.vertical, Metrics.spacingM)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.panel))
        .allowsHitTesting(false)
    }

    private var offsetText: String {
        let delta = Int((target - current).rounded())
        return delta >= 0 ? "+\(delta) 秒" : "\(delta) 秒"
    }
}

/// 统计信息 overlay(I 键):等宽小字,不接收点击。
struct PlayerStatisticsView: View {
    let statistics: PlayerStatistics

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Metrics.spacingM, verticalSpacing: Metrics.spacingXS) {
            ForEach(statistics.lines) { line in
                GridRow {
                    Text(line.label)
                        .foregroundStyle(.secondary)
                    Text(line.value)
                }
            }
        }
        .font(.caption.monospaced())
        .padding(Metrics.spacingM)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: Radius.panel))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("播放统计信息")
    }
}

// MARK: - 窗口桥接

/// 播放窗口的 `NSWindow` 引用(弱引用,不延长窗口寿命)。
/// 全屏要切**播放窗口自己**:早期版本用 `NSApp.keyWindow`,
/// 播放器还是 sheet 时切到的是承载它的主窗口(docs/PITFALLS.md Q19)。
@MainActor
final class WindowBox {
    weak var window: NSWindow? {
        didSet { allowFullScreen() }
    }

    var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }

    func toggleFullScreen() {
        allowFullScreen()
        window?.toggleFullScreen(nil)
    }

    /// SwiftUI 给次级 `Window` 场景建的 NSWindow 带 `.fullScreenAuxiliary`
    /// 而没有 `.fullScreenPrimary`(本机实测:主窗口 Primary、播放窗口
    /// Auxiliary)。Auxiliary 窗口只能跟着别的窗口进全屏空间,自己调
    /// `toggleFullScreen` 什么也不发生 —— F、双击、控制栏按钮、绿灯全部失效。
    /// 切全屏前每次都重设一遍:SwiftUI 更新场景时可能把它改回去。
    private func allowFullScreen() {
        guard let window else { return }
        window.collectionBehavior.remove([.fullScreenAuxiliary, .fullScreenNone])
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    /// 置顶:浮动窗口层级。全屏时同样生效(无影响)。
    func setFloating(_ floating: Bool) {
        window?.level = floating ? .floating : .normal
    }

    /// 红绿灯随控制层一起隐藏,画面上不留常驻的窗口控件。
    func setTitlebarButtonsVisible(_ visible: Bool) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttons {
            window?.standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0
        }
    }
}

/// 取视图所在的 `NSWindow`。
struct WindowReader: NSViewRepresentable {
    var onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange?(window)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
