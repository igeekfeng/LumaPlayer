import AppKit
import OpenGL.GL3
import SwiftUI

// MARK: - CAOpenGLLayer 子层

/// 把 mpv 渲染上下文挂到 layer 的 CGL context 上,每帧画到当前绑定的 framebuffer
/// (draw 时查询 + FLIP_Y,render.h:200-208)。
///
/// CAOpenGLLayer 的废弃告警由 `OTHER_SWIFT_FLAGS` 的 `-DGL_SILENCE_DEPRECATION` 静默,
/// ⛔ 不加 @available 级联标注。
final class MPVGLLayer: CAOpenGLLayer {

    /// weak:生命周期归 PlayerViewModel
    private weak var player: MPVPlayer?

    override init() {
        super.init()
        // CA 每个 vsync 在主线程问一次 canDraw,只有新帧 / 尺寸变了才 draw(`MPVPlayer.needsRender`)
        isAsynchronous = true
    }

    /// mpv 不知道 layer 变了,要主动请求重画;`needsDisplayOnBoundsChange` 过不了 `canDraw`。
    override var bounds: CGRect {
        didSet { if bounds.size != oldValue.size { player?.requestRender() } }
    }

    override var contentsScale: CGFloat {
        didSet { if contentsScale != oldValue { player?.requestRender() } }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isAsynchronous = true
    }

    func attach(player: MPVPlayer) {
        self.player = player
    }

    /// GL 3.2 core profile(render.h:184-187)。
    override func copyCGLPixelFormat(
        forDisplayMask mask: UInt32
    ) -> CGLPixelFormatObj {
        // 0 是属性数组终止符;`kCGLOGLPVersion_GL3_Core` 是 CGLOpenGLProfile,经 rawValue 换型
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile,
            CGLPixelFormatAttribute(kCGLOGLPVersion_GL3_Core.rawValue),
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0),
        ]
        var chosen: CGLPixelFormatObj?
        var count: GLint = 0
        let err = CGLChoosePixelFormat(attributes, &chosen, &count)
        guard err == kCGLNoError, let chosen else {
            // 选不出 core 就退回父类默认(legacy profile,mpv 也支持)
            return super.copyCGLPixelFormat(forDisplayMask: mask)
        }
        return chosen
    }

    /// 在这里挂 mpv 渲染上下文。所有 mpv_render* 调用都要求该 context 在调用线程 current
    /// (render.h 66-69):draw 由 AppKit 保证,create 由 `MPVPlayer.attachGLContext` 自己切。
    override func copyCGLContext(
        forPixelFormat pixelFormat: CGLPixelFormatObj
    ) -> CGLContextObj {
        let context = super.copyCGLContext(forPixelFormat: pixelFormat)
        player?.attachGLContext(context)
        return context
    }

    /// 没新东西就不画,layer 保留上一帧:播放中只按片源帧率画;播放器拆掉后画面定格
    /// 而不是变黑(换集 / 转码 seek / 重试靠它不黑屏)。
    override func canDraw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) -> Bool {
        player?.needsRender ?? false
    }

    override func draw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) {
        // 尺寸取 CA 设好的 viewport(= 实际 FBO 像素),⛔ 不用 bounds × contentsScale 推:
        // 缩放比变化时两者对不上,画面会偏到一角或被裁切(同 mpv cocoa-cb)。
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        player?.renderIntoBoundFramebuffer(width: Int(viewport[2]), height: Int(viewport[3]))
        super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    }
}

// MARK: - AppKit 承载视图

/// libmpv 视频的 AppKit 承载视图。viewDidMoveToWindow(nil) 与 dismantleNSView 双保险触发
/// `player.shutdown()`(幂等)。player 先被别处 shutdown 时画面定格在最后一帧。
final class MPVLayerView: NSView {

    let player: MPVPlayer
    private let glLayer = MPVGLLayer()

    /// 视图被加进还没归属窗口的父视图时,AppKit 也会以 `window == nil` 回调 `viewDidMoveToWindow`;
    /// 不区分的话播放器上屏前就被打到不可复用的 destroyed(§8),永久黑屏。只有上过屏又离开才算结束。
    private var hasEnteredWindow = false

    init(player: MPVPlayer) {
        self.player = player
        super.init(frame: .zero)
        glLayer.attach(player: player)
        glLayer.needsDisplayOnBoundsChange = true
        wantsLayer = true
    }

    /// ⛔ 必须经 makeBackingLayer 保持 layer-backed,不要直接赋 `layer`(layer-hosting)再手动设 frame:
    /// layer 的 frame 在父 layer 坐标系里,视图不在父视图原点时画面会被拽到左下角。
    override func makeBackingLayer() -> CALayer {
        glLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            hasEnteredWindow = true
            glLayer.contentsScale = window.backingScaleFactor
        } else if hasEnteredWindow {
            player.shutdown()
        }
    }

    /// Retina ↔ 外接 1x 屏幕之间移动时同步像素密度
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            glLayer.contentsScale = window.backingScaleFactor
        }
    }
}

// MARK: - SwiftUI 入口

/// libmpv 视频的 SwiftUI 承载(MPV_INTEGRATION.md §2)。视频层不经 SwiftUI 渲染管线;
/// CAOpenGLLayer 的定时器与 draw(含 `mpv_render_context_render`)都在主线程,渲染路径里不能阻塞。
struct MPVView: NSViewRepresentable {

    let player: MPVPlayer

    func makeNSView(context: Context) -> MPVLayerView {
        MPVLayerView(player: player)
    }

    func updateNSView(_ nsView: MPVLayerView, context: Context) {
        // 一实例一 URL(§8),无需更新
    }

    static func dismantleNSView(_ nsView: MPVLayerView, coordinator: ()) {
        nsView.player.shutdown()
    }
}
