import SwiftUI

/// 播放器窗口的根视图(独立窗口,ARCHITECTURE.md 7.5)。
///
/// ## ⚠️ 这是 `exp/avkit-rust-core` 分支上的**占位实现**
///
/// 这一支把播放内核从 libmpv 换成 AVKit。原实现(`PlayerWindowView` /
/// `PlayerViewModel` / `PlayerControlsView` / `NowPlayingController`)全部建在
/// `MPVPlayer` 上,换内核期间无法编译,已随 `Core/MPV/` 一起删除。
///
/// 但**保留这个场景**是刻意的,有两个具体目的:
///
/// 1. 4 个 `openWindow(id: PlayerSceneRoot.windowID)` 调用点
///    (首页 / 媒体库 / 搜索 / 详情页)**一行都不用改**;
/// 2. 窗口的单实例语义(内容由 `AppState.nowPlaying` 决定)与
///    「没有请求就关窗」的行为留在原处 —— 接 AVKit 时只换 `body`,
///    不用回来重新推导这两条。
///
/// 决策与后续计划见 `docs/DECISIONS/avkit-rust-rearchitecture.md`。
struct PlayerSceneRoot: View {
    static let windowID = "player"

    let container: AppContainer
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        placeholder
            // 只在「有请求 → 无请求」的跳变上关窗,不能挂在占位视图的 onAppear 上:
            // 用户关窗时 tearDown 把请求清空,但窗口已关、这次更新没渲染出来;
            // 下次 openWindow 时 SwiftUI 补上积压的 onAppear,刚打开的窗口立刻被关掉,
            // 新请求也随 tearDown 一起清空 —— 表现为再点播放没反应(本机最小复现实测)。
            .onChange(of: container.state.nowPlaying?.id) { old, new in
                if old != nil, new == nil { dismissWindow(id: Self.windowID) }
            }
            // 深色环境:视频背景亮度不可控,玻璃与文字按深色外观取色才稳定可读(UI_DESIGN.md 8.1)
            .environment(\.colorScheme, .dark)
    }

    /// 占位内容:说明「这一支还没接播放层」,并把请求里的项名显示出来 ——
    /// 好让手工验收时能确认请求确实送到了窗口(而不是点了没反应)。
    private var placeholder: some View {
        ZStack {
            Color.black
            VStack(spacing: Metrics.spacingL) {
                Image(systemName: "play.slash")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
                Text("此分支尚未接入播放层")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("exp/avkit-rust-core 正在把播放内核从 libmpv 换成 AVKit。\n媒体库浏览、刮削与网络层不受影响。")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                if let request = container.state.nowPlaying {
                    Text("已收到播放请求:\(request.item.name)")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, Metrics.spacingS)
                }
            }
            .padding(Metrics.spacingXL)
        }
        .frame(minWidth: 640, minHeight: 360)
    }
}
