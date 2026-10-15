import SwiftUI

extension FocusedValues {
    /// 当前处于前台的主窗口提供的动作。只有主窗口是 key window 时才有值,
    /// 菜单项据此启用 / 禁用 —— 播放器窗口在前台时 ⌘R 不会去刷新背后的页面。
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

/// 菜单栏的主窗口命令:View →「Reload」(⌘R),以及「Source」菜单(⌘1…⌘9 切换来源)。
///
/// 主窗口没有系统工具栏(`BrowseChromeBar.swift`):刷新不再是常驻按钮,走这里;
/// 来源在顶栏也有一个图标按钮,这里给键盘入口。
/// 文案用英文,与 `PlayerCommands` 同一理由(系统菜单都是英文,菜单栏不中英混排)。
struct BrowseCommands: Commands {
    @FocusedValue(\.browseActions) private var actions

    /// 配快捷键的来源个数(⌘1…⌘9)
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
            // 来源管理(增 / 改 / 删 / 登录)在设置窗口的「来源」标签页
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
