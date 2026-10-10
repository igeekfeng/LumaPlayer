import SwiftUI

@main
@MainActor
struct LumaPlayerApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
        }
        .defaultSize(width: Metrics.mainWindowWidth, height: Metrics.mainWindowHeight)
        // `exp/avkit-rust-core`:`Playback` 菜单(`PlayerCommands`)随播放层一起摘掉了,
        // 它整个建在 `PlayerViewModel` 上。接 AVKit 时与播放页一起回来。

        // 播放器:单实例独立窗口(ARCHITECTURE.md 7.5)。内容由
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
