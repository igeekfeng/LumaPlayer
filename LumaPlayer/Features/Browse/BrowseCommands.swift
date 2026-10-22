import SwiftUI

extension FocusedValues {
    /// 前台主窗口提供的动作。只有主窗口是 key window 时才有值,菜单据此启用 / 禁用。
    @Entry var browseActions: BrowseActions?
}

/// 主窗口交给菜单栏的动作与状态(由 `BrowseView` 经 `focusedSceneValue` 提供)。
struct BrowseActions {
    /// 有内容页正在加载 / 刷新(此时「Reload」禁用,口径同顶栏加载线)
    let isLoading: Bool
    let reload: @MainActor () -> Void
    /// 来源列表(菜单顺序 = 设置里的顺序,前 9 个配 ⌘1…⌘9)
    let sources: [SourceProfile]
    let currentSourceID: UUID?
    let switchTo: @MainActor (SourceProfile) -> Void
}

/// 菜单栏的主窗口命令:View →「Reload」(⌘R)与「Source」菜单(⌘1…⌘9 切换来源)。
/// 文案用英文,与系统菜单一致。
struct BrowseCommands: Commands {
    @FocusedValue(\.browseActions) private var actions

    private static let shortcutCount = 9

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Reload") { actions?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions == nil || actions?.isLoading == true)
            Divider()
        }

        CommandMenu("Source") {
            let sources = actions?.sources ?? []
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                Toggle(isOn: selectionBinding(for: source)) {
                    Text("\(source.displayName) · \(source.kindDescription)")
                }
                .keyboardShortcut(Self.shortcut(at: index))
            }
            if !sources.isEmpty {
                Divider()
            }
            SettingsLink {
                Text("Manage Sources…")
            }
        }
    }

    /// 勾选 = 当前来源;选中别的即切换(取消勾选当前来源没有意义,忽略)
    private func selectionBinding(for source: SourceProfile) -> Binding<Bool> {
        Binding(
            get: { actions?.currentSourceID == source.id },
            set: { isOn in
                guard isOn, actions?.currentSourceID != source.id else { return }
                actions?.switchTo(source)
            }
        )
    }

    private static func shortcut(at index: Int) -> KeyboardShortcut? {
        guard index < shortcutCount else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
    }
}
