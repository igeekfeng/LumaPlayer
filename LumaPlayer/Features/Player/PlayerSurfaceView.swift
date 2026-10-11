import AppKit
import SwiftUI

/// 视频承载视图:把引擎提供的原生视图(SDK 自己的 Metal 图层视图)交给 SwiftUI。
///
/// 视图层**不 import 内核**:`PlaybackEngine.makeVideoSurface()` 返回的就是
/// 现成的 `NSView`,渲染循环由 SDK 视图自己驱动(不需要宿主等「渲染上下文挂好」)。
///
/// 拆卸:本视图只负责把原生视图移出层级;**不关引擎** —— 播放会话的收尾
/// (最终上报 + `engine.close()`)统一由 `PlayerViewModel.stop()` 负责,
/// 避免视图拆卸与播放状态机互相打架。
struct PlayerSurfaceView: NSViewRepresentable {

    let engine: any PlaybackEngine

    func makeNSView(context: Context) -> NSView {
        engine.makeVideoSurface()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 引擎与视图是一次性绑定(一个引擎一个表面),无需更新
    }
}
