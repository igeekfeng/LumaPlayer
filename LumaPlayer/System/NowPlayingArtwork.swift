import AppKit
import MediaPlayer

/// 系统「正在播放」封面的构造(控制中心 / 锁屏小组件用)。
///
/// ## 为什么只有这一个函数被留下来
///
/// 原来它在 `Features/Player/NowPlayingController.swift` 里。那个 controller
/// 整个建在 `PlayerViewModel` 上(`update(from:)` / 命令注册全都拿 ViewModel 当参数),
/// `exp/avkit-rust-core` 摘掉 libmpv 时随播放层一起删了;按落地清单它在 **P6**
/// 重建(目录见 `docs/DECISIONS/avkit-rust-rearchitecture.md` 第 7 节 `System/`)。
///
/// 唯独下面这个函数与 ViewModel 无关,而且它挡着的是一个**与内核无关、重建时
/// 必然再踩一次**的崩溃:
///
/// `requestHandler` 由 MediaPlayer 在它自己的 accessQueue 上调用,**不在主线程**。
/// 闭包若写在 `@MainActor` 类型的方法里会继承主线程隔离,被调时 Swift 运行时的
/// 隔离检查直接 trap(EXC_BREAKPOINT)—— 表现为「播放有剧照的分集时 App 崩溃」。
/// 所以它必须 `nonisolated`。
///
/// 回归覆盖:`LumaPlayerTests/NowPlayingArtworkTests`。
enum NowPlayingArtwork {
    nonisolated static func make(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
