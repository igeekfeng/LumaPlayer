import AppKit
import SwiftUI

// MARK: - 面板骨架

/// 控制栏上点开的面板:倍速、字幕、弹幕、音轨、播放选项五个入口共用同一形态(`PlayerPanelChrome`)。
///
/// 不用 `Menu`:系统菜单行高只有 22pt、白底压在视频上突兀,延迟只能拆成好几行文字按钮,倍速放不了滑块。
/// 不用 `.popover`:系统箭头与材质跟控制栏对不上。面板画在播放窗口的覆盖层里(`PlayerWindowView`),
/// 按钮经 `PlayerPanelAnchorKey` 报自己的位置,面板贴着按钮上方摆。
/// ⛔ 这一排入口只能整体换形态:混用时一开一个样,对不上(这正是之前单开倍速浮层被撤掉的原因)。
/// 多级内容(播放选项里的画面 / 章节…)在面板内翻页(`PlayerPanelBackHeader`),⛔ 不叠第二层浮层。
enum PlayerPanelKind: Hashable {
    case speed
    case subtitles
    case danmaku
    case audio
    case options
}

/// 控制栏按钮的边框,供覆盖层定位面板
struct PlayerPanelAnchorKey: PreferenceKey {
    static let defaultValue: [PlayerPanelKind: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [PlayerPanelKind: Anchor<CGRect>],
        nextValue: () -> [PlayerPanelKind: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}

/// 控制栏上打开面板的按钮。点同一个收起,点另一个直接切过去。
struct PlayerPanelButton<Label: View>: View {
    let kind: PlayerPanelKind
    @Binding var activePanel: PlayerPanelKind?
    let help: String
    @ViewBuilder let label: Label

    @State private var isHovering = false

    private var isOpen: Bool { activePanel == kind }

    var body: some View {
        Button {
            activePanel = isOpen ? nil : kind
        } label: {
            label
                .frame(minWidth: Metrics.playerButtonSize, minHeight: Metrics.playerButtonSize)
                .background(Capsule().fill(.white.opacity(fillOpacity)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .anchorPreference(key: PlayerPanelAnchorKey.self, value: .bounds) { [kind: $0] }
    }

    private var fillOpacity: Double {
        if isOpen { return Metrics.playerButtonActiveOpacity }
        return isHovering ? Metrics.playerButtonHoverOpacity : 0
    }
}

/// 面板外壳:玻璃 + 压暗(视频亮度不可控,只靠玻璃压不住)。
struct PlayerPanelChrome<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            content
        }
        .padding(Metrics.spacingS)
        .frame(width: Metrics.playerPanelWidth)
        .background(
            Color.black.opacity(Metrics.playerPanelDimOpacity),
            in: .rect(cornerRadius: Radius.playerPanel))
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.playerPanel))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// 面板内的按钮底:行常态无底、档位 / 入口块常态有浅底;悬停、按下逐级加深。
struct PlayerPanelButtonStyle: ButtonStyle {
    enum Shape {
        /// 整行(选轨、动作)
        case row
        /// 档位、步进按钮、入口块
        case tile
    }

    var shape: Shape = .row
    /// 行:当前选中;档位:当前档(强调色实底)
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        PlayerPanelButtonBody(configuration: configuration, shape: shape, isSelected: isSelected)
    }
}

private struct PlayerPanelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let shape: PlayerPanelButtonStyle.Shape
    let isSelected: Bool

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(fill, in: .rect(cornerRadius: Radius.playerPanelItem))
            .contentShape(.rect(cornerRadius: Radius.playerPanelItem))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
    }

    private var foreground: AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(.tertiary) }
        if shape == .tile, isSelected { return AnyShapeStyle(.white) }
        return AnyShapeStyle(.primary)
    }

    private var fill: AnyShapeStyle {
        if shape == .tile, isSelected { return AnyShapeStyle(Color.accentColor) }
        let opacity: Double
        if isEnabled, configuration.isPressed {
            opacity = Metrics.playerPanelItemPressedOpacity
        } else if isEnabled, isHovering {
            opacity = Metrics.playerPanelItemHoverOpacity
        } else if shape == .tile {
            opacity = Metrics.playerPanelItemFillOpacity
        } else {
            opacity = isSelected ? Metrics.playerPanelRowSelectedOpacity : 0
        }
        return AnyShapeStyle(.white.opacity(opacity))
    }
}

// MARK: - 面板部件

/// 分组小标题,右边可带当前值
struct PlayerPanelHeader: View {
    let title: String
    var value: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: Metrics.spacingS)
            if let value {
                Text(value).monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metrics.spacingS)
        .padding(.top, Metrics.spacingXS)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 整行可点的选项 / 动作。选中项右侧打勾(颜色不是唯一表达),VoiceOver 读出选中态。
struct PlayerPanelRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    var isSelected = false
    /// 右侧的当前值(翻页入口用)
    var value: String?
    /// 点了进下一页:右侧画 `›`
    var opensPage = false
    var isDestructive = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    private var isRed: Bool { isDestructive && isEnabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.spacingS) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(isRed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .frame(width: Metrics.spacingL)
                }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isRed ? AnyShapeStyle(.red) : AnyShapeStyle(isEnabled ? .primary : .tertiary))
                if let detail {
                    PlayerPanelTag(text: detail)
                }
                Spacer(minLength: Metrics.spacingS)
                if let value {
                    Text(value)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                if opensPage {
                    Image(systemName: "chevron.right")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, Metrics.spacingS)
            .frame(maxWidth: .infinity, minHeight: Metrics.playerPanelRowHeight, alignment: .leading)
        }
        .buttonStyle(PlayerPanelButtonStyle(isSelected: isSelected))
        .help(detail.map { "\(title)  \($0)" } ?? title)
        .accessibilityValue(value ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 整行可点的开关,右侧开关只是状态指示
struct PlayerPanelToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var help: String?

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack {
                Text(title)
                Spacer()
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, Metrics.spacingS)
            .frame(maxWidth: .infinity, minHeight: Metrics.playerPanelRowHeight)
        }
        .buttonStyle(PlayerPanelButtonStyle())
        .help(help ?? title)
        .accessibilityRepresentation { Toggle(title, isOn: $isOn) }
    }
}

/// 二级页的页头:整行点回上一页
struct PlayerPanelBackHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        Button(action: back) {
            HStack(spacing: Metrics.spacingS) {
                Image(systemName: "chevron.left")
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, Metrics.spacingS)
            .frame(maxWidth: .infinity, minHeight: Metrics.playerPanelRowHeight)
        }
        .buttonStyle(PlayerPanelButtonStyle())
        .help("返回")
        .accessibilityLabel("返回")
        .accessibilityHint(title)
    }
}

/// 分组之间的细线(系统 `Divider` 压在视频上太亮)
struct PlayerPanelSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(Metrics.playerPanelItemHoverOpacity))
            .frame(height: Metrics.playerPanelSeparatorThickness)
            .padding(.horizontal, Metrics.spacingXS)
            .padding(.vertical, Metrics.spacingXXS)
            .accessibilityHidden(true)
    }
}

/// 轨道编码等附注
struct PlayerPanelTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.spacingXS)
            .padding(.vertical, Metrics.spacingXXS)
            .background(.white.opacity(Metrics.playerPanelItemHoverOpacity), in: .rect(cornerRadius: Radius.tag))
            // 标题长时让标题截断,标签留全
            .fixedSize()
    }
}

/// 一列行,超过 `playerPanelMaxVisibleRows` 行在面板内滚动。
/// 高度按行数算:⛔ 不把 `ScrollView` 丢进弹性容器(行少时撑出一片空白)。
struct PlayerPanelList<Content: View>: View {
    let rowCount: Int
    @ViewBuilder let content: Content

    var body: some View {
        let visible = min(rowCount, Metrics.playerPanelMaxVisibleRows)
        ScrollView {
            VStack(spacing: 0) { content }
        }
        .scrollIndicators(rowCount > visible ? .automatic : .never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: CGFloat(visible) * Metrics.playerPanelRowHeight)
    }
}

/// `[−] 当前值 [+] [↺]`。按住 ⇧ 点按走大步(与键盘 ⇧ 一致);没有大步的传 nil 的 `largeStepText`。
struct PlayerPanelStepper: View {
    let value: String
    /// 「提前」「减慢」这类方向词
    let decrementVerb: String
    let incrementVerb: String
    let stepText: String
    var largeStepText: String?
    var canDecrement = true
    var canIncrement = true
    var isResetDisabled = false
    var resetHelp = "重置"
    /// (加 / 减, 是否大步)
    let step: (_ up: Bool, _ large: Bool) -> Void
    var reset: (() -> Void)?

    var body: some View {
        HStack(spacing: Metrics.spacingXS) {
            stepButton(up: false)
                .disabled(!canDecrement)
            Text(value)
                .font(.body)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            stepButton(up: true)
                .disabled(!canIncrement)
            if let reset {
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: Metrics.playerPanelStepButtonWidth, height: Metrics.playerPanelChipHeight)
                }
                .buttonStyle(PlayerPanelButtonStyle(shape: .tile))
                .disabled(isResetDisabled)
                .help(resetHelp)
                .accessibilityLabel(resetHelp)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func stepButton(up: Bool) -> some View {
        let verb = up ? incrementVerb : decrementVerb
        let help = largeStepText.map { "\(verb) \(stepText)(按住 ⇧ 为 \($0))" } ?? "\(verb) \(stepText)"
        return Button {
            let large = largeStepText != nil && NSEvent.modifierFlags.contains(.shift)
            step(up, large)
        } label: {
            Image(systemName: up ? "plus" : "minus")
                .frame(width: Metrics.playerPanelStepButtonWidth, height: Metrics.playerPanelChipHeight)
        }
        .buttonStyle(PlayerPanelButtonStyle(shape: .tile))
        .help(help)
        .accessibilityLabel("\(verb) \(stepText)")
        .accessibilityValue(value)
    }
}

/// 图标 + 短文字的入口块,一排并列
struct PlayerPanelTile: View {
    let title: String
    let systemImage: String
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Metrics.spacingXXS) {
                Image(systemName: systemImage)
                    .font(.body)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.playerPanelTileHeight)
        }
        .buttonStyle(PlayerPanelButtonStyle(shape: .tile))
        .help(help ?? title)
    }
}

// MARK: - 倍速

/// 倍速:档位 + 滑块 + 微调。连续调节也靠 `[` `]`(`Metrics.speedKeyStep`)。
struct PlayerSpeedPanel: View {
    let viewModel: PlayerViewModel
    let dismiss: () -> Void

    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    private var current: Double { PlayerViewModel.clampedSpeed(viewModel.speed) }
    private var isNormal: Bool { abs(current - 1) < 0.001 }

    var body: some View {
        PlayerPanelChrome(title: "播放速度") {
            HStack(alignment: .firstTextBaseline) {
                Text(PlayerViewModel.speedText(current))
                    .font(.title2)
                    .monospacedDigit()
                Spacer()
                Button("恢复 1×") { viewModel.setSpeed(1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(isNormal ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .disabled(isNormal)
            }
            .padding(.horizontal, Metrics.spacingS)
            .padding(.vertical, Metrics.spacingXS)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.spacingXS), count: 3),
                spacing: Metrics.spacingXS
            ) {
                ForEach(PlayerViewModel.speedPresets, id: \.self) { preset in
                    let selected = abs(preset - current) < 0.001
                    Button { viewModel.setSpeed(preset) } label: {
                        Text(PlayerViewModel.speedText(preset))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: Metrics.playerPanelChipHeight)
                    }
                    .buttonStyle(PlayerPanelButtonStyle(shape: .tile, isSelected: selected))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            HStack(spacing: Metrics.spacingS) {
                stepButton(up: false)
                Slider(
                    value: Binding(get: { current }, set: { viewModel.setSpeed($0) }),
                    in: Metrics.speedRange,
                    step: Metrics.speedStep
                )
                .controlSize(.small)
                .accessibilityLabel("播放速度")
                .accessibilityValue(PlayerViewModel.speedText(current))
                stepButton(up: true)
            }
            .padding(.vertical, Metrics.spacingXS)

            PlayerPanelSeparator()

            PlayerPanelRow(title: "默认倍速…", systemImage: "gearshape") {
                dismiss()
                settingsTab = .playback
                openSettings()
            }
        }
    }

    private func stepButton(up: Bool) -> some View {
        let label = "\(up ? "加快" : "减慢") \(PlayerViewModel.speedText(Metrics.speedStep))"
        return Button {
            viewModel.stepSpeed(up: up, step: Metrics.speedStep)
        } label: {
            Image(systemName: up ? "plus" : "minus")
                .frame(width: Metrics.playerPanelStepButtonWidth, height: Metrics.playerPanelChipHeight)
        }
        .buttonStyle(PlayerPanelButtonStyle(shape: .tile))
        // 已经贴着区间端点:再点一步不会有变化
        .disabled(PlayerViewModel.steppedSpeed(from: viewModel.speed, up: up, step: Metrics.speedStep) == current)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - 字幕

/// 字幕:选轨 + 延迟 + 入口(本地 / 在线 / 外观)。外观在设置窗口「字幕」页。
///
/// ⛔ 入口不按「有没有字幕轨」禁用:「打开本地字幕」正是给没有字幕轨的片源用的。
struct PlayerSubtitlePanel: View {
    let viewModel: PlayerViewModel
    let dismiss: () -> Void
    // 文件面板与 sheet 挂在 `PlayerWindowView` 上:面板会先收起
    let openImporter: () -> Void
    let openSearch: () -> Void

    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    var body: some View {
        PlayerPanelChrome(title: "字幕") {
            PlayerPanelHeader(title: "字幕轨")
            if viewModel.subtitleTracks.isEmpty {
                Text("没有字幕轨")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Metrics.spacingS)
                    .frame(maxWidth: .infinity, minHeight: Metrics.playerPanelRowHeight, alignment: .leading)
            } else {
                PlayerPanelList(rowCount: viewModel.subtitleTracks.count + 1) {
                    PlayerPanelRow(title: "关闭", isSelected: viewModel.selectedSubtitleTrackID == nil) {
                        viewModel.selectSubtitleTrack(nil)
                    }
                    ForEach(viewModel.subtitleTracks) { track in
                        PlayerPanelRow(
                            title: track.displayName,
                            detail: track.detail,
                            isSelected: viewModel.selectedSubtitleTrackID == track.id
                        ) { viewModel.selectSubtitleTrack(track.id) }
                    }
                }
            }

            PlayerPanelSeparator()

            PlayerPanelHeader(title: "字幕延迟")
            PlayerPanelStepper(
                value: PlayerViewModel.subtitleDelayValueText(viewModel.subtitleDelay),
                decrementVerb: "提前",
                incrementVerb: "延后",
                stepText: Self.secondsText(Metrics.subtitleDelayStep),
                largeStepText: Self.secondsText(Metrics.subtitleDelayLargeStep),
                isResetDisabled: viewModel.subtitleDelay == 0,
                resetHelp: "重置字幕延迟",
                step: { up, large in
                    viewModel.stepSubtitleDelay(
                        later: up,
                        step: large ? Metrics.subtitleDelayLargeStep : Metrics.subtitleDelayStep)
                },
                reset: { viewModel.resetSubtitleDelay() }
            )
            .disabled(!viewModel.canAdjustSubtitleDelay)

            PlayerPanelSeparator()

            HStack(spacing: Metrics.spacingXS) {
                PlayerPanelTile(title: "本地", systemImage: "folder", help: "打开本地字幕…") {
                    dismiss()
                    openImporter()
                }
                PlayerPanelTile(title: "在线", systemImage: "magnifyingglass", help: "搜索在线字幕…") {
                    dismiss()
                    openSearch()
                }
                PlayerPanelTile(title: "外观", systemImage: "textformat", help: "字幕外观…") {
                    dismiss()
                    settingsTab = .subtitles
                    openSettings()
                }
            }
        }
    }

    static func secondsText(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)))) 秒"
    }
}

// MARK: - 音轨

/// 音轨:选轨 + 音频延迟。延迟放这里而不是单开一个按钮 —— 都是「听」的事,也免得控制栏挤。
struct PlayerAudioPanel: View {
    let viewModel: PlayerViewModel

    var body: some View {
        PlayerPanelChrome(title: "音轨") {
            PlayerPanelHeader(title: "音轨")
            PlayerPanelList(rowCount: viewModel.audioTracks.count) {
                ForEach(viewModel.audioTracks) { track in
                    PlayerPanelRow(
                        title: track.displayName,
                        detail: track.detail,
                        isSelected: viewModel.selectedAudioTrackID == track.id
                    ) { viewModel.selectAudioTrack(track.id) }
                }
            }

            PlayerPanelSeparator()

            PlayerPanelHeader(title: "音频延迟")
            PlayerPanelStepper(
                value: PlayerViewModel.audioDelayValueText(viewModel.audioDelay),
                decrementVerb: "音频提前",
                incrementVerb: "音频延后",
                stepText: PlayerSubtitlePanel.secondsText(Metrics.audioDelayStep),
                largeStepText: PlayerSubtitlePanel.secondsText(Metrics.audioDelayLargeStep),
                isResetDisabled: viewModel.audioDelay == 0,
                resetHelp: "重置音频延迟",
                step: { up, large in
                    viewModel.stepAudioDelay(
                        later: up,
                        step: large ? Metrics.audioDelayLargeStep : Metrics.audioDelayStep)
                },
                reset: { viewModel.resetAudioDelay() }
            )
            .disabled(!viewModel.canAdjustAudioDelay)
        }
    }
}
