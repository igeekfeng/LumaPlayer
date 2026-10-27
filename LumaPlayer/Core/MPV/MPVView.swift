import AppKit
import OpenGL.GL3
import SwiftUI
import Synchronization

// MARK: - CAOpenGLLayer 子层

/// 把 mpv 渲染上下文挂到 layer 的 CGL context 上,每帧画到当前绑定的 framebuffer
/// (draw 时查询 + FLIP_Y,render.h:200-208)。
///
/// 出帧在专用串行队列上(MPV_INTEGRATION.md §2):mpv 的 update 回调 → `scheduleDisplay()` → 队列上 `display()`。
/// 主线程只在 CA 自己要画时(尺寸 / 缩放比变化,`needsDisplayOnBoundsChange`)同步画一次,
/// 与窗口缩放同一个事务,画面不拉伸。⛔ 不开 `isAsynchronous`:那是主线程定时器驱动、draw 在主线程。
///
/// `@unchecked Sendable`:render 队列、主线程(CA 触发的 display、displayLink)共用本对象。
/// 可变状态都是原子量或 `Synchronization.Mutex`;`display()` 由 `displayLock` 串行;`player` 是 weak let。
/// 非主线程 display 包在显式 CATransaction 里(见 `display()`)。
///
/// CAOpenGLLayer 的废弃告警由 `OTHER_SWIFT_FLAGS` 的 `-DGL_SILENCE_DEPRECATION` 静默,
/// ⛔ 不加 @available 级联标注。
final class MPVGLLayer: CAOpenGLLayer, @unchecked Sendable {

    /// weak:生命周期归 PlayerViewModel
    private weak let player: MPVPlayer?

    private let renderQueue = DispatchQueue(label: "com.local.LumaPlayer.mpv-render", qos: .userInteractive)

    /// 主线程与 render 队列的 display 互斥。递归:CA 在 display 内部的事务提交可能再进 display。
    private let displayLock = NSRecursiveLock()

    /// 已有一个 display 排在队列上:mpv 连发通知时只排一个
    private let displayScheduled = Atomic<Bool>(false)

    /// 本次 display 里 CA 有没有问过 `canDraw`。没问 = CA 整个跳过了这一帧(窗口不可见)
    private let canDrawAsked = Atomic<Bool>(false)

    /// 自 displayLink 上次取走以来画过或跳过帧(`takeRenderActivity`)
    private let renderActivity = Atomic<Bool>(false)
    /// displayLink 因空闲停下了;出帧时由这里叫醒(`displayLinkWake`)
    private let displayLinkIdle = Atomic<Bool>(false)
    private let displayLinkWake = Synchronization.Mutex<(@MainActor @Sendable () -> Void)?>(nil)

    init(player: MPVPlayer) {
        self.player = player
        super.init()
        isAsynchronous = false
        player.setFrameReadyHandler { [weak self] in self?.scheduleDisplay() }
    }

    /// CA 复制图层(如 contentsScale 变化)时调用
    override init(layer: Any) {
        player = (layer as? MPVGLLayer)?.player
        super.init(layer: layer)
        isAsynchronous = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// mpv 不知道 layer 变了,要主动请求重画;`needsDisplayOnBoundsChange` 只负责让 CA 来问 `canDraw`。
    override var bounds: CGRect {
        didSet { if bounds.size != oldValue.size { player?.requestRender() } }
    }

    override var contentsScale: CGFloat {
        didSet {
            if contentsScale != oldValue {
                player?.requestRender()
                setNeedsDisplay()
            }
        }
    }

    /// 在 render 队列上排一次 display。任意线程可调(mpv 的 update 回调里也调)。
    func scheduleDisplay() {
        guard !displayScheduled.exchange(true, ordering: .acquiringAndReleasing) else { return }
        renderQueue.async { [self] in
            // 先清标志再画:画的过程中 mpv 送来的下一帧会再排一次
            displayScheduled.store(false, ordering: .releasing)
            display()
        }
    }

    override func display() {
        displayLock.lock()
        defer { displayLock.unlock() }
        canDrawAsked.store(false, ordering: .relaxed)
        if Thread.isMainThread {
            super.display()
            return
        }
        // 非主线程必须用显式事务,否则开了 CA_ASSERT_MAIN_THREAD_TRANSACTIONS 会因隐式事务崩溃;
        // flush 是因为这个事务可能嵌在一个隐式事务里,commit 不会把它送上屏(IINA #5038 / #5029)。
        CATransaction.begin()
        super.display()
        CATransaction.commit()
        CATransaction.flush()
        if !canDrawAsked.load(ordering: .relaxed), let player, player.needsRender {
            player.skipPendingFrame()
            noteRenderActivity()
        }
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
    /// (render.h 66-69):draw 由 CA 保证,create 由 `MPVPlayer.attachGLContext` 自己切。
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
        canDrawAsked.store(true, ordering: .relaxed)
        return player?.needsRender ?? false
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
        noteRenderActivity()
    }

    // MARK: displayLink 启停(`MPVLayerView.displayLinkFired`)

    func setDisplayLinkWake(_ wake: (@MainActor @Sendable () -> Void)?) {
        displayLinkWake.withLock { $0 = wake }
    }

    /// 出了帧:displayLink 若已空闲停下就叫醒它,VO 正等着下一次 swap
    private func noteRenderActivity() {
        renderActivity.store(true, ordering: .releasing)
        guard displayLinkIdle.exchange(false, ordering: .acquiringAndReleasing) else { return }
        let wake = displayLinkWake.withLock { $0 }
        Task { @MainActor in wake?() }
    }

    /// 自上次调用以来有没有出帧(并清掉)
    func takeRenderActivity() -> Bool {
        renderActivity.exchange(false, ordering: .acquiringAndReleasing)
    }

    /// displayLink 要停了。返回 false = 刚好又出了帧,别停。
    func displayLinkWillIdle() -> Bool {
        displayLinkIdle.store(true, ordering: .releasing)
        guard renderActivity.load(ordering: .acquiring) else { return true }
        // 置位前后之间出的帧没看到 idle,不会来叫醒;这里自己撤回
        return !displayLinkIdle.exchange(false, ordering: .acquiringAndReleasing)
    }
}

// MARK: - AppKit 承载视图

/// libmpv 视频的 AppKit 承载视图。viewDidMoveToWindow(nil) 与 dismantleNSView 双保险触发
/// `player.shutdown()`(幂等)。player 先被别处 shutdown 时画面定格在最后一帧。
///
/// 持一个 displayLink,每个 vsync 调 `player.reportSwap()`(MPV_INTEGRATION.md §2)。
/// 连续 `displayLinkIdleDelay` 秒没出帧(暂停、播放器已拆)就停,layer 出帧时叫醒。
final class MPVLayerView: NSView {

    let player: MPVPlayer
    private let glLayer: MPVGLLayer

    /// 视图被加进还没归属窗口的父视图时,AppKit 也会以 `window == nil` 回调 `viewDidMoveToWindow`;
    /// 不区分的话播放器上屏前就被打到不可复用的 destroyed(§8),永久黑屏。只有上过屏又离开才算结束。
    private var hasEnteredWindow = false

    private var displayLink: CADisplayLink?
    /// 最近一次出帧时的 displayLink 时间戳
    private var lastRenderActivity: CFTimeInterval = 0
    private static let displayLinkIdleDelay: CFTimeInterval = 1

    init(player: MPVPlayer) {
        self.player = player
        glLayer = MPVGLLayer(player: player)
        super.init(frame: .zero)
        glLayer.needsDisplayOnBoundsChange = true
        wantsLayer = true
        glLayer.setDisplayLinkWake { [weak self] in self?.resumeDisplayLink() }
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
            startDisplayLink()
            // 不开 isAsynchronous 后 CA 不会自己来画:第一次 display 才挂 GL(copyCGLContext)
            glLayer.setNeedsDisplay()
        } else {
            stopDisplayLink()
            if hasEnteredWindow { player.shutdown() }
        }
    }

    /// Retina ↔ 外接 1x 屏幕之间移动时同步像素密度
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            glLayer.contentsScale = window.backingScaleFactor
        }
        updatePreferredFrameRate()
    }

    private func startDisplayLink() {
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            // common 模式:拖窗口 / 菜单展开时也照常报 swap,否则 VO 每帧等满 200 ms
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        resumeDisplayLink()
        updatePreferredFrameRate()
    }

    /// displayLink 强引用 target,视图离开窗口 / 被 SwiftUI 拆掉时必须 invalidate
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func resumeDisplayLink() {
        guard let displayLink else { return }
        lastRenderActivity = CACurrentMediaTime()
        displayLink.isPaused = false
    }

    /// 报 swap 要跟屏幕真实刷新率一致(ProMotion 屏最高 120 Hz)
    private func updatePreferredFrameRate() {
        guard let displayLink, let fps = window?.screen?.maximumFramesPerSecond, fps > 0 else { return }
        let rate = Float(fps)
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        player.reportSwap()
        if glLayer.takeRenderActivity() {
            lastRenderActivity = link.timestamp
            return
        }
        guard link.timestamp - lastRenderActivity > Self.displayLinkIdleDelay else { return }
        if glLayer.displayLinkWillIdle() {
            link.isPaused = true
        }
    }
}

// MARK: - SwiftUI 入口

/// libmpv 视频的 SwiftUI 承载(MPV_INTEGRATION.md §2)。视频层不经 SwiftUI 渲染管线;
/// 出帧在 `MPVGLLayer` 的 render 队列上,只有改尺寸时的那一次 draw 在主线程。
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
