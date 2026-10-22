import SwiftUI

/// 控制栏的「弹幕」菜单。菜单里放不了输入控件,手动选择只放入口,表单由播放窗口以 sheet 呈现
/// (`DanmakuPickerSheet`)。
struct PlayerDanmakuMenu: View {
    let viewModel: PlayerViewModel
    @Binding var isPickerPresented: Bool

    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    private var danmaku: DanmakuController { viewModel.danmaku }

    var body: some View {
        Menu {
            Toggle("显示弹幕", isOn: Binding(
                get: { danmaku.isVisible },
                set: { danmaku.setVisible($0) }
            ))

            Section(Self.statusText(danmaku.status)) {
                if case .failed(_, let needsCredentials) = danmaku.status, needsCredentials {
                    Button("填写弹弹play 凭据…") { openDanmakuSettings() }
                } else if case .failed = danmaku.status {
                    Button("重试") { danmaku.reload() }
                }
                Button("选择弹幕…") { isPickerPresented = true }
            }

            Section("弹幕偏移:\(Self.offsetText(danmaku.userOffset))") {
                Button("提前 0.5 秒") { danmaku.userOffset -= Self.offsetStep }
                Button("延后 0.5 秒") { danmaku.userOffset += Self.offsetStep }
                Button("重置偏移") { danmaku.userOffset = 0 }
                    .disabled(danmaku.userOffset == 0)
            }
            .disabled(danmaku.loaded == nil)

            Divider()

            Button("弹幕外观与凭据…") { openDanmakuSettings() }
        } label: {
            Image(systemName: danmaku.isVisible ? "text.bubble.fill" : "text.bubble")
                .font(.title3)
                .frame(width: Metrics.playerButtonSize, height: Metrics.playerButtonSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("弹幕")
        .accessibilityLabel("弹幕")
    }

    private func openDanmakuSettings() {
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
