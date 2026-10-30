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
    @Binding var isEpisodePanelPresented: Bool
    /// 倍速 / 字幕 / 弹幕 / 音轨 / 播放选项面板,由播放窗口画(`PlayerPanelKind`)
    @Binding var activePanel: PlayerPanelKind?

    var body: some View {
        VStack(spacing: Metrics.spacingS) {
            PlayerScrubber(viewModel: viewModel)
            HStack(spacing: Metrics.spacingM) {
                transport
                PlayerVolumeControl(viewModel: viewModel)
                Spacer(minLength: Metrics.spacingL)
                panelButtons
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

    private var panelButtons: some View {
        HStack(spacing: Metrics.spacingXS) {
            PlayerPanelButton(kind: .speed, activePanel: $activePanel, help: "播放速度") {
                Text(PlayerViewModel.speedText(viewModel.speed))
                    .font(.callout)
                    .monospacedDigit()
                    .padding(.horizontal, Metrics.spacingS)
            }
            .accessibilityValue(PlayerViewModel.speedText(viewModel.speed))
            PlayerPanelButton(kind: .subtitles, activePanel: $activePanel, help: "字幕") {
                Image(systemName: viewModel.selectedSubtitleTrackID == nil ? "captions.bubble" : "captions.bubble.fill")
                    .font(.title3)
            }
            PlayerPanelButton(kind: .danmaku, activePanel: $activePanel, help: "弹幕") {
                Image(systemName: viewModel.danmaku.isVisible ? "text.bubble.fill" : "text.bubble")
                    .font(.title3)
            }
            PlayerPanelButton(kind: .audio, activePanel: $activePanel, help: "音轨") {
                Image(systemName: "waveform")
                    .font(.title3)
            }
            .disabled(viewModel.audioTracks.isEmpty)
            PlayerPanelButton(kind: .options, activePanel: $activePanel, help: "播放选项") {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
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
                    Circle().fill(.white.opacity(isHovering ? Metrics.playerButtonHoverOpacity : 0))
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
