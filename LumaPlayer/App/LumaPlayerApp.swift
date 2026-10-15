import SwiftUI

@main
@MainActor
struct LumaPlayerApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
        }
        // 主窗口没有标题栏与系统工具栏:内容铺到最上沿,返回 / 搜索等画在浮动顶栏上
        // (`BrowseChromeBar.swift`,DesignTokens.swift「界面规则」)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: Metrics.mainWindowWidth, height: Metrics.mainWindowHeight)
        .commands { PlayerCommands() }

        // 播放器:单实例独立窗口(CLAUDE.md「架构主线」)。内容由
        // `AppState.nowPlaying` 决定;不参与窗口恢复 —— 重启后没有播放请求,
        // 恢复出来也只会是一个空窗口。
        Window("播放", id: PlayerSceneRoot.windowID) {
            PlayerSceneRoot(container: container)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        .restorationBehavior(.disabled)
        // 不在「窗口」菜单里放一个「播放」入口:没有播放请求时打开它毫无意义
        .commandsRemoved()

        Settings {
            AppSettingsView(container: container)
        }
    }
}
