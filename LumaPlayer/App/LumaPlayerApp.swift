import SwiftUI

@main
@MainActor
struct LumaPlayerApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
        }
        // 无标题栏:返回 / 搜索画在浮动顶栏上(`BrowseChromeBar.swift`)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: Metrics.mainWindowWidth, height: Metrics.mainWindowHeight)
        .commands {
            BrowseCommands()
            PlayerCommands()
        }

        // 播放器单实例窗口,内容由 `AppState.nowPlaying` 决定;不恢复(重启后没有播放请求,只会是空窗)
        Window("播放", id: PlayerSceneRoot.windowID) {
            PlayerSceneRoot(container: container)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        .restorationBehavior(.disabled)
        // 不进「窗口」菜单:没有播放请求时打开它没意义
        .commandsRemoved()

        Settings {
            AppSettingsView(container: container)
        }
    }
}
