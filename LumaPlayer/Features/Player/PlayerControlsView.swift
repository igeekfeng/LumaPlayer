import SwiftUI

/// 播放器底部控制栏(DesignTokens.swift「界面规则」)。
///
/// 从左到右:播放簇 → 音量 → 倍速 / 字幕 / 弹幕 / 音轨 / 选项 → 选集(最右)。
/// ⛔ 不放全屏图标(F 与双击画面已够),最右位置留给选集。
///
/// 形态:全宽底部横条 + 渐变压暗,⛔ 不用悬浮玻璃药丸(HIG 要求玻璃压视频须配 dimming layer;
/// 渐变在明暗剧变的画面上更可预测)。
///
/// 进度条只交出目标秒数,DirectStream / 转码的 seek 差异在 `PlayerViewModel.seek` 分派(API_CONTRACT.md 4.5)。
///
/// 直接持有 ViewModel:`@Observable` 按属性追踪,每 0.2s 的 `time-pos` 只让 `PlayerScrubber` 重算。
struct PlayerControlsView: View {
    let viewModel: PlayerViewModel
    // 以下浮层 / 面板打开期间都要钉住控制栏,否则会随控制栏自动隐藏一起消失
    @Binding var isSpeedPopoverPresented: Bool
    @Binding var isEpisodePanelPresented: Bool
    @Binding var isMarkersEditorPresented: Bool
    @Binding var isDanmakuPickerPresented: Bool
    @Binding var isSubtitleImporterPresented: Bool
    @Binding var isSubtitleSearchPresented: Bool

    var body: some View {
        VStack(spacing: Metrics.spacingS) {
            PlayerScrubber(viewModel: viewModel)
            HStack(spacing: Metrics.spacingM) {
                transport
                PlayerVolumeControl(viewModel: viewModel)
                Spacer(minLength: Metrics.spacingL)
                PlayerSpeedControl(viewModel: viewModel, isPresented: $isSpeedPopoverPresented)
                PlayerSubtitleMenu(
                    viewModel: viewModel,
                    isImporterPresented: $isSubtitleImporterPresented,
                    isSearchPresented: $isSubtitleSearchPresented)
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
        // 压暗衬底铺到窗口底边,不留窗口背景色窄条
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) { scrim }
    }

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

    /// 播放键左右紧贴上一集 / 下一集,±跳转在最外侧。上下集没有就不占位。
    ///
    /// 已知取舍:没有上下集时播放键会左移一个按钮位,⛔ 不要「修」成固定最左。
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

    /// 切换 `PlayerEpisodePanel`。抽屉打开后会盖住这个按钮,收起靠抽屉左缘把手。
    /// ⛔ 不用 `Menu` / `popover`:几百集时铺不开。
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

/// 进度条:悬停显示该点时间,拖动中显示目标时间,松手才 seek。
/// 左边已播放,右边剩余时长 / 预计结束时刻(点击切换)。
///
/// 自绘而不用 `Slider`:系统滑块没有悬停预览,且拖动中会被 time-pos 拉回。
/// 键盘与 VoiceOver 走 `accessibilityAdjustableAction`。
struct PlayerScrubber: View {
    let viewModel: PlayerViewModel

    /// 拖动中的目标秒数;nil 表示跟随播放位置
    @State private var dragging: Double?
    /// 进度条坐标系;nil = 没悬停
    @State private var hoverX: CGFloat?
    /// 跨次启动记住
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

    /// `endsAt` 为 nil 时退回剩余时长。⛔ 别写成 `"-" + PlayerTime.text(...)`:
    /// 时长未知时会拼出 `---:--`,用 `PlayerTime.remainingText`。
    private var trailingText: String {
        if showsEndTime, let endsAt {
            return "\(endsAt.formatted(date: .omitted, time: .shortened)) 结束"
        }
        return PlayerTime.remainingText(
            duration - displayed,
            durationKnown: duration > 0
        )
    }

    /// 时长未知、已播完、倍速非正时为 nil。
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
                // 已缓存段画在已播放段下面,重叠时不用算交集
                if let buffered = bufferedFraction {
                    Capsule()
                        .fill(.white.opacity(Metrics.scrubberBufferedOpacity))
                        .frame(width: width * buffered)
                }
                // 章节刻度画在已播放段**之下**:经过的章节不必再占视觉(也避开白底白线)
                chapterTickOverlay(width: width)
                Capsule()
                    .fill(.white.opacity(Metrics.scrubberPlayedOpacity))
                    .frame(width: width * fraction)
                // 标记画在已播放段之上,播过后仍可见。颜色不是唯一表达:菜单里有文字摘要
                markerOverlay(width: width)
            }
            .frame(height: trackHeight)
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: Metrics.animationFast), value: isActive)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: min(max(width * fraction - knobSize / 2, 0), max(0, width - knobSize)))
                    .animation(.easeOut(duration: Metrics.animationFast), value: fraction)
                    // 也跟 isActive 做动画,否则悬停切换尺寸会硬跳
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
        // 拖不动的源直接禁用(判据见 `PlaybackSeekStrategy`)
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

    /// 章节起点竖线(`viewModel.chapters`)。至少两章才画:单章等于整片,画在 0 处只是杂讯。
    /// 转码流通常没有章节,自然不画。
    @ViewBuilder
    private func chapterTickOverlay(width: CGFloat) -> some View {
        if duration > 0, viewModel.chapters.count > 1 {
            ForEach(viewModel.chapters) { chapter in
                if chapter.time > 0, chapter.time < duration {
                    Rectangle()
                        .fill(.white.opacity(Metrics.scrubberChapterTickOpacity))
                        .frame(width: Metrics.scrubberChapterTickWidth, height: trackHeight)
                        .offset(x: width * (chapter.time / duration))
                }
            }
        }
    }

    /// 片头区间带 + 片尾起点竖条(`viewModel.markers`)。时长未知时不画。
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

/// 倍速:连续调节(滑块 + 步进)。用 `popover` 不用 `Menu`:macOS 菜单里的滑块拖不动。
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

    /// 贴着区间端点时置灰
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

/// 字幕菜单,与音轨分成两个入口。用 `Picker` 而非手画勾:VoiceOver 能读出选中态(8.3)。
///
/// 字幕延迟只给步进按钮(菜单里放不了滑块);连续调靠 Z / X。外观在设置窗口「字幕」页。
///
/// ⛔ 菜单整体不按「有没有字幕轨」禁用:「打开本地字幕…」正是给没有字幕轨的片源用的。
struct PlayerSubtitleMenu: View {
    let viewModel: PlayerViewModel
    // 面板与 sheet 挂在 `PlayerWindowView` 上:菜单点开就收起,不能在这里挂 `fileImporter`
    @Binding var isImporterPresented: Bool
    @Binding var isSearchPresented: Bool

    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    var body: some View {
        Menu {
            if viewModel.subtitleTracks.isEmpty {
                Text("没有字幕轨")
            } else {
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
            }

            Divider()

            Button("打开本地字幕…") { isImporterPresented = true }
            Button("搜索在线字幕…") { isSearchPresented = true }

            Divider()

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
    }

    private var symbol: String {
        viewModel.selectedSubtitleTrackID == nil ? "captions.bubble" : "captions.bubble.fill"
    }
}

/// 字幕延迟按钮,控制栏字幕菜单与菜单栏「Playback › Subtitle Delay」共用。
/// 快捷键只挂在菜单栏那份上,两份都挂会注册两遍。
struct PlayerSubtitleDelayButtons: View {
    let viewModel: PlayerViewModel
    /// 菜单栏那份:带快捷键、英文文案
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

/// 音轨菜单:选轨 + 音频延迟。延迟放这里而不是单开一个按钮 —— 都是「听」的事,也免得控制栏挤。
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

            Divider()

            Section("音频延迟:\(PlayerViewModel.audioDelayValueText(viewModel.audioDelay))") {
                PlayerAudioDelayButtons(viewModel: viewModel)
            }
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

/// 音频延迟按钮,控制栏音轨菜单与菜单栏「Playback › Audio Delay」共用。
/// 快捷键只挂在菜单栏那份上(与字幕延迟同一个约定:两份都挂会注册两遍)。
struct PlayerAudioDelayButtons: View {
    let viewModel: PlayerViewModel
    /// 菜单栏那份:带快捷键、英文文案
    var inMenuBar = false

    var body: some View {
        Group {
            Button(earlier(Metrics.audioDelayStep)) {
                viewModel.stepAudioDelay(later: false)
            }
            .keyboardShortcut(shortcut("c", []))
            Button(later(Metrics.audioDelayStep)) {
                viewModel.stepAudioDelay(later: true)
            }
            .keyboardShortcut(shortcut("v", []))
            Button(earlier(Metrics.audioDelayLargeStep)) {
                viewModel.stepAudioDelay(later: false, step: Metrics.audioDelayLargeStep)
            }
            .keyboardShortcut(shortcut("c", .shift))
            Button(later(Metrics.audioDelayLargeStep)) {
                viewModel.stepAudioDelay(later: true, step: Metrics.audioDelayLargeStep)
            }
            .keyboardShortcut(shortcut("v", .shift))
            Button(inMenuBar ? "Reset Audio Delay" : "重置音频延迟") { viewModel.resetAudioDelay() }
                .disabled(viewModel.audioDelay == 0)
        }
        .disabled(!viewModel.canAdjustAudioDelay)
    }

    private func earlier(_ step: Double) -> String {
        inMenuBar ? "Advance Audio by \(Self.seconds(step)) s" : "音频提前 \(Self.seconds(step)) 秒"
    }

    private func later(_ step: Double) -> String {
        inMenuBar ? "Delay Audio by \(Self.seconds(step)) s" : "音频延后 \(Self.seconds(step)) 秒"
    }

    private func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> KeyboardShortcut? {
        inMenuBar ? KeyboardShortcut(key, modifiers: modifiers) : nil
    }

    private static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// 低频播放偏好,与菜单栏「Playback」里的对应项同一份状态。
struct PlayerOptionsMenu: View {
    @Bindable var viewModel: PlayerViewModel
    /// sheet 由播放窗口呈现,这里只负责打开
    @Binding var isMarkersEditorPresented: Bool

    var body: some View {
        Menu {
            Toggle("自动跳过片头", isOn: $viewModel.autoSkipIntro)
            Toggle("自动播放下一集", isOn: $viewModel.autoPlayNext)
            Divider()
            markersMenu
            chapterMenu
            Divider()
            pictureMenu
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

    /// 手动片头 / 片尾,同一部剧共用(`ManualMarkersScope`)。
    ///
    /// ⛔ 标签里不要读 `viewModel.positionSeconds`:每 0.2s 变一次,会让 Menu 按钮反复重建、
    /// 悬停高亮一直闪。打点的秒数由点击后的屏显给出。
    private var markersMenu: some View {
        Menu("片头片尾") {
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

    /// 容器章节(Emby / 百度 / 本地统一由 mpv 给)。至少两章才出现在菜单里。
    ///
    /// 跳转走 `viewModel.seekToChapter` 而不是 mpv 的 `chapter` 属性:转码流必须由客户端重新起流。
    @ViewBuilder
    private var chapterMenu: some View {
        if viewModel.hasChapters {
            Picker("章节", selection: Binding<Int?>(
                get: { viewModel.currentChapter?.id },
                set: { id in
                    guard let id, let chapter = viewModel.chapters.first(where: { $0.id == id })
                    else { return }
                    viewModel.seekToChapter(chapter)
                }
            )) {
                ForEach(viewModel.chapters) { chapter in
                    Text("\(PlayerTime.markerText(chapter.time))  \(chapter.displayName)")
                        .tag(Int?.some(chapter.id))
                }
            }
            .pickerStyle(.inline)
            .disabled(!viewModel.canSkipChapter)
        }
    }

    /// 画面适配:填充 / 宽高比 / 缩放 / 旋转(MPV_INTEGRATION.md 7.4)。
    /// 都是「针对这一集源」的临时修正,所以不给持久化,换片回到自动。
    private var pictureMenu: some View {
        Menu("画面") {
            Picker("比例", selection: Binding(
                get: { viewModel.picture.fit },
                set: { viewModel.setPictureFit($0) }
            )) {
                ForEach(PictureSettings.Fit.allCases) { fit in
                    Text(fit.displayName).tag(fit)
                }
            }
            .pickerStyle(.inline)

            Picker("宽高比", selection: Binding(
                get: { viewModel.picture.aspect },
                set: { viewModel.setPictureAspect($0) }
            )) {
                ForEach(PictureSettings.Aspect.allCases) { aspect in
                    Text(aspect.displayName).tag(aspect)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button("放大") { viewModel.stepPictureZoom(up: true) }
            Button("缩小") { viewModel.stepPictureZoom(up: false) }
            Button("缩放 100%") { viewModel.resetPictureZoom() }
                .disabled(viewModel.picture.zoom == 0)
            Button("顺时针旋转 90°") { viewModel.rotatePicture() }
            if viewModel.picture.rotation != 0 {
                Text("已旋转 \(viewModel.picture.rotation)°")
            }

            Divider()

            Button("画面设置复位") { viewModel.resetPicture() }
                .disabled(!viewModel.isPictureAdjusted)
        }
        .disabled(viewModel.session == nil)
    }
}

// MARK: - 手动片头 / 片尾的文案

extension ManualMarkers {
    /// 例:`片头 00:30–02:00 · 片尾 22:00`;都没填时 nil。不会生效的组合明确写「未生效」。
    ///
    /// 放在 Features 层:要用 `PlayerTime.markerText`,⛔ Core 不依赖 Features。
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

/// 连点累加的跳转倍数(纯值 + 显式时间参数,便于单测)。
struct PlayerSkipRepeat {
    /// nil = 还没点过
    private(set) var lastClick: Date?
    private(set) var multiple = 0

    init() {}

    /// 返回这次该跳的倍数:距上次超过 `seekRepeatResetDelay` 从 1 重来,否则 +1,
    /// 到 `seekRepeatMaxMultiple` 封顶。
    mutating func advance(now: Date) -> Int {
        let expired = isExpired(now)
        multiple = expired ? 1 : min(multiple + 1, Metrics.seekRepeatMaxMultiple)
        lastClick = now
        return multiple
    }

    /// 下一次点击会用几倍(tooltip 预告用)。
    func upcoming(now: Date) -> Int {
        let current = isExpired(now) ? 0 : min(multiple, Metrics.seekRepeatMaxMultiple)
        return min(current + 1, Metrics.seekRepeatMaxMultiple)
    }

    private func isExpired(_ now: Date) -> Bool {
        lastClick.map { now.timeIntervalSince($0) > Metrics.seekRepeatResetDelay } ?? true
    }
}

/// 后退 / 前进按钮,连点累加:第 n 次跳 `seekStep × n`(见 `PlayerSkipRepeat`)。
/// 归零用 `Date` 比对,⛔ 不另起 `Task` 计时(会引入状态竞争)。
struct PlayerRepeatSkipButton: View {
    enum Direction {
        case backward
        case forward

        var delta: TimeInterval { self == .forward ? 1 : -1 }
        var verb: String { self == .forward ? "前进" : "后退" }

        /// SF Symbols 只有 `Metrics.seekStepOptions` 这几档带数字,其余用不带数字的箭头。
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
        // file-loaded 前 / 播完后 mpv 必拒 seek(PITFALLS)。
        // ⛔ 刻意不含 `seekStrategy`:拖不动的源按下去要给出原因(`seek` 的 `.unsupported` 分支)
        .disabled(!viewModel.isReadyToSeek)
    }

    private var label: String {
        "\(direction.verb) \(Int(viewModel.seekStep) * skipRepeat.upcoming(now: Date())) 秒"
    }
}

/// 播放器统一图标按钮(DesignTokens.swift「界面规则」)。
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
    /// 0 / 非有限值显示 `--:--`,⛔ 不填 `0:00` 假装已知(API_CONTRACT.md 8.1)。
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

    /// 标记位置回显,0 显示 `00:00`(真实值,⛔ 不能用 `text` 回显成 `--:--` 再存丢);nil 返回空串。
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

    /// 接受 `hh:mm:ss` / `mm:ss` / 秒数(`90.5`);首段可任意大,其余须在 0–59。
    /// 解析不出、为空、为负返回 nil,⛔ 不当作 0(会把片头标到片首)。
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value.isFinite, value >= 0 else { return nil }
            if index > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// VoiceOver 用:「1 小时 2 分 3 秒」。
    static func spokenText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "未知" }
        let duration = Duration.seconds(Int(seconds.rounded()))
        return duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// 剩余时长,带 `-` 前缀。剩余为 0 与时长未知是两回事:
    /// 时长未知 → `--:--`(不加负号);剩余为 0 → `-00:00`。
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

    /// 按剩余时长 ÷ 倍速推算的结束时刻。时长未知(`API_CONTRACT.md` 8.1)、已播完、
    /// 倍速非法、剩余非正时返回 nil。
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
