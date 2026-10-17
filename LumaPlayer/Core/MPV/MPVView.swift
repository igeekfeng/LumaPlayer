import AppKit
import OpenGL.GL3
import SwiftUI

// MARK: - CAOpenGLLayer 子层

/// 把 mpv 渲染上下文挂到 layer 的 CGL context 上,每帧把视频画到
/// layer 当前绑定的 framebuffer(draw 时查询 + FLIP_Y,render.h:200-208)。
///
/// ⚠️ 零 warning 策略:CAOpenGLLayer 自 macOS 10.14 废弃,本文件的
/// 废弃告警统一由构建设置 `OTHER_SWIFT_FLAGS` 注入的
/// `-DGL_SILENCE_DEPRECATION` 静默(CLAUDE.md「工程结构」),不在
/// 代码里加 @available 级联标注污染调用方。
final class MPVGLLayer: CAOpenGLLayer {

    /// weak:player 的生命周期由调用方(PlayerViewModel)持有,
    /// layer 不延长其存活。
    private weak var player: MPVPlayer?

    override init() {
        super.init()
        // 异步模式:CA 按 vsync 频率调 draw(主线程 runloop 定时器,不是独立渲染线程);draw 内轮询
        // mpv_render_context_update(),无新帧时直接返回。
        isAsynchronous = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isAsynchronous = true
    }

    func attach(player: MPVPlayer) {
        self.player = player
    }

    /// GL 3.2 core profile(mpv render API 要求 GL 2.1+ 或 3.2 core,
    /// render.h:184-187)。
    ///
    /// 注意:父类钩子的真实签名是 forDisplayMask:(CAOpenGLLayer.h
    /// copyCGLPixelFormatForDisplayMask:),与 copyCGLContext 的
    /// forPixelFormat: 不同。
    override func copyCGLPixelFormat(
        forDisplayMask mask: UInt32
    ) -> CGLPixelFormatObj {
        // CGLPixelFormatAttribute 枚举非连续(99 / 0x1000 / 0x3200 …),
        // Swift 导入为 struct;0 是属性数组终止符(CGLChoosePixelFormat 约定)。
        // kCGLOGLPVersion_GL3_Core 的类型是 CGLOpenGLProfile(同为 struct),
        // 需经 rawValue 换型。
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

    /// CGL context 就绪钩子:在这里挂 mpv 渲染上下文。
    /// 此后所有 mpv_render* 调用(包括 draw 里的 render)都要求
    /// 该 context 在调用线程 current(render.h 66-69)——draw 钩子由
    /// AppKit 保证 current,create 由 MPVPlayer.attachGLContext 自己切换。
    override func copyCGLContext(
        forPixelFormat pixelFormat: CGLPixelFormatObj
    ) -> CGLContextObj {
        let context = super.copyCGLContext(forPixelFormat: pixelFormat)
        player?.attachGLContext(context)
        return context
    }

    /// 没有活的渲染上下文就不画:CA 跳过这一帧、layer 保留上一次的画面
    /// (见 `MPVPlayer.canRender`)。播放器拆掉后画面因此定格在最后一帧而不是变黑 ——
    /// 换集 / 转码 seek / 重试就靠它不黑屏。
    override func canDraw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) -> Bool {
        player?.canRender ?? false
    }

    override func draw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) {
        // draw 时 ctx 已由 AppKit 设为 current(CAOpenGLLayer 契约)。
        // 尺寸取 CA 为本次 draw 设好的 viewport(= 实际 FBO 像素尺寸),不用
        // bounds × contentsScale 自己推:两者一旦对不上(缩放比刚变、缩放
        // 过程中),mpv 按错误尺寸排版,画面就会偏到一角或被裁切。
        // 与 mpv 自家 cocoa-cb 后端的做法一致。
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        player?.renderIntoBoundFramebuffer(width: Int(viewport[2]), height: Int(viewport[3]))
        super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    }
}

// MARK: - AppKit 承载视图

/// libmpv 视频的 AppKit 承载视图:NSView + MPVGLLayer。
/// 拆卸路径:viewDidMoveToWindow(nil) / dismantleNSView 双保险触发
/// player.shutdown()(可重入,MPVPlayer 保证幂等)。
/// player 先被别处 shutdown、视图还留在屏上时,画面定格在最后一帧(`canDraw`)。
final class MPVLayerView: NSView {

    let player: MPVPlayer
    private let glLayer = MPVGLLayer()

    /// 是否真正挂到过窗口上。
    ///
    /// AppKit 在「视图被加进一个本身还没归属窗口的父视图」时,同样会以
    /// `window == nil` 回调 `viewDidMoveToWindow`。不区分这两种 nil,
    /// 播放器就会在上屏之前被 shutdown 打到终态 destroyed——而 destroyed
    /// 不可复用(§8),窗口随后永久黑屏。只有「上过屏又离开」才算会话结束。
    private var hasEnteredWindow = false

    init(player: MPVPlayer) {
        self.player = player
        super.init(frame: .zero)
        glLayer.attach(player: player)
        // 尺寸变化(缩放窗口 / 全屏)立即重画,不等下一帧新画面
        glLayer.needsDisplayOnBoundsChange = true
        wantsLayer = true
    }

    /// 经 makeBackingLayer 交出 layer,视图保持 layer-backed:frame、
    /// 缩放与父 layer 坐标换算都由 AppKit 负责。
    ///
    /// 早期版本是 `wantsLayer = true` 后直接赋 `layer = glLayer`(那是
    /// layer-hosting 的写法),再在 `layout()` 里手动 `glLayer.frame = bounds`。
    /// 视图自己的 layer 的 frame 是**父 layer 坐标系**里的,bounds 的原点
    /// 恒为 0 —— 视图只要不在父视图原点(SwiftUI 的承载容器常常如此),
    /// 画面就被拽到父 layer 左下角,尺寸位置全错。
    override func makeBackingLayer() -> CALayer {
        glLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // 本视图只在代码里创建(播放窗口不走 nib)
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            hasEnteredWindow = true
            // backing 属性只有挂上 window 才拿得到
            glLayer.contentsScale = window.backingScaleFactor
        } else if hasEnteredWindow {
            // 上过屏又离开(窗口关闭 / SwiftUI 移除)= 播放会话结束
            player.shutdown()
        }
    }

    /// 窗口挪到缩放比不同的屏幕(Retina ↔ 外接 1x)时同步像素密度
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            glLayer.contentsScale = window.backingScaleFactor
        }
    }
}

// MARK: - SwiftUI 入口

/// libmpv 视频的 SwiftUI 承载(MPV_INTEGRATION.md §2 渲染路径)。
/// 图片之外的唯一例外:视频层不经过 SwiftUI 渲染管线,
/// 每帧绘制由 CAOpenGLLayer 的异步定时器驱动 —— 定时器挂在**主线程** runloop 上,
/// draw(含 `mpv_render_context_render`)也在主线程执行(2026-10-17 采样实测),渲染路径里不能阻塞。
struct MPVView: NSViewRepresentable {

    let player: MPVPlayer

    func makeNSView(context: Context) -> MPVLayerView {
        MPVLayerView(player: player)
    }

    func updateNSView(_ nsView: MPVLayerView, context: Context) {
        // player 是一次性绑定(一实例一 URL,§8),无需更新
    }

    static func dismantleNSView(_ nsView: MPVLayerView, coordinator: ()) {
        // 双保险:viewDidMoveToWindow(nil) 通常先到;shutdown 可重入
        nsView.player.shutdown()
    }
}
