import SwiftUI
import AppKit

/// 播放器窗口的根视图(单实例独立窗口,内容由 `AppState.nowPlaying` 决定)。
///
/// 播放页按 `pageID` 认:新页时旧页随 `onDisappear` 收尾上报;页内换集只换会话(`switchSession`)。
/// 请求被清空(含切换 / 删除服务器)时关窗。
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
        // ⛔ 只在「有请求 → 无请求」跳变上关窗,不能挂在 Color.black 的 onAppear 上:
        // 下次 openWindow 时 SwiftUI 会补上积压的 onAppear,把刚打开的窗口关掉
        .onChange(of: container.state.nowPlaying?.id) { old, new in
            if old != nil, new == nil { dismissWindow(id: Self.windowID) }
        }
        // 视频亮度不可控,按深色外观取色才稳定可读
        .environment(\.colorScheme, .dark)
    }
}

/// 播放页(画面、控制栏、快捷键、自动隐藏)。视频层是 `MPVView`,其余是覆盖其上的 SwiftUI 控件。
///
/// 换集时本页保留,只把 `viewModel` 换成新一集的(ViewModel 与 mpv 仍每集一份,§8),见 `switchSession`。
struct PlayerWindowView: View {
    let container: AppContainer
    let request: PlaybackRequest

    @State private var viewModel: PlayerViewModel
    @State private var nowPlaying = NowPlayingController()
    @State private var window = WindowBox()
    @State private var trackpad = TrackpadScrubMonitor()

    /// 标题栏 + 控制栏 + 红绿灯
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isHoveringControls = false
    // 以下浮层 / 面板打开期间钉住控制栏,否则自动隐藏时会连它们一起带走
    @State private var isSpeedPopoverPresented = false
    @State private var isEpisodePanelPresented = false
    @State private var isMarkersEditorPresented = false
    @State private var isDanmakuPickerPresented = false
    @State private var isSubtitleImporterPresented = false
    @State private var isSubtitleSearchPresented = false
    /// 正在显示的屏显,`Metrics.osdDuration` 后清空(见 `showOSD`)
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
            // 按实例认视图:`MPVView` 一次性绑定 player(§8),换实例必须重建 layer。
            // ⛔ 不能拆成两个 `if`:上一集挪到「定格」时会被重建成空 layer,定格画面就没了。
            // 顺序即层级:当前播放器在下,定格的 `lingeringPlayer` 盖在上面。
            ForEach(videoLayers) { layer in
                MPVView(player: layer.player)
            }
            // ⛔ 弹幕不吃点击:单击 / 双击画面要落到 interactionLayer
            DanmakuOverlayView(
                controller: viewModel.danmaku,
                settings: container.danmakuSettings.settings,
                positionSeconds: viewModel.positionSeconds,
                isPaused: viewModel.isPaused || viewModel.isBuffering,
                speed: viewModel.speed)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
        // 同一播放页里换了集(`pageID` 不变、`id` 变了)
        .onChange(of: request.id) { switchSession() }
        .onContinuousHover { phase in
            // 移动 → 显示并重新计时;静止或移出 → 到点隐藏(移出延迟更短)。
            // ⛔ 不要只在移出时隐藏:指针停在窗口里不动就永远不收起
            switch phase {
            case .active:
                revealControls()
            case .ended:
                revealControls(delay: Metrics.autoHidePointerExitDelay)
            }
        }
        .onChange(of: viewModel.isPaused) { _, paused in
            // 暂停时常驻;恢复播放后多等一会儿再隐藏
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
            // 系统按 rate 自己外推进度,只需定期校准
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
            // 设置里改了字幕外观,当前这一集立即套用
            viewModel.applySubtitleStyle()
        }
        .onChange(of: viewModel.scrubPreviewSeconds) { _, preview in
            if preview != nil { revealControls() }
        }
        .onChange(of: isSpeedPopoverPresented) { _, presented in
            // 打开时钉住控制栏;关掉后重新计时
            if presented { revealControls(autoHide: false) } else { revealControls() }
        }
        .onChange(of: isEpisodePanelPresented) { _, presented in
            if presented { revealControls(autoHide: false) } else { revealControls() }
        }
        .onChange(of: isDanmakuPickerPresented) { _, presented in
            if presented { revealControls(autoHide: false) } else { revealControls() }
        }
        .onChange(of: isSubtitleImporterPresented) { _, presented in
            if presented { revealControls(autoHide: false) } else { revealControls() }
        }
        .onChange(of: isSubtitleSearchPresented) { _, presented in
            if presented { revealControls(autoHide: false) } else { revealControls() }
        }
        .onChange(of: viewModel.previousEpisode?.id) { nowPlaying.update(from: viewModel) }
        .onChange(of: viewModel.nextEpisode?.id) { nowPlaying.update(from: viewModel) }
        .task(id: viewModel.osd?.id) { await showOSD() }
        // 快捷键表见 PlayerCommands.swift。与菜单栏重复的键:菜单启用时先被菜单吃掉,
        // 这里保留是为菜单焦点值尚未就绪时仍可用。
        // 方向键只取 .down:转码模式下每次 seek 都重新起流,⛔ 不能按住连发。
        .onKeyPress(.space) { viewModel.togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow, phases: .down) { press in
            // file-loaded 前 / 播完后 mpv 必拒 seek(PITFALLS),放行
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
            // 不在片头区间时放行
            guard viewModel.isSkipIntroAvailable else { return .ignored }
            viewModel.skipIntro()
            return .handled
        }
        .onKeyPress("i") { viewModel.toggleStatistics(); return .handled }
        .onKeyPress("d") { viewModel.danmaku.setVisible(!viewModel.danmaku.isVisible); return .handled }
        // 按 characters 匹配,⇧ 时收到的是大写
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
            // 先收选集抽屉,再退出全屏
            if isEpisodePanelPresented {
                isEpisodePanelPresented = false
                return .handled
            }
            guard window.isFullScreen else { return .ignored }
            toggleFullScreen()
            return .handled
        }
        // ⛔ 弹窗(sheet / 文件面板)必须挂在上面这串 `onKeyPress` 的外层:弹窗里的按键会沿呈现它的视图
        // 往上传,挂在里层时这些处理器比输入框先拿到键(在搜索框里打字会变成静音、暂停……)。

        // 面板挂在窗口上:挂在字幕菜单里会随菜单收起一起消失
        .fileImporter(
            isPresented: $isSubtitleImporterPresented,
            allowedContentTypes: SubtitleFormats.contentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                viewModel.attachLocalSubtitle(at: url)
            case .failure(let error):
                // 用户取消不提示
                guard (error as NSError).code != NSUserCancelledError else { return }
                viewModel.reportSubtitlePickerFailure(error)
            }
        }
        .sheet(isPresented: $isDanmakuPickerPresented) {
            DanmakuPickerSheet(controller: viewModel.danmaku) { isDanmakuPickerPresented = false }
        }
        .sheet(isPresented: $isSubtitleSearchPresented) {
            SubtitlePickerSheet(viewModel: viewModel) { isSubtitleSearchPresented = false }
        }
        .sheet(isPresented: $isMarkersEditorPresented) {
            PlayerMarkersEditor(viewModel: viewModel) { isMarkersEditorPresented = false }
        }
    }

    /// 当前播放器 + 定格的上一个(`PlayerViewModel.lingeringPlayer`)
    private var videoLayers: [VideoLayer] {
        [viewModel.player, viewModel.lingeringPlayer].compactMap { $0 }.map(VideoLayer.init)
    }

    /// 秒
    private static let nowPlayingResyncSeconds = 5

    // MARK: - 交互层

    /// 单击暂停 / 继续,双击切全屏。顶部留一条拖窗口区域:隐藏标题栏后没它就拖不动。
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
                // 选集抽屉压在最上层,见 `PlayerEpisodePanel`
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

    /// 右下角情境按钮:片头里「跳过片头」,片尾「下一集」。控制栏隐藏时照样显示,位置随控制栏让开。
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
        // ⛔ 不加水平 padding / 最大宽度:压暗衬底要铺到窗口边缘,缩进在 `PlayerControlsView` 内部做
        PlayerControlsView(
            viewModel: viewModel,
            isSpeedPopoverPresented: $isSpeedPopoverPresented,
            isEpisodePanelPresented: $isEpisodePanelPresented,
            isMarkersEditorPresented: $isMarkersEditorPresented,
            isDanmakuPickerPresented: $isDanmakuPickerPresented,
            isSubtitleImporterPresented: $isSubtitleImporterPresented,
            isSubtitleSearchPresented: $isSubtitleSearchPresented
        )
        .onHover { hovering in
            isHoveringControls = hovering
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
        guard let item = viewModel.playingItem else { return viewModel.playingTitle }
        if item.kind == .episode, let series = item.seriesName {
            return [series, item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        }
        return item.name
    }

    // MARK: - 自动隐藏

    /// 显示控制层并重置计时;`autoHide` 时 `delay` 秒后隐藏,到点 `canAutoHide` 为假则不收。
    private func revealControls(autoHide: Bool = true, delay: TimeInterval = Metrics.autoHideDelay) {
        if !controlsVisible { controlsVisible = true }
        hideTask?.cancel()
        guard autoHide else { return }
        hideTask = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard canAutoHide else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

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
            && !isDanmakuPickerPresented
            && !isSubtitleImporterPresented
            && !isSubtitleSearchPresented
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

    /// 绑的是当前这一集的 ViewModel,换集后要重装。
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

    /// 系统「正在播放」的封面(`EmbyItem.coverImage`);取不到就不设。非 Emby 来源暂无封面通路,直接跳过。
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
            // 取图期间已换集:别把上一集的图盖到新一集上
            guard viewModel.playbackRequest.id == request.id else { return }
            nowPlaying.setArtwork(image)
            nowPlaying.update(from: viewModel)
        } catch {
            // 可选装饰:失败用系统默认图标,不提示
            return
        }
    }

    private static let artworkMaxWidth = 600

    /// 只有 401 给重新登录入口(API_CONTRACT.md 2.5)。
    private func loginAction(for failure: LoadFailure) -> (() -> Void)? {
        guard failure.needsLogin, let server = request.embyServer else { return nil }
        return {
            container.state.serverNeedingLogin = server
            close()
        }
    }

    /// 页内换集:旧一集走 `finish` 收尾,新一集起播,页面不动。
    /// ⛔ 新 ViewModel 必须建在旧的 stop 之后:两个 mpv 不同时存活,休眠断言也不叠两份。
    private func switchSession() {
        let previous = viewModel
        let carryOver = previous.pageCarryOver
        finish(previous)
        // 上一集最后一帧定格在新一集上(stop 之后才确定,见 `lastFramePlayer`)。
        // ⛔ 必须与 `viewModel = next` 同一拍,否则定格 layer 会被重建成空的
        let next = PlayerViewModel(
            container: container, request: request,
            carryOver: carryOver, lastFramePlayer: previous.lastFramePlayer)
        viewModel = next
        // 换了对象时 update 会撤掉旧的远程命令注册与封面
        nowPlaying.update(from: next)
        installTrackpadScrubbing()
        next.start()
        revealControls()
        Task { await loadNowPlayingArtwork() }
    }

    /// 拆播放器 + 收尾上报,发完后广播 `FinishedPlayback`(Q22)。关窗与换集共用。
    private func finish(_ viewModel: PlayerViewModel) {
        viewModel.stop()
        let state = container.state
        let request = viewModel.playbackRequest
        // 关窗时清掉请求,免得下次 openWindow 重放;换集时 nowPlaying 已是新请求,不能动
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

    /// 视图离开即拆播放器。MPVView 的 dismantleNSView 也会触发,两条路径都指向可重入的 shutdown()。
    private func tearDown() {
        hideTask?.cancel()
        trackpad.uninstall()
        nowPlaying.deactivate()
        window.setTitlebarButtonsVisible(true)
        finish(viewModel)
    }
}

/// 按播放器实例认身份(见 `videoLayers`)
private struct VideoLayer: Identifiable {
    let player: MPVPlayer
    var id: ObjectIdentifier { ObjectIdentifier(player) }
}

// MARK: - 标题栏 / 屏显提示 / 播完卡片

/// 顶部标题,一行居中(避开红绿灯):剧集是「剧名 + S1E2 · 集名」两级,电影只有标题。
///
/// ⛔ 只放标题:播放方式 / 容器等诊断信息在统计 overlay(I),倍速在控制栏,预计结束时刻在进度条。
struct PlayerTitleBar: View {
    let viewModel: PlayerViewModel

    var body: some View {
        // ⛔ 不要改成 `VStack` 两行:白白多占一行高度
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

struct PlayerEndCard: View {
    let nextEpisode: PlaybackEpisode?
    /// nil = 不自动播
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

/// 片尾的「下一集」提示,开着自动播放时带倒计时。取消后本次播放不再出现。
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

/// 触控板横滑时画面中央的目标时间与偏移。
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

/// 播放窗口的弱引用。全屏要切播放窗口自己,⛔ 不用 `NSApp.keyWindow`(docs/PITFALLS.md Q19)。
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

    /// SwiftUI 给次级 `Window` 场景的 NSWindow 是 `.fullScreenAuxiliary`,自己调 `toggleFullScreen`
    /// 无效。每次切全屏前都重设:SwiftUI 更新场景时可能改回去。
    private func allowFullScreen() {
        guard let window else { return }
        window.collectionBehavior.remove([.fullScreenAuxiliary, .fullScreenNone])
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    func setFloating(_ floating: Bool) {
        window?.level = floating ? .floating : .normal
    }

    /// 红绿灯随控制层一起隐藏。
    func setTitlebarButtonsVisible(_ visible: Bool) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttons {
            window?.standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0
        }
    }
}

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
