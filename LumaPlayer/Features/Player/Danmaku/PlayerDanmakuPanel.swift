import SwiftUI

/// 控制栏的「弹幕」面板(形态见 `PlayerPanelKind`)。手动选择只放入口,表单由播放窗口以 sheet 呈现
/// (`DanmakuPickerSheet`)。
struct PlayerDanmakuPanel: View {
    let viewModel: PlayerViewModel
    let dismiss: () -> Void
    let openPicker: () -> Void

    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    private var danmaku: DanmakuController { viewModel.danmaku }

    var body: some View {
        PlayerPanelChrome(title: "弹幕") {
            PlayerPanelToggleRow(
                title: "显示弹幕",
                isOn: Binding(get: { danmaku.isVisible }, set: { danmaku.setVisible($0) }),
                help: "显示弹幕(D)")

            Text(Self.statusText(danmaku.status))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.spacingS)
                .padding(.vertical, Metrics.spacingXS)

            if case .failed(_, let needsCredentials) = danmaku.status, needsCredentials {
                PlayerPanelRow(title: "填写弹弹play 凭据…", systemImage: "key") { openDanmakuSettings() }
            } else if case .failed = danmaku.status {
                PlayerPanelRow(title: "重试", systemImage: "arrow.clockwise") { danmaku.reload() }
            }
            PlayerPanelRow(title: "选择弹幕…", systemImage: "list.bullet") {
                dismiss()
                openPicker()
            }

            PlayerPanelSeparator()

            PlayerPanelHeader(title: "弹幕偏移")
            PlayerPanelStepper(
                value: Self.offsetText(danmaku.userOffset),
                decrementVerb: "提前",
                incrementVerb: "延后",
                stepText: PlayerSubtitlePanel.secondsText(Self.offsetStep),
                isResetDisabled: danmaku.userOffset == 0,
                resetHelp: "重置偏移",
                step: { up, _ in danmaku.userOffset += up ? Self.offsetStep : -Self.offsetStep },
                reset: { danmaku.userOffset = 0 }
            )
            .disabled(danmaku.loaded == nil)

            PlayerPanelSeparator()

            PlayerPanelRow(title: "弹幕外观与凭据…", systemImage: "gearshape") { openDanmakuSettings() }
        }
    }

    private func openDanmakuSettings() {
        dismiss()
        settingsTab = .danmaku
        openSettings()
    }

    static let offsetStep = 0.5

    static func offsetText(_ offset: Double) -> String {
        offset == 0 ? "无" : String(format: "%+.1f 秒", offset)
    }

    static func statusText(_ status: DanmakuController.Status) -> String {
        switch status {
        case .off: return "弹幕未开启"
        case .loading: return "正在加载弹幕…"
        case .loaded(let count, let dropped, let title):
            let droppedText = dropped > 0 ? "(\(dropped) 条无法解析已略过)" : ""
            return "\(title):\(count) 条\(droppedText)"
        case .needsSelection(let candidates):
            return candidates.isEmpty ? "没有自动匹配到弹幕" : "匹配到 \(candidates.count) 个可能的弹幕库,请选择"
        case .failed(let message, _):
            return message
        }
    }
}
