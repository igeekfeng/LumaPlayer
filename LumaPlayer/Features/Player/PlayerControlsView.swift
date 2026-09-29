import SwiftUI

/// 播放器底部控制栏(UI_DESIGN.md 5.2 的优先级:播放/暂停 → 进度 →
/// 音量 → 字幕/音轨 → 全屏 → 其他)。
///
/// 进度条对两种播放方式**行为不同**:
/// DirectStream 拖动 = mpv seek;转码拖动 = 停流 + `StartTimeTicks` 重新起流
/// (API_CONTRACT.md 4.5)。差异在 `PlayerViewModel.seek` 里分派,
/// 本视图只负责把目标秒数交出去。
///
/// 直接持有 ViewModel 而不是逐个传值:`@Observable` 按属性追踪读取,
/// 每 0.2s 一次的 `time-pos` 只让读了位置的 `PlayerScrubber` 重算,
/// 按钮行不跟着重绘(UI_DESIGN.md 第 9 节第 4 条)。
struct PlayerControlsView: View {
    let viewModel: PlayerViewModel
    var toggleFullScreen: () -> Void
    /// 有下一集时才给(剧集且不是最后一集)
    var playNext: (() -> Void)?
    /// 倍速浮层是否打开:打开期间控制栏不能自动隐藏,否则浮层连着控制栏一起消失
    @Binding var isSpeedPopoverPresented: Bool

    var body: some View {
        VStack(spacing: Metrics.spacingS) {
            PlayerScrubber(viewModel: viewModel)
            HStack(spacing: Metrics.spacingM) {
                transport
                PlayerVolumeControl(viewModel: viewModel)
                Spacer(minLength: Metrics.spacingL)
                PlayerSpeedControl(viewModel: viewModel, isPresented: $isSpeedPopoverPresented)
                PlayerTrackMenu(viewModel: viewModel)
                PlayerOptionsMenu(viewModel: viewModel)
                if let playNext {
                    PlayerIconButton(
                        systemImage: "forward.end.fill",
                        label: "下一集",
                        action: playNext
                    )
                }
                PlayerIconButton(
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    label: "切换全屏",
                    action: toggleFullScreen
                )
            }
        }
        .padding(.horizontal, Metrics.spacingL)
        .padding(.vertical, Metrics.spacingM)
        // UI_DESIGN.md 4.1:控制栏用圆角矩形玻璃;里面的按钮保持无底色,
        // 不做「玻璃叠玻璃」,悬停反馈由 PlayerIconButton 自己画。
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.glassBar))
    }

    /// 播放 / 暂停位置固定在最左,不因其他控件出现与否而移动(5.2)。
    private var transport: some View {
        HStack(spacing: Metrics.spacingXS) {
            PlayerIconButton(
                systemImage: "gobackward.10",
                label: "后退 \(Int(Metrics.seekStep)) 秒"
            ) { viewModel.skip(by: -Metrics.seekStep) }
            PlayerIconButton(
                systemImage: viewModel.isPaused ? "play.fill" : "pause.fill",
                label: viewModel.isPaused ? "播放" : "暂停",
                prominent: true
            ) { viewModel.togglePlayPause() }
            PlayerIconButton(
                systemImage: "goforward.10",
                label: "前进 \(Int(Metrics.seekStep)) 秒"
            ) { viewModel.skip(by: Metrics.seekStep) }
        }
    }
}

// MARK: - 进度条

/// 进度条:悬停显示该点的时间,拖动中显示目标时间,松手才 seek。
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
    /// 右侧显示剩余时间还是总时长(点一下切换,跨次启动记住)
    @AppStorage("player.showsRemainingTime") private var showsRemaining = false

    private var duration: Double { viewModel.durationSeconds }
    /// 优先级:鼠标拖动 > 触控板横滑预览 > 实际播放位置
    private var displayed: Double { dragging ?? viewModel.scrubPreviewSeconds ?? viewModel.positionSeconds }
    private var isActive: Bool { dragging != nil || hoverX != nil }

    var body: some View {
        HStack(spacing: Metrics.spacingM) {
            Text(PlayerTime.text(displayed))
                .font(.caption)
                .monospacedDigit()
            track
            Button {
                showsRemaining.toggle()
            } label: {
                Text(trailingText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(duration <= 0)
            .help(showsRemaining ? "显示总时长" : "显示剩余时间")
        }
    }

    private var trailingText: String {
        guard duration > 0 else { return PlayerTime.text(0) }
        return showsRemaining
            ? "-" + PlayerTime.text(max(0, duration - displayed))
            : PlayerTime.text(duration)
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = duration > 0 ? min(1, max(0, displayed / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                // 已缓存到的位置(mpv demuxer-cache-time):比底色亮一档,比已播放暗
                if let buffered = bufferedFraction {
                    Capsule().fill(.white.opacity(0.45)).frame(width: width * buffered)
                }
                Capsule().fill(.white).frame(width: width * fraction)
            }
            .frame(height: isActive ? Metrics.spacingS : Metrics.spacingXS)
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: Metrics.animationFast), value: isActive)
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
                            y: -Metrics.spacingM
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
        .disabled(duration <= 0)
        .help("拖动调整进度")
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(PlayerTime.spokenText(displayed)),共 \(PlayerTime.spokenText(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: viewModel.skip(by: Metrics.seekStep)
            case .decrement: viewModel.skip(by: -Metrics.seekStep)
            @unknown default: break
            }
        }
    }

    private var bufferedFraction: Double? {
        guard duration > 0, let buffered = viewModel.bufferedUntilSeconds, buffered > 0 else { return nil }
        return min(1, buffered / duration)
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

/// 音轨 / 字幕菜单(UI_DESIGN.md 2:临时层,低频操作放浮层不占底栏)。
/// 用 `Picker` 而不是手画勾:系统菜单的勾选态 VoiceOver 能读出「已选择」(8.3)。
struct PlayerTrackMenu: View {
    let viewModel: PlayerViewModel

    var body: some View {
        Menu {
            if !viewModel.subtitleTracks.isEmpty {
                Picker("字幕", selection: Binding<Int?>(
                    get: { viewModel.selectedSubtitleTrackID },
                    set: { viewModel.selectSubtitleTrack($0) }
                )) {
                    Text("关闭").tag(Int?.none)
                    ForEach(viewModel.subtitleTracks) { track in
                        trackLabel(track).tag(Int?.some(track.id))
                    }
                }
                .pickerStyle(.inline)
            }
            if !viewModel.audioTracks.isEmpty {
                Picker("音轨", selection: Binding<Int?>(
                    get: { viewModel.selectedAudioTrackID },
                    set: { id in if let id { viewModel.selectAudioTrack(id) } }
                )) {
                    ForEach(viewModel.audioTracks) { track in
                        trackLabel(track).tag(Int?.some(track.id))
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.title3)
                .frame(width: Metrics.playerButtonSize, height: Metrics.playerButtonSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("字幕与音轨")
        .accessibilityLabel("选择字幕或音轨")
        .disabled(viewModel.audioTracks.isEmpty && viewModel.subtitleTracks.isEmpty)
    }

    private func trackLabel(_ track: MPVTrack) -> Text {
        guard let detail = track.detail else { return Text(track.displayName) }
        return Text("\(track.displayName)  \(Text(detail).foregroundStyle(.secondary))")
    }
}

/// 低频的播放偏好:自动跳过片头、自动播下一集、置顶、统计信息。
/// 与菜单栏「播放」菜单里的同名项是同一份状态。
struct PlayerOptionsMenu: View {
    @Bindable var viewModel: PlayerViewModel

    var body: some View {
        Menu {
            Toggle("自动跳过片头", isOn: $viewModel.autoSkipIntro)
            Toggle("自动播放下一集", isOn: $viewModel.autoPlayNext)
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
}

// MARK: - 图标按钮

/// 播放器里统一的图标按钮:固定点击区域、悬停时画一个淡圆底,
/// 带 tooltip 与 `accessibilityLabel`(UI_DESIGN.md 5.2 / 8.3)。
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

    /// VoiceOver 读的版本:「1 小时 2 分 3 秒」,不读冒号。
    static func spokenText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "未知" }
        let duration = Duration.seconds(Int(seconds.rounded()))
        return duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}
