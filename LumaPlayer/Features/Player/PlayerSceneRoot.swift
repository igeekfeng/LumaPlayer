import SwiftUI

/// 播放器窗口的根视图(独立窗口,ARCHITECTURE.md 7.5)。
///
/// 窗口是单实例的:内容由 `AppState.nowPlaying` 决定,换请求就按新 `id`
/// 重建播放页(旧的随 `onDisappear` 走完收尾上报)。没有请求时关窗 ——
/// 切换 / 删除服务器会清空请求(UI_DESIGN.md 7.1)。
///
/// ⚠️ `exp/avkit-rust-core` 上这里曾是**占位实现**(换内核期间播放层整个删了,
/// 先把场景与单实例语义留住)。P3c 起 `body` 换成真的 `PlayerWindowView` ——
/// 4 个 `openWindow(id: PlayerSceneRoot.windowID)` 调用点一行都没改。
struct PlayerSceneRoot: View {
    static let windowID = "player"

    let container: AppContainer
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let request = container.state.nowPlaying {
                PlayerWindowView(container: container, request: request)
                    .id(request.id)
            } else {
                Color.black
            }
        }
        // 只在「有请求 → 无请求」的跳变上关窗,不能挂在 Color.black 的 onAppear 上:
        // 用户关窗时 tearDown 把请求清空,但窗口已关、这次更新没渲染出来;
        // 下次 openWindow 时 SwiftUI 补上积压的 onAppear,刚打开的窗口立刻被关掉,
        // 新请求也随 tearDown 一起清空 —— 表现为再点播放没反应(本机最小复现实测)。
        .onChange(of: container.state.nowPlaying?.id) { old, new in
            if old != nil, new == nil { dismissWindow(id: Self.windowID) }
        }
        // 深色环境:视频背景亮度不可控,玻璃与文字按深色外观取色才稳定可读(UI_DESIGN.md 8.1)
        .environment(\.colorScheme, .dark)
    }
}
