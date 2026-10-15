import SwiftUI

/// 播放器底部控制栏(DesignTokens.swift「界面规则」)。
///
/// 从左到右:播放 / 暂停(**上下集紧贴它左右**,外侧是 ±`seekStep` 跳转)→ 音量
/// → 倍速 / 字幕 / 音轨 / 选项 → **选集(最右)**。⛔ 控制栏里不再有全屏图标 —— F 与双击画面
/// 两条通路已经够用,把最右这个「离手最近」的位置让给播剧时要反复点的选集(2026-10-14 改)。
///
/// **形态:全宽底部横条 + 渐变压暗,不是悬浮玻璃药丸。**
///
/// 玻璃药丸是 2026-09 之前的做法,现在弃用,理由三条:
/// - Apple TV / QuickTime / mpv OSC 默认布局(`bottombar`)/ Jellyfin 全是全宽,
///   药丸在 mpv 里是 `floating` / `box` 这种备选;
/// - HIG Materials:玻璃浮在 media background 上要配 dimming layer(Apple 给 35%),
///   裸玻璃压在视频上不合规,社区也批评悬浮玻璃条遮挡画面底部、易误触;
/// - 渐变压暗在明暗剧烈变化的视频上比玻璃的自适应行为可预测,
///   也不依赖 Reduce Transparency 是否被正确响应。
///
/// 进度条对两种播放方式**行为不同**:
/// DirectStream 拖动 = mpv seek;转码拖动 = 停流 + `StartTimeTicks` 重新起流
/// (API_CONTRACT.md 4.5)。差异在 `PlayerViewModel.seek` 里分派,
/// 本视图只负责把目标秒数交出去。
///
/// 直接持有 ViewModel 而不是逐个传值:`@Observable` 按属性追踪读取,
/// 每 0.2s 一次的 `time-pos` 只让读了位置的 `PlayerScrubber` 重算,
/// 按钮行不跟着重绘(DesignTokens.swift「界面规则」)。
struct PlayerControlsView: View {
    let viewModel: PlayerViewModel
    /// 倍速浮层是否打开:打开期间控制栏不能自动隐藏,否则浮层连着控制栏一起消失
    @Binding var isSpeedPopoverPresented: Bool
    /// 选集抽屉是否打开:同上,打开期间要钉住控制栏(收起靠抽屉左缘的把手)
    @Binding var isEpisodePanelPresented: Bool
    /// 手动片头片尾输入面板是否打开:同上,面板开着期间也要钉住控制栏
    @Binding var isMarkersEditorPresented: Bool
    /// 手动选择弹幕的面板是否打开:同上
    @Binding var isDanmakuPickerPresented: Bool

    var body: some View {
        VStack(spacing: Metrics.spacingS) {
            PlayerScrubber(viewModel: viewModel)
            HStack(spacing: Metrics.spacingM) {
                transport
                PlayerVolumeControl(viewModel: viewModel)
                Spacer(minLength: Metrics.spacingL)
                PlayerSpeedControl(viewModel: viewModel, isPresented: $isSpeedPopoverPresented)
                PlayerSubtitleMenu(viewModel: viewModel)
                PlayerDanmakuMenu(viewModel: viewModel, isPickerPresented: $isDanmakuPickerPresented)
                PlayerAudioMenu(viewModel: viewModel)
                PlayerOptionsMenu(
                    viewModel: viewModel,
                    isMarkersEditorPresented: $isMarkersEditorPresented
                )
                episodePanelButton
            }
            .padding(.horizontal, Metrics.controlBarSideInset)
        }
        .padding(.top, Metrics.controlBarTopInset)
        .padding(.bottom, Metrics.controlBarBottomInset)
        // 全宽触底:压暗衬底一直铺到窗口底边,不能留出窗口背景色的窄条
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) { scrim }
    }

    /// 自下而上的黑色渐变,底端到 `controlBarScrimOpacity` 后完全透明。
    /// 不用玻璃 —— 理由见类型注释。
    private var scrim: some View {
        LinearGradient(
            colors: [
                .clear,
                .black.opacity(Metrics.controlBarScrimOpacity),
            ],
            startPoint: UnitPoint(x: 0.5, y: Metrics.controlBarScrimStart),
            endPoint: UnitPoint(x: 0.5, y: 1)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 播放 / 暂停,左右**紧贴**上一集 / 下一集(2026-10-14 指定):播剧时换集比
    /// ±`seekStep` 的跳转频繁得多,贴着播放键那一簇才找得到。±跳转留在这一簇的最外侧,
    /// 播放键仍在视觉中心。
    ///
    /// ⚠️ 已知取舍:播放键不再固定最左 —— 电影 / 单条视频没有上下集时整簇收窄,
    /// 播放键会向左移一个按钮位。这是「换集贴着播放键」的必然代价,⛔ 不要再「修」回去。
    ///
    /// 上下集各自按可用性出现(没有就不占位);队列由 `PlayerViewModel` 按来源装好
    /// (百度复用目录已列条目,Emby 查当前季)。
    private var transport: some View {
        HStack(spacing: Metrics.spacingXS) {
            PlayerRepeatSkipButton(direction: .backward, viewModel: viewModel)
            if viewModel.previousEpisode != nil {
                PlayerIconButton(systemImage: "backward.end.fill", label: "上一集") {
                    viewModel.playPreviousEpisode()
                }
            }
            PlayerIconButton(
                systemImage: viewModel.isPaused ? "play.fill" : "pause.fill",
                label: viewModel.isPaused ? "播放" : "暂停",
                prominent: true
            ) { viewModel.togglePlayPause() }
            if viewModel.nextEpisode != nil {
                PlayerIconButton(systemImage: "forward.end.fill", label: "下一集") {
                    viewModel.playNextEpisode()
                }
            }
            PlayerRepeatSkipButton(direction: .forward, viewModel: viewModel)
        }
    }

    /// 选集:切换右侧滑出的分集抽屉(`PlayerEpisodePanel`),点任意一集直接切。
    ///
    /// 放在控制栏**最右端**,也就是原先全屏图标的位置:全屏已有 F 与双击画面两条通路。
    /// ⚠️ 抽屉一打开就盖住控制栏右半段(含这个按钮),那条开关通路就断了 ——
    /// 收起由抽屉左缘的把手承担(见 `PlayerEpisodePanel.collapseHandle`)。
    ///
    /// 用抽屉而不是 `Menu` / `popover`(第一版是 popover):几百集时菜单铺不开,
    /// 而抽屉里能放带剧照的可滚动列表,并把当前集滚到可见(理由见 `PlayerEpisodePanel`)。
    @ViewBuilder
    private var episodePanelButton: some View {
        if viewModel.episodes.count > 1 {
            PlayerIconButton(systemImage: "list.number", label: "选集") {
                isEpisodePanelPresented.toggle()
            }
        }
    }
}

// MARK: - 进度条

/// 进度条:悬停显示该点的时间,拖动中显示目标时间,松手才 seek。
///
/// 时间**两端都显示**:左边已播放、右边剩余(Apple TV 的做法是
/// "the timeline shows elapsed and remaining time",Plex 同)。
/// 取消的是「总时长 / 剩余」那一档 —— 剩余时长已是默认显示态,再给一个
/// 切回总时长的按钮等于让用户逐次点回去。右侧保留的那个切换是
/// 「剩余时长 ↔ 预计结束时刻」,答的是「看完得到几点」。
///
/// 自绘而不是用 `Slider`:系统滑块没有悬停预览,且拖动中会被
/// 每 0.2s 的 time-pos 拉回(所以才有 `dragging` 这个临时值)。
/// 键盘与 VoiceOver 走 `accessibilityAdjustableAction`,与方向键同步长。
struct PlayerScrubber: View {
    let viewModel: PlayerViewModel

    /// 拖动中的目标秒数;nil 表示跟随播放位置
    @State private var dragging: Double?
    /// 悬停位置(进度条坐标系);nil = 没悬停
    @State private var hoverX: CGFloat?
    /// 右侧显示剩余时长还是预计结束时刻。跨次启动记住 —— Apple TV 的进度条
    /// 就是这个「再点一次切换」的交互,不是单向的。
    @AppStorage("player.scrubberShowsEndTime") private var showsEndTime = false

    private var duration: Double { viewModel.durationSeconds }
    /// 优先级:鼠标拖动 > 触控板横滑预览 > 实际播放位置
    private var displayed: Double { dragging ?? viewModel.scrubPreviewSeconds ?? viewModel.positionSeconds }
    private var isActive: Bool { dragging != nil || hoverX != nil }
    private var trackHeight: CGFloat {
        isActive ? Metrics.scrubberTrackHeightActive : Metrics.scrubberTrackHeight
    }
    private var knobSize: CGFloat {
        isActive ? Metrics.scrubberKnobSizeActive : Metrics.scrubberKnobSize
    }

    var body: some View {
        HStack(spacing: Metrics.spacingM) {
            Text(PlayerTime.text(displayed))
                .font(.caption)
                .monospacedDigit()
            track
            trailingTime
        }
        .padding(.horizontal, Metrics.controlBarSideInset)
    }

    /// 右侧时间:默认「剩余时长」,点一下换成「预计结束时刻」。
    ///
    /// 为什么单独给它一个交互:1.25× 倍速下「还剩 22 分钟」远不如「21:35 结束」
    /// 好用 —— 后者直接回答「看完得到几点」。Apple TV 的进度条就是这个第二态。
    /// ⛔ 不做成常驻顶栏的一行:那是所有人在所有时间都要看的信息。
    private var trailingTime: some View {
        Button {
            showsEndTime.toggle()
        } label: {
            Text(trailingText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(duration <= 0)
        .help(showsEndTime ? "显示剩余时间" : "显示预计结束时刻")
        .accessibilityLabel(showsEndTime ? "预计结束时刻,点击显示剩余时间" : "剩余时间,点击显示预计结束时刻")
    }

    /// 时长未知时给 `--:--` 不加负号(⛔ 不填 `0:00` 假装已知,同 `PlayerTime.text`)。
    /// `endsAt` 为 nil(已播完 / 倍速非法)时自动退回剩余时长,不能给个空白。
    ///
    /// ⛔ 别写成 `"-" + PlayerTime.text(...)`:`text(0)` 返回 `--:--`,
    /// 拼上负号就是 `---:--`。用 `PlayerTime.remainingText` 分开这两种情况。
    private var trailingText: String {
        if showsEndTime, let endsAt {
            return "\(endsAt.formatted(date: .omitted, time: .shortened)) 结束"
        }
        return PlayerTime.remainingText(
            duration - displayed,
            durationKnown: duration > 0
        )
    }

    /// 按剩余时长与倍速推算的结束时刻。时长未知、已播完、倍速非正时为 nil
    /// —— 宁可不显示,也不显示一个编出来的时刻。
    private var endsAt: Date? {
        PlayerTime.endsAt(
            position: displayed,
            duration: duration,
            speed: viewModel.speed,
            isEnded: viewModel.isEnded
        )
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = duration > 0 ? min(1, max(0, displayed / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(Metrics.scrubberTrackOpacity))
                // 已缓存到的位置(mpv demuxer-cache-time):比底色亮一档,比已播放暗。
                // 画在已播放段**下面**,已播放段盖在上面 —— 两段重叠时只有已播放的亮,
                // 不需要额外算交集。
                if let buffered = bufferedFraction {
                    Capsule()
                        .fill(.white.opacity(Metrics.scrubberBufferedOpacity))
                        .frame(width: width * buffered)
                }
                Capsule()
                    .fill(.white.opacity(Metrics.scrubberPlayedOpacity))
                    .frame(width: width * fraction)
                // 片头 / 片尾标记:画在已播放段**之上** —— 播过片头之后还要看得见,
                // 不然「设在哪了」只有回到片头才发现。用强调色,与白色的已播放 / 已缓存段区分。
                // 颜色不是唯一表达:菜单里有文字摘要(无障碍规则)。
                markerOverlay(width: width)
            }
            .frame(height: trackHeight)
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: Metrics.animationFast), value: isActive)
            .overlay(alignment: .leading) {
                // 播放头圆点:mpv OSC `seekbarstyle=knob` 的做法(官方推荐
                // `seekbarhandlesize=0.6`)。Apple 在 Liquid Glass 里也把播放头
                // 「从小变得更大更显眼」,亮画面上小圆点根本看不见。
                // 中心对齐轨道,拖动时跟着手指走。
                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: min(max(width * fraction - knobSize / 2, 0), max(0, width - knobSize)))
                    .animation(.easeOut(duration: Metrics.animationFast), value: fraction)
                    // value 要同时带 isActive:圆点大小由 knobSize 决定,
                    // 只跟 fraction 的话悬停切换尺寸会硬跳(轨道高度是有动画的)。
                    .animation(.easeOut(duration: Metrics.animationFast), value: isActive)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if let x = dragging.map({ width * $0 / max(duration, 1) }) ?? hoverX, duration > 0 {
                    Text(PlayerTime.text(seconds(at: x, width: width)))
                        .font(.caption)
                        .monospacedDigit()
                        .padding(.horizontal, Metrics.spacingS)
                        .padding(.vertical, Metrics.spacingXS)
                        .background(.black.opacity(0.7), in: Capsule())
                        .fixedSize()
                        .position(
                            x: min(max(x, Metrics.spacingXL), max(width - Metrics.spacingXL, Metrics.spacingXL)),
                            y: -Metrics.scrubberTooltipOffset
                        )
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = seconds(at: value.location.x, width: width)
                    }
                    .onEnded { value in
                        let target = seconds(at: value.location.x, width: width)
                        dragging = nil
                        viewModel.seek(to: target)
                    }
            )
        }
        .frame(height: Metrics.spacingL)
        // 拖不动的源不给拖动交互(判据见 `PlaybackSeekStrategy`):让进度条
        // 看起来能拖、拖了才弹一句「不支持」,不如一开始就别给这个手势。
        .disabled(duration <= 0 || !viewModel.allowsSeeking)
        .help(viewModel.seekUnavailableReason ?? "拖动调整进度")
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(PlayerTime.spokenText(displayed)),剩余 \(PlayerTime.spokenText(max(0, duration - displayed)))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: viewModel.skip(by: viewModel.seekStep)
            case .decrement: viewModel.skip(by: -viewModel.seekStep)
            @unknown default: break
            }
        }
    }

    private var bufferedFraction: Double? {
        guard duration > 0, let buffered = viewModel.bufferedUntilSeconds, buffered > 0 else { return nil }
        return min(1, buffered / duration)
    }

    /// 片头区间带 + 片尾起点竖条(位置来自 `viewModel.markers`,手动标注与服务端标记合并后的结果)。
    ///
    /// 时长未知时**不画**:没有分母就算不出位置,画在哪儿都是猜的。
    @ViewBuilder
    private func markerOverlay(width: CGFloat) -> some View {
        if duration > 0 {
            if let intro = viewModel.markers.intro, intro.lowerBound < duration {
                let start = min(max(intro.lowerBound / duration, 0), 1)
                let end = min(max(intro.upperBound / duration, 0), 1)
                Capsule()
                    .fill(.tint)
                    .opacity(Metrics.scrubberMarkerOpacity)
                    .frame(width: max(Metrics.scrubberMarkerMinWidth, width * (end - start)))
                    .offset(x: width * start)
            }
            if let credits = viewModel.markers.creditsStart, credits < duration {
                Capsule()
                    .fill(.tint)
                    .opacity(Metrics.scrubberMarkerOpacity)
                    .frame(width: Metrics.scrubberMarkerWidth)
                    .offset(x: width * (credits / duration) - Metrics.scrubberMarkerWidth / 2)
            }
        }
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }
}

// MARK: - 音量 / 倍速 / 轨道

struct PlayerVolumeControl: View {
    let viewModel: PlayerViewModel

    var body: some View {
        HStack(spacing: Metrics.spacingXS) {
            PlayerIconButton(
                systemImage: PlayerViewModel.volumeSymbol(viewModel.volume, muted: viewModel.isMuted),
                label: viewModel.isMuted ? "取消静音" : "静音"
            ) { viewModel.toggleMute() }
            Slider(
                value: Binding(get: { viewModel.volume }, set: { viewModel.setVolume($0) }),
                in: 0...100
            )
            .controlSize(.small)
            .frame(width: Metrics.posterMinWidth / 2)
            .help("音量")
            .accessibilityLabel("音量")
        }
    }
}

/// 倍速:连续调节(滑块 + 步进),**不是固定档位**。
///
/// 用 `popover` 而不是 `Menu`:macOS 的 SwiftUI 菜单不承载可交互控件
/// (滑块放进去拖不动),浮层才行。滑块每动一步就直接写 mpv 的 `speed`,
/// 画面上的屏显同步跟着变,松手即停在那儿。
struct PlayerSpeedControl: View {
    let viewModel: PlayerViewModel
    @Binding var isPresented: Bool

    @State private var isHovering = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Text(PlayerViewModel.speedText(viewModel.speed))
                .font(.callout)
                .monospacedDigit()
                .frame(minWidth: Metrics.playerButtonSize, minHeight: Metrics.playerButtonSize)
                .background(Circle().fill(.white.opacity(isHovering ? 0.15 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .help("播放速度")
        .accessibilityLabel("播放速度")
        .accessibilityValue(PlayerViewModel.speedText(viewModel.speed))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { speedPopover }
    }

    private var speedPopover: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            HStack(spacing: Metrics.spacingS) {
                stepButton(up: false) { viewModel.stepSpeed(up: false, step: Metrics.speedStep) }
                Text(PlayerViewModel.speedText(viewModel.speed))
                    .font(.title3)
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .center)
                stepButton(up: true) { viewModel.stepSpeed(up: true, step: Metrics.speedStep) }
            }
            Slider(
                value: Binding(get: { viewModel.speed }, set: { viewModel.setSpeed($0) }),
                in: Metrics.speedRange,
                step: Metrics.speedStep
            )
            .help("拖动调整倍速")
            .accessibilityLabel("播放速度")
            .accessibilityValue(PlayerViewModel.speedText(viewModel.speed))
            HStack {
                Text(PlayerViewModel.speedText(Metrics.speedRange.lowerBound))
                Spacer()
                Button("正常速度") { viewModel.setSpeed(1) }
                    .buttonStyle(.plain)
                    .disabled(abs(viewModel.speed - 1) < 0.001)
                Spacer()
                Text(PlayerViewModel.speedText(Metrics.speedRange.upperBound))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(Metrics.spacingL)
        .frame(width: 240)
    }

    /// ± 一步(步长 `Metrics.speedStep`);贴着区间端点时置灰,而不是按了没反应
    private func stepButton(up: Bool, action: @escaping () -> Void) -> some View {
        let label = up ? "加快" : "减慢"
        return Button(action: action) {
            Image(systemName: up ? "plus" : "minus")
                .font(.title3)
                .frame(width: Metrics.playerButtonSize, height: Metrics.playerButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .disabled(
            PlayerViewModel.steppedSpeed(from: viewModel.speed, up: up, step: Metrics.speedStep)
                == PlayerViewModel.clampedSpeed(viewModel.speed)
        )
    }
}

/// 字幕菜单(DesignTokens.swift「界面规则」:临时层,低频操作放浮层不占底栏)。
/// 与音轨**分成两个入口** —— Apple TV 右下角就是独立的 CC 与 Audio 两个按钮,
/// Plex 也是 `S` 字幕 / `A` 音轨分开;合并成一个菜单会让人多找一次。
///
/// 用 `Picker` 而不是手画勾:系统菜单的勾选态 VoiceOver 能读出「已选择」(8.3)。
///
/// 轨道下面是**字幕延迟**与「字幕外观…」入口。延迟只给步进按钮、不给滑块:
/// 菜单里放不了可交互控件(见 `PlayerSpeedControl`),而且延迟要的是 0.1 秒级的微调,
/// 连续调主要靠 Z / X(菜单栏「Playback › Subtitle Delay」,按住可连发),这里是给鼠标用户的入口。
/// 外观是长期偏好,放设置窗口的「字幕」页,播放中改了即时生效。
struct PlayerSubtitleMenu: View {
    let viewModel: PlayerViewModel

    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    var body: some View {
        Menu {
            Picker("字幕", selection: Binding<Int?>(
                get: { viewModel.selectedSubtitleTrackID },
                set: { viewModel.selectSubtitleTrack($0) }
            )) {
                Text("关闭").tag(Int?.none)
                ForEach(viewModel.subtitleTracks) { track in
                    PlayerTrackLabel(track: track).tag(Int?.some(track.id))
                }
            }
            .pickerStyle(.inline)

            Section("字幕延迟:\(PlayerViewModel.subtitleDelayValueText(viewModel.subtitleDelay))") {
                PlayerSubtitleDelayButtons(viewModel: viewModel)
            }

            Divider()

            Button("字幕外观…") {
                settingsTab = .subtitles
                openSettings()
            }
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: Metrics.playerButtonSize, height: Metrics.playerButtonSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("字幕")
        .accessibilityLabel("字幕")
        .disabled(viewModel.subtitleTracks.isEmpty)
    }

    /// 有选中轨道时用实心图标,和「关着」区分得开 —— 与音量按钮同一套做法。
    private var symbol: String {
        viewModel.selectedSubtitleTrackID == nil ? "captions.bubble" : "captions.bubble.fill"
    }
}

/// 字幕延迟的提前 / 延后 / 重置。控制栏的字幕菜单与菜单栏「Playback › Subtitle Delay」共用,
/// 快捷键只挂在菜单栏那份上(`PlayerCommands`),这里挂会注册第二遍。
/// 菜单栏那份用英文,与系统菜单一致(见 `PlayerCommands`)。
struct PlayerSubtitleDelayButtons: View {
    let viewModel: PlayerViewModel
    /// 菜单栏那份:带快捷键、英文文案;控制栏里的不带快捷键、中文文案
    var inMenuBar = false

    var body: some View {
        Group {
            Button(earlier(Metrics.subtitleDelayStep)) {
                viewModel.stepSubtitleDelay(later: false)
            }
            .keyboardShortcut(shortcut("z", []))
            Button(later(Metrics.subtitleDelayStep)) {
                viewModel.stepSubtitleDelay(later: true)
            }
            .keyboardShortcut(shortcut("x", []))
            Button(earlier(Metrics.subtitleDelayLargeStep)) {
                viewModel.stepSubtitleDelay(later: false, step: Metrics.subtitleDelayLargeStep)
            }
            .keyboardShortcut(shortcut("z", .shift))
            Button(later(Metrics.subtitleDelayLargeStep)) {
                viewModel.stepSubtitleDelay(later: true, step: Metrics.subtitleDelayLargeStep)
            }
            .keyboardShortcut(shortcut("x", .shift))
            Button(inMenuBar ? "Reset Subtitle Delay" : "重置字幕延迟") { viewModel.resetSubtitleDelay() }
                .disabled(viewModel.subtitleDelay == 0)
        }
        .disabled(!viewModel.canAdjustSubtitleDelay)
    }

    private func earlier(_ step: Double) -> String {
        inMenuBar ? "Earlier by \(Self.seconds(step)) s" : "提前 \(Self.seconds(step)) 秒"
    }

    private func later(_ step: Double) -> String {
        inMenuBar ? "Later by \(Self.seconds(step)) s" : "延后 \(Self.seconds(step)) 秒"
    }

    private func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> KeyboardShortcut? {
        inMenuBar ? KeyboardShortcut(key, modifiers: modifiers) : nil
    }

    private static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// 音轨菜单。与字幕分开一个入口,理由同 `PlayerSubtitleMenu`。
struct PlayerAudioMenu: View {
    let viewModel: PlayerViewModel

    var body: some View {
        Menu {
            Picker("音轨", selection: Binding<Int?>(
                get: { viewModel.selectedAudioTrackID },
                set: { id in if let id { viewModel.selectAudioTrack(id) } }
            )) {
                ForEach(viewModel.audioTracks) { track in
                    PlayerTrackLabel(track: track).tag(Int?.some(track.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "waveform")
                .font(.title3)
                .frame(width: Metrics.playerButtonSize, height: Metrics.playerButtonSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("音轨")
        .accessibilityLabel("音轨")
        .disabled(viewModel.audioTracks.isEmpty)
    }
}

/// 低频的播放偏好:自动跳过片头、自动播下一集、手动片头片尾、置顶、统计信息。
/// 与菜单栏「Playback」菜单里的对应项是同一份状态。
struct PlayerOptionsMenu: View {
    @Bindable var viewModel: PlayerViewModel
    /// 手动片头片尾输入面板(由播放窗口持有并呈现 sheet;这里只负责打开)
    @Binding var isMarkersEditorPresented: Bool

    var body: some View {
        Menu {
            Toggle("自动跳过片头", isOn: $viewModel.autoSkipIntro)
            Toggle("自动播放下一集", isOn: $viewModel.autoPlayNext)
            Divider()
            markersMenu
            Divider()
            Toggle("窗口置顶", isOn: $viewModel.floatsOnTop)
            Toggle("显示统计信息", isOn: Binding(
                get: { viewModel.showsStatistics },
                set: { _ in viewModel.toggleStatistics() }
            ))
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: Metrics.playerButtonSize, height: Metrics.playerButtonSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("播放选项")
        .accessibilityLabel("播放选项")
    }

    /// 手动片头 / 片尾:服务端检测不出来时自己标。**同一部剧的每一集共用一份**,
    /// 所以在一集里标好后,这部剧后面的集数都套用(见 `ManualMarkersScope`)。
    ///
    /// 「按当前位置打点」放在最前:拖到片头 / 片尾再点最省事;要精确到秒才用「手动输入…」。
    ///
    /// ⚠️ 标签里⛔ **不要**写 `viewModel.positionSeconds`:它是每 0.2s 变一次的值,
    /// 一读就会让整个 `PlayerOptionsMenu` 跟着重绘,`ellipsis.circle` 这个 Menu 按钮
    /// 被反复重建 —— 悬停高亮一直在闪(2026-10-12 实测)。打点的具体秒数由点击后的
    /// 屏显提示(`flash`)给出,这里只报「会打在当前位置」。
    private var markersMenu: some View {
        Menu("片头片尾") {
            // 已经设了什么:先摆出来,否则设完只在屏显里闪一下,回头完全看不出来。
            // `manualMarkerValues` 只在用户改动时变,不会像 `positionSeconds` 那样每 0.2s 抖。
            if let summary = viewModel.manualMarkerValues?.summary {
                Text(summary)
                Divider()
            }
            Button("设为片头起点(当前位置)") {
                viewModel.setIntroStartAtCurrentPosition()
            }
            Button("设为片头终点(当前位置)") {
                viewModel.setIntroEndAtCurrentPosition()
            }
            Button("设为片尾起点(当前位置)") {
                viewModel.setCreditsStartAtCurrentPosition()
            }
            Divider()
            Button("手动输入…") { isMarkersEditorPresented = true }
            Button("清除本剧的片头片尾", role: .destructive) {
                viewModel.clearManualMarkers()
            }
            .disabled(!viewModel.hasManualMarkers)
        }
    }
}

// MARK: - 手动片头 / 片尾的文案

extension ManualMarkers {
    /// 菜单里显示「已经设了什么」的一行摘要;三个位置都没填时 nil。
    ///
    /// 例:`片头 00:30–02:00 · 片尾 22:00`。只填了一端、终点不晚于起点、片尾为 0
    /// 这几种都**不会生效**,摘要里明确写「未生效」—— 光看数字看不出这个区别。
    ///
    /// ⚠️ 放在 Features 层而不是 `ManualMarkers` 定义处:它要用 `PlayerTime.markerText`,
    /// 而 `ManualMarkers` 在 Core(⛔ Core 不依赖 Features)。
    var summary: String? {
        var parts: [String] = []
        switch (introStart, introEnd) {
        case let (start?, end?) where end > start:
            parts.append("片头 \(PlayerTime.markerText(start))–\(PlayerTime.markerText(end))")
        case (nil, nil):
            break
        default:
            parts.append("片头未生效")
        }
        if let creditsStart {
            parts.append(creditsStart > 0 ? "片尾 \(PlayerTime.markerText(creditsStart))" : "片尾未生效")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - 图标按钮

/// 轨道菜单里的一项:名称 + 语言 / 编码等补充信息(补充信息用次级色)。
struct PlayerTrackLabel: View {
    let track: MPVTrack

    var body: some View {
        if let detail = track.detail {
            Text("\(track.displayName)  \(Text(detail).foregroundStyle(.secondary))")
        } else {
            Text(track.displayName)
        }
    }
}

/// 连点累加的跳转倍数(纯值 + 显式时间参数,无 IO 无 SwiftUI,靠单元测试覆盖)。
///
/// 单独成类型而不是塞在按钮视图里:视图里的 `@State` + `Date()` 没法测,
/// 而「第几次点击跳几倍」「什么时候归零」正是最容易写错的地方。
struct PlayerSkipRepeat {
    /// 上一次点击的时刻;nil = 还没点过
    private(set) var lastClick: Date?
    /// 上一次点击用的倍数
    private(set) var multiple = 0

    init() {}

    /// 记一次点击,返回这次该跳的倍数。
    ///
    /// 距上次点击超过 `Metrics.seekRepeatResetDelay` 就重新从 1 开始;
    /// 否则在上一档上加 1,到 `Metrics.seekRepeatMaxMultiple` 封顶
    /// (不封顶的话连点几十次会一次跳走几小时)。
    mutating func advance(now: Date) -> Int {
        let expired = isExpired(now)
        multiple = expired ? 1 : min(multiple + 1, Metrics.seekRepeatMaxMultiple)
        lastClick = now
        return multiple
    }

    /// 下一次点击会用几倍 —— tooltip 要预告这个数,不是上一次已经用过的。
    func upcoming(now: Date) -> Int {
        let current = isExpired(now) ? 0 : min(multiple, Metrics.seekRepeatMaxMultiple)
        return min(current + 1, Metrics.seekRepeatMaxMultiple)
    }

    private func isExpired(_ now: Date) -> Bool {
        lastClick.map { now.timeIntervalSince($0) > Metrics.seekRepeatResetDelay } ?? true
    }
}

/// 后退 / 前进按钮:**连点累加**。
///
/// 第 n 次点击跳 `seekStep × n`(上限 `seekRepeatMaxMultiple` 倍),
/// 超过 `seekRepeatResetDelay` 没再点就归零重来。Apple TV 的说明写的是
/// "Click again to skip another 10 seconds",Plex 的 10 秒 / 10 分钟两级也是
/// 同一个思路:想跳远一点就多连点几次,不用先去找一个「跳 5 分钟」的入口。
///
/// 归零判断用 `Date` 直接比对,不另起 `Task` 计时 —— 每次点击都要能立刻
/// 读到当前累计值,定时器会引入状态竞争。
struct PlayerRepeatSkipButton: View {
    enum Direction {
        case backward
        case forward

        var delta: TimeInterval { self == .forward ? 1 : -1 }
        var verb: String { self == .forward ? "前进" : "后退" }

        /// 图标:系统只画得出 `Metrics.seekStepOptions` 这几档带数字的样式,
        /// 其余步长(以及设置页改了但这里还没刷新的一瞬)用不带数字的箭头。
        func symbol(seconds: Double) -> String {
            let base = self == .forward ? "goforward" : "gobackward"
            let value = Int(seconds)
            guard Metrics.seekStepOptions.contains(where: { Int($0) == value }) else { return base }
            return "\(base).\(value)"
        }
    }

    let direction: Direction
    let viewModel: PlayerViewModel

    @State private var skipRepeat = PlayerSkipRepeat()

    var body: some View {
        PlayerIconButton(systemImage: direction.symbol(seconds: viewModel.seekStep), label: label) {
            let multiple = skipRepeat.advance(now: Date())
            viewModel.skip(by: direction.delta * viewModel.seekStep * Double(multiple))
        }
        // 内核还没 file-loaded、或已经播完时不给按:那两种状态下 mpv 对 seek
        // 必拒(PITFALLS),按了只会闪一句失败。
        // ⛔ 门禁只取 `isReadyToSeek`,刻意不含 `seekStrategy` —— 拖不动的源
        // 按下去要能听到一句「为什么不行」(`seek` 的 `.unsupported` 分支)。
        .disabled(!viewModel.isReadyToSeek)
    }

    private var label: String {
        "\(direction.verb) \(Int(viewModel.seekStep) * skipRepeat.upcoming(now: Date())) 秒"
    }
}

/// 播放器里统一的图标按钮:固定点击区域、悬停时画一个淡圆底,
/// 带 tooltip 与 `accessibilityLabel`(DesignTokens.swift「界面规则」)。
struct PlayerIconButton: View {
    let systemImage: String
    let label: String
    var prominent = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(prominent ? .title2 : .title3)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Metrics.playerButtonSize, height: Metrics.playerButtonSize)
                .background(
                    Circle().fill(.white.opacity(isHovering ? 0.15 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - 时间文案

enum PlayerTime {
    /// 时间标签。总时长未知(0 / 非有限值)时显示 `--:--`,
    /// ⛔ 不填 `0:00` 假装已知(API_CONTRACT.md 8.1)。
    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// 标记位置的回显:`0` 也要显示成 `00:00`。
    ///
    /// ⛔ 与 `text(_:)` 分开:`text(0)` 返回 `--:--`(那是「时长未知」的语义),
    /// 而标记位置的 0 是「片头从片首开始」这个**真实值** —— 按 `text` 回显成 `--:--`,
    /// 再保存一次就把它弄丢了。`nil` 返回空串(那一格没标)。
    static func markerText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// 解析用户输入的时间(手动片头片尾的文本框):接受 `hh:mm:ss` / `mm:ss` / 秒数
    /// (`90` / `90.5`)。`hh` 与纯秒数那一档可以任意大,`mm` / `ss` 必须落在 0–59。
    ///
    /// 解析不出、为空、或为负时返回 nil —— ⛔ 不当作 0:`text(0)` 是「未知」的语义,
    /// 拿 0 冒充用户填的值会把片头标到片首(与「时长未知不给 0」同一立场)。
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value.isFinite, value >= 0 else { return nil }
            // 除第一段(时 / 纯秒数)外,分与秒必须落在 0–59
            if index > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// VoiceOver 读的版本:「1 小时 2 分 3 秒」,不读冒号。
    static func spokenText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "未知" }
        let duration = Duration.seconds(Int(seconds.rounded()))
        return duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// 剩余时长的标签:比 `text` 多一个 `-` 前缀。
    ///
    /// 抽出来是因为**剩余为 0 和时长未知是两回事**,而两者都会让
    /// `text` 返回 `--:--`,拼上 `-` 就成了 `---:--`(2026-10-03 修复):
    ///
    /// - 时长未知(`duration <= 0`)→ `--:--`,⛔ 不加负号。负号在这里
    ///   是「相对总时长的差值」的语义,没有总量就没有差值。
    /// - 剩余为 0(拖到最右 / 播到结尾)→ `-00:00`,负号保留。这是「确实
    ///   剩 0 秒」,不是不知道 —— `text(0)` 的 `--:--` 语义在这里是错的。
    static func remainingText(_ seconds: Double, durationKnown: Bool) -> String {
        guard durationKnown else { return text(0) }
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        let total = Int(clamped.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "-%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "-%02d:%02d", minutes, secs)
    }

    /// 按剩余时长与当前倍速推算的结束时刻。
    ///
    /// 倍速必须参与计算:1.25× 下「还剩 44 分钟」实际只过 35 分钟,
    /// 不换算就会算出一个偏晚的时刻。显示层拿它回答「看完得到几点」。
    ///
    /// 返回 nil 的四种情况,都是「宁可不显示也不显示编出来的值」:
    /// 时长未知(`API_CONTRACT.md` 8.1)、已播完、倍速非正或非有限、
    /// 剩余时长非正。
    static func endsAt(
        position: Double,
        duration: Double,
        speed: Double,
        isEnded: Bool,
        now: Date = Date()
    ) -> Date? {
        guard duration.isFinite, duration > 0, !isEnded else { return nil }
        guard speed.isFinite, speed > 0 else { return nil }
        guard position.isFinite else { return nil }
        let remaining = duration - position
        guard remaining > 0 else { return nil }
        return now.addingTimeInterval(remaining / speed)
    }
}
