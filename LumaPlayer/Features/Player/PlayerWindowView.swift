import SwiftUI
import AppKit

/// 播放器窗口的根视图(独立窗口,CLAUDE.md「架构主线」)。
///
/// 窗口是单实例的:内容由 `AppState.nowPlaying` 决定。播放页按 `pageID` 认:
/// 从别处起播是新页(旧页随 `onDisappear` 走完收尾上报);播放页里换集沿用
/// 同一个 `pageID`,页面不重建,只在页内换会话(`PlayerWindowView.switchSession`)。
/// 没有请求时关窗 —— 切换 / 删除服务器会清空请求(DesignTokens.swift「界面规则」)。
struct PlayerSceneRoot: View {
    static let windowID = "player"

    let container: AppContainer
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let request = container.state.nowPlaying {
                PlayerWindowView(container: container, request: request)
                    .id(request.pageID)
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
        // 深色环境:视频背景亮度不可控,玻璃与文字按深色外观取色才稳定可读(DesignTokens.swift「界面规则」)
        .environment(\.colorScheme, .dark)
    }
}

/// 播放页(画面、控制栏、快捷键、自动隐藏)。
///
/// 视频层走 `MPVView`(libmpv 的 OpenGL 渲染路径,不经过 SwiftUI 管线),
/// 其余是覆盖在上面的 SwiftUI 控件层。
///
/// 换集时本页保留(全屏、控制层、选集抽屉、屏显都不动),`viewModel` 换成新一集的
/// —— ViewModel 与 mpv 仍是每集一份(§8 一实例一 URL),见 `switchSession`。
struct PlayerWindowView: View {
    let container: AppContainer
    let request: PlaybackRequest

    @State private var viewModel: PlayerViewModel
    @State private var nowPlaying = NowPlayingController()
    @State private var window = WindowBox()
    @State private var trackpad = TrackpadScrubMonitor()
    /// 换集时上一集的播放器(已 shutdown):它的视频层留在屏上、盖在新一集上面,
    /// 画面定格在最后一帧(`MPVGLLayer.canDraw`),新一集出第一帧后撤掉 ——
    /// 换集不再黑一下。nil = 没有要留的。
    @State private var lingeringPlayer: MPVPlayer?

    /// 控制层(标题栏 + 控制栏 + 红绿灯)是否可见
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    /// 鼠标停在控制栏上时不自动隐藏
    @State private var isHoveringControls = false
    /// 倍速浮层打开中:控制栏要一直留着,否则它会在自动隐藏时连浮层一起带走
    @State private var isSpeedPopoverPresented = false
    /// 选集抽屉打开中:同理,控制栏不能自动隐藏(抽屉靠控制栏上的按钮收起)
    @State private var isEpisodePanelPresented = false
    /// 手动片头片尾输入面板打开中:同理,面板开着期间钉住控制栏
    @State private var isMarkersEditorPresented = false
    /// 正在显示的屏显提示(比 `viewModel.osd` 晚一拍清空)
    @State private var shownOSD: PlayerOSD?
    @FocusState private var isFocused: Bool
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(container: AppContainer, request: PlaybackRequest) {
        self.container = container
        self.request = request
        self._viewModel = State(
            initialValue: PlayerViewModel(container: container, request: request)
        )
    }

    var body: some View {
        ZStack {
            Color.black
            // 按实例认视图:`MPVView` 一次性绑定 player(§8),换了实例必须重建 layer,
            // 否则新 mpv 永远等不到 GL 上下文。⛔ 不能拆成两个 `if`:上一集从「当前」
            // 挪到「定格」时会被当成另一个视图重建,新 layer 是空的 —— 定格画面就没了。
            // 顺序即层级:当前一集在下,定格的上一集盖在上面。
            ForEach(videoLayers) { layer in
                MPVView(player: layer.player)
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
        // 同一播放页里换了集(`pageID` 没变、`id` 变了):页内换会话
        .onChange(of: request.id) { switchSession() }
        .onChange(of: viewModel.isAwaitingFirstVideoFrame) { _, awaiting in
            // 新一集出画面了(或出错 / 纯音频,再等也没有画面):撤掉定格的上一集
            if !awaiting { lingeringPlayer = nil }
        }
        .onContinuousHover { phase in
            // 指针在窗口内移动:显示并**重新计时**,静止 `autoHideDelay`
            // 秒后自动隐藏。指针移出窗口:同样走计时(延迟更短,见 Metrics)。
            //
            // ⛔ 不要写成「只在移出窗口时隐藏」——那样指针停在窗口里不动
            // 就永远不会收起,控制栏会一直压在画面上(2026-10-02 用户实测反馈)。
            // Apple TV 是「移出 viewer 即隐藏」,mpv OSC 是「静止 0.5 秒」,
            // 两条并不冲突:移动 → 显示并重置计时,静止或移出 → 到点隐藏。
            switch phase {
            case .active:
                revealControls()
            case .ended:
                revealControls(delay: Metrics.autoHidePointerExitDelay)
            }
        }
        .onChange(of: viewModel.isPaused) { _, paused in
            // 暂停时常驻;恢复播放后多等一会儿再隐藏(DesignTokens.swift autoHideResumeDelay)
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
        .onChange(of: container.subtitleStyles.style) {
            // 设置窗口里改了字幕外观:正在播的这一集立即套用(新建的 mpv 由 ViewModel 自己设)
            viewModel.applySubtitleStyle()
        }
        .onChange(of: viewModel.scrubPreviewSeconds) { _, preview in
            // 横滑拖进度时把控制栏叫出来,进度条跟着预览位置走
            if preview != nil { revealControls() }
        }
        .onChange(of: isSpeedPopoverPresented) { _, presented in
            // 打开时钉住控制栏;关掉后按正常节奏重新计时隐藏
            if presented { revealControls(autoHide: false) } else { revealControls() }
        }
        .onChange(of: isEpisodePanelPresented) { _, presented in
            // 选集抽屉同理:开着的时候控制栏不能自己收走
            if presented { revealControls(autoHide: false) } else { revealControls() }
        }
        .sheet(isPresented: $isMarkersEditorPresented) {
            // 手动片头片尾:表单在窗口上呈现(sheet 比 popover 稳,菜单点开就收起来了)
            PlayerMarkersEditor(viewModel: viewModel) { isMarkersEditorPresented = false }
        }
        .onChange(of: viewModel.previousEpisode?.id) { nowPlaying.update(from: viewModel) }
        .onChange(of: viewModel.nextEpisode?.id) { nowPlaying.update(from: viewModel) }
        .task(id: viewModel.osd?.id) { await showOSD() }
        // 快捷键按 PlayerCommands.swift 的快捷键表。Space / M / [ ] / ⌘→ 同时挂在菜单栏「Playback」菜单
        // (PlayerCommands):菜单启用时按键先被菜单吃掉,下面的同名处理不会重复触发;
        // 这里保留它们,是为菜单未就绪(焦点值尚未传到菜单)时按键仍然可用。
        // 方向键只取 .down:按住不放时 .repeat 会连续触发 seek,而转码模式下
        // 一次 seek 就是一次重新起流。
        .onKeyPress(.space) { viewModel.togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow, phases: .down) { press in
            // 内核还没 file-loaded / 已经播完时 mpv 对 seek 必拒(PITFALLS):
            // 放行,不闪一句注定失败的提示。
            guard viewModel.isReadyToSeek else { return .ignored }
            viewModel.skip(by: press.modifiers.contains(.shift)
                ? -Metrics.seekStepLarge : -viewModel.seekStep)
            return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            guard viewModel.isReadyToSeek else { return .ignored }
            viewModel.skip(by: press.modifiers.contains(.shift)
                ? Metrics.seekStepLarge : viewModel.seekStep)
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
        // 字幕延迟:Z 提前 / X 延后,⇧ 为大步长。按 characters 匹配,⇧ 时收到的是大写
        .onKeyPress(characters: CharacterSet(charactersIn: "zxZX"), phases: [.down, .repeat]) { press in
            guard viewModel.canAdjustSubtitleDelay else { return .ignored }
            let key = press.characters
            viewModel.stepSubtitleDelay(
                later: key.lowercased() == "x",
                step: key == key.uppercased() ? Metrics.subtitleDelayLargeStep : Metrics.subtitleDelayStep)
            return .handled
        }
        .onKeyPress("f") { toggleFullScreen(); return .handled }
        .onKeyPress(.escape) {
            // 选集抽屉开着时,先收抽屉 —— 退出全屏是更「重」的动作,不该抢在前面
            if isEpisodePanelPresented {
                isEpisodePanelPresented = false
                return .handled
            }
            guard window.isFullScreen else { return .ignored }
            toggleFullScreen()
            return .handled
        }
    }

    /// 屏上的视频层(当前一集 + 换集时定格的上一集),见 `lingeringPlayer`
    private var videoLayers: [VideoLayer] {
        [viewModel.player, lingeringPlayer].compactMap { $0 }.map(VideoLayer.init)
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
                // 选集抽屉压在最上层:从右侧滑出,和画面并存(不铺满)。
                // 左侧留白不参与命中测试,点画面照样落到 `interactionLayer`。
                if isEpisodePanelPresented {
                    PlayerEpisodePanel(
                        episodes: viewModel.episodes,
                        currentID: viewModel.currentEpisodeID,
                        store: container.posters,
                        onSelect: { episode in
                            isEpisodePanelPresented = false
                            viewModel.playEpisode(episode)
                        },
                        onClose: { isEpisodePanelPresented = false }
                    )
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(controlsAnimation, value: controlsVisible)
            .animation(controlsAnimation, value: isEpisodePanelPresented)
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
        // 全宽触底:不再加水平 padding 与最大宽度,压暗衬底要一直铺到窗口边缘。
        // 内容的左右缩进在 `PlayerControlsView` 内部做(controlBarSideInset)。
        // 换集入口(上一集 / 下一集 / 选集)由控制栏自己按 `viewModel` 的队列决定,
        // 这里不再单独算一个 `playNext` 传进去。
        PlayerControlsView(
            viewModel: viewModel,
            toggleFullScreen: { toggleFullScreen() },
            isSpeedPopoverPresented: $isSpeedPopoverPresented,
            isEpisodePanelPresented: $isEpisodePanelPresented,
            isMarkersEditorPresented: $isMarkersEditorPresented
        )
        .onHover { hovering in
            isHoveringControls = hovering
            // 指针扫进控制栏就取消隐藏;扫出去再按正常节奏重新计时
            if hovering { revealControls(autoHide: false) } else { revealControls() }
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
        // 百度来源没有 Emby 的剧集结构,标题就是文件名(`playingTitle`)
        guard let item = viewModel.playingItem else { return viewModel.playingTitle }
        if item.kind == .episode, let series = item.seriesName {
            return [series, item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        }
        return item.name
    }

    // MARK: - 自动隐藏

    /// 显示控制层;`autoHide` 时在 `delay` 秒后隐藏(DesignTokens.swift「界面规则」)。
    ///
    /// 每次调用都会**重置**计时(`hideTask?.cancel()` 后重新排),所以
    /// 「指针移动 → 显示 → 静止 → 隐藏」是一个自然的循环。
    /// `canAutoHide` 为假时(暂停、缓冲、播完、指针停在控制栏上…)到点也不会收。
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
            && !isEpisodePanelPresented
            && !isMarkersEditorPresented
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

    /// 触控板横滑绑的是**当前这一集**的 ViewModel:换集后要重装(`switchSession`)。
    private func installTrackpadScrubbing() {
        trackpad.uninstall()
        let viewModel = viewModel
        let window = window
        trackpad.install(
            window: { window.window },
            onScrub: { viewModel.previewScrub(by: $0) },
            onEnd: { viewModel.commitScrub() }
        )
    }

    /// 系统「正在播放」的封面:分集用剧照,电影用横版图 / 海报(`EmbyItem.coverImage`)。
    /// 走 `PosterImageStore`(带认证头,与海报墙共用缓存);没有图或加载失败就不设封面。
    /// ⚠️ 百度来源当前没有封面通路,直接跳过(见 `docs/SOURCE_ABSTRACTION_PLAN.md` P5)。
    private func loadNowPlayingArtwork() async {
        let request = request
        guard let item = request.embyItem, let server = request.embyServer,
              let source = item.coverImage else { return }
        let spec = ImageSpec(
            serverID: server.id,
            itemID: source.itemID,
            type: source.type,
            tag: source.tag,
            maxWidth: Self.artworkMaxWidth
        )
        do {
            let image = try await container.posters.image(for: spec)
            // 取图期间已换到别的集:这张是上一集的,不能盖到新一集上
            guard viewModel.playbackRequest.id == request.id else { return }
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
        guard failure.needsLogin, let server = request.embyServer else { return nil }
        return {
            container.state.serverNeedingLogin = server
            close()
        }
    }

    /// 同一播放页里换集:旧一集收尾,新一集起播,页面本身(全屏、控制层、抽屉)不动。
    ///
    /// 旧 ViewModel 走与关窗同一条收尾(`finish`):最终 Progress + Stopped 发完再广播,
    /// 详情页 / 首页据此重读进度(Q22)。新 ViewModel 建在**旧的 stop 之后**:
    /// 两个 mpv 不同时存活,显示器休眠断言也不会叠两份。
    private func switchSession() {
        let previous = viewModel
        let carryOver = previous.pageCarryOver
        // 上一集出过画面就定格它;没出过(还在起播就又换了)就留着更早那一集的定格
        if let player = previous.player, previous.hasRenderedFirstVideoFrame {
            lingeringPlayer = player
        }
        finish(previous)
        let next = PlayerViewModel(container: container, request: request, carryOver: carryOver)
        viewModel = next
        // 远程命令绑在 ViewModel 上:update 发现换了对象会撤掉旧注册再按新的注册
        // (同时清掉上一集的封面)
        nowPlaying.update(from: next)
        installTrackpadScrubbing()
        next.start()
        revealControls()
        Task { await loadNowPlayingArtwork() }
    }

    /// 结束一集的会话:拆播放器 + 收尾上报,发完后广播给详情页 / 首页重读进度(Q22)。
    /// 关窗(`tearDown`)与页内换集(`switchSession`)共用。
    private func finish(_ viewModel: PlayerViewModel) {
        viewModel.stop()
        let state = container.state
        let request = viewModel.playbackRequest
        // 用户直接关窗:清掉请求,下次 openWindow 不会把这一集又放一遍。
        // 换集时 nowPlaying 已是新请求,不能动它。
        if state.nowPlaying?.id == request.id {
            state.nowPlaying = nil
        }
        Task {
            await viewModel.waitUntilReportingFinished()
            state.lastFinishedPlayback = FinishedPlayback(
                requestID: request.id,
                serverID: request.embyServer?.id,
                itemID: request.source.contentID
            )
        }
    }

    /// 视图离开(关窗 / 从别处起播换了页 / 切服务器)即拆播放器:MPVView 的
    /// dismantleNSView 也会触发,两条路径都指向可重入的 shutdown()。
    /// stop() 内部会补最后一次 Progress + Stopped(API_CONTRACT.md 5.4)。
    private func tearDown() {
        hideTask?.cancel()
        trackpad.uninstall()
        nowPlaying.deactivate()
        window.setTitlebarButtonsVisible(true)
        finish(viewModel)
    }
}

/// `PlayerWindowView` 视频层的身份:按播放器实例认(见 `videoLayers`)
private struct VideoLayer: Identifiable {
    let player: MPVPlayer
    var id: ObjectIdentifier { ObjectIdentifier(player) }
}

// MARK: - 标题栏 / 屏显提示 / 播完卡片

/// 顶部标题:**一行**,剧集是「剧名 + S1E2 · 集名」两级,电影只有标题。
/// 居中放置,避开左上角的红绿灯。
///
/// **只有标题,没有别的。** 原先这里还有第三行「直接串流 · MKV · 1.25× ·
/// 21:35 结束」,2026-10-02 删掉了,理由不是「和统计 overlay 重复」那么简单:
///
/// - 播放方式 / 容器格式是**诊断信息**。统计 overlay(按 I)是用户主动索取,
///   顶栏是环境信息、视线扫过。把诊断字段放在视觉最顶层,等于让所有人在
///   所有时间都看只有少数人需要的东西 —— mpv 同样把 cache 指示器放在
///   OSC 标题行,但那一整行**随鼠标移动出现、静止即消失**,本质是调试面板。
/// - 倍速已有更好的落点:控制栏的常驻按钮 + 改速瞬间的 OSD 提示。
/// - 预计结束时刻移到了进度条的切换态(见 `PlayerScrubber`)。
///
/// 依据(2026-10-02 查证):QuickTime / Infuse 把标题放窗口标题栏,技术信息放独立面板;
/// IINA / Plex 同样把媒体信息放独立面板(`Cmd+I` / Get Info)。
struct PlayerTitleBar: View {
    let viewModel: PlayerViewModel

    var body: some View {
        // 剧集是两级排版(剧名 / 集号集名),电影只有一级 —— 用 `HStack` 的
        // baseline 对齐,⛔ 不要改成 `VStack` 上下两行:那是把 SwiftUI 的
        // 单行两级排版当两行用,白白多占一行动画高度。
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingS) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.spacingS)
        .padding(.horizontal, Metrics.spacingXL * 4)
        .padding(.bottom, Metrics.spacingXL)
        .background(
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
        )
        .allowsHitTesting(false)
    }

    private var item: EmbyItem? { viewModel.playingItem }

    private var title: String {
        guard let item else { return viewModel.playingTitle }
        return item.kind == .episode ? (item.seriesName ?? item.name) : item.name
    }

    private var subtitle: String? {
        guard let item, item.kind == .episode else { return nil }
        return [item.episodeLabel, item.seriesName == nil ? nil : item.name]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }
}

/// 屏显提示:小型非交互玻璃胶囊(DesignTokens.swift「界面规则」)。
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
    let nextEpisode: PlaybackEpisode?
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
                Text([nextEpisode.label, nextEpisode.title].compactMap { $0 }.joined(separator: " · "))
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
    let nextEpisode: PlaybackEpisode
    let countdown: Int?
    var playNext: () -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("下一集")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text([nextEpisode.label, nextEpisode.title].compactMap { $0 }.joined(separator: " · "))
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
