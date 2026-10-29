import AppKit
import QuartzCore
import SwiftUI

/// 弹幕渲染层:叠在视频上、控制层下,⛔ 不接收点击。
///
/// ⛔ 不交给 mpv(ASS):改外观要重载字幕轨,还会占掉用户的字幕轨(`docs/DANMAKU.md` §4)。
///
/// ⛔ 不用 SwiftUI `Canvas` 每帧重画(主线程光栅化,120 Hz 屏上掉到约 40 帧)。
/// 每条出场时预渲染位图(`DanmakuSprite`),每帧只改图层位置,按 displayLink 的 `targetTimestamp` 算。
///
/// `positionSeconds` 只有 5 Hz,由 `DanmakuClock` 外推。暂停时时间轴与 displayLink 都停。
struct DanmakuOverlayView: View {
    let controller: DanmakuController
    let settings: DanmakuDisplaySettings
    let positionSeconds: Double
    let isPaused: Bool
    let speed: Double

    var body: some View {
        if controller.isVisible, controller.loaded != nil {
            DanmakuLayerRepresentable(
                controller: controller, settings: settings,
                positionSeconds: positionSeconds, isPaused: isPaused, speed: speed)
        }
    }
}

private struct DanmakuLayerRepresentable: NSViewRepresentable {
    let controller: DanmakuController
    let settings: DanmakuDisplaySettings
    let positionSeconds: Double
    let isPaused: Bool
    let speed: Double

    func makeNSView(context: Context) -> DanmakuLayerView {
        DanmakuLayerView(controller: controller)
    }

    func updateNSView(_ view: DanmakuLayerView, context: Context) {
        view.update(
            controller: controller, settings: settings,
            position: positionSeconds, isPaused: isPaused, speed: speed)
    }

    static func dismantleNSView(_ view: DanmakuLayerView, coordinator: ()) {
        view.stopDisplayLink()
    }
}

/// 容器层 + 每条在场弹幕一个子层。子层按排版下标缓存;`layoutGeneration` 或像素密度变了整批重建。
final class DanmakuLayerView: NSView {

    /// `settings.fontSize` 以 1080 高的画面为基准
    private static let referenceHeight: CGFloat = 1080
    private static let minimumFontSize: CGFloat = 12
    private static let poolLimit = 128

    private var controller: DanmakuController
    private var settings = DanmakuDisplaySettings.default
    private var isPaused = true
    private var lastClockInput: (position: Double, isPaused: Bool, speed: Double)?

    private let clock = DanmakuClock()
    private let container = CALayer()
    private var sprites: [Int: DanmakuSpriteLayer] = [:]
    private var pool: [DanmakuSpriteLayer] = []
    private var spriteGeneration: Int?
    private var scale: CGFloat = 2
    private var displayLink: CADisplayLink?

    init(controller: DanmakuController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        container.anchorPoint = .zero
        container.masksToBounds = true
        layer?.addSublayer(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 自上而下排版,与 `DanmakuLayout` 的行号方向一致
    override var isFlipped: Bool { true }

    /// 双保险,挂载处另有 `allowsHitTesting(false)`
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - 输入

    func update(
        controller: DanmakuController, settings: DanmakuDisplaySettings,
        position: Double, isPaused: Bool, speed: Double
    ) {
        if controller !== self.controller {
            self.controller = controller
            removeAllSprites()
        }
        self.settings = settings
        self.isPaused = isPaused
        container.opacity = Float(settings.opacity)

        // 只在三项真变了时同步时钟:父视图因别的原因刷新时位置是旧值,会把时钟往回拽
        let clockInput = (position: position, isPaused: isPaused, speed: speed)
        if lastClockInput.map({ $0 != clockInput }) ?? true {
            clock.update(position: position, isPaused: isPaused, speed: speed, now: CACurrentMediaTime())
            lastClockInput = clockInput
        }
        displayLink?.isPaused = isPaused
        // 暂停时没有逐帧刷新,手动画一帧
        if isPaused { renderFrame(at: CACurrentMediaTime()) }
    }

    // MARK: - 视图生命周期

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            stopDisplayLink()
            return
        }
        applyBackingScale(window.backingScaleFactor)
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            // common 模式:拖窗口 / 菜单展开时也照常刷新
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = isPaused
        updatePreferredFrameRate()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window { applyBackingScale(window.backingScaleFactor) }
        updatePreferredFrameRate()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        CATransaction.commit()
        if isPaused { renderFrame(at: CACurrentMediaTime()) }
    }

    /// displayLink 强引用 target,视图离开窗口 / 被 SwiftUI 拆掉时必须 invalidate
    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func applyBackingScale(_ newScale: CGFloat) {
        guard newScale > 0, newScale != scale else { return }
        scale = newScale
        removeAllSprites()
    }

    /// 跑满屏幕最高刷新率(系统按功耗策略可能再降)
    private func updatePreferredFrameRate() {
        guard let displayLink, let fps = window?.screen?.maximumFramesPerSecond, fps > 0 else { return }
        let rate = Float(fps)
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
    }

    // MARK: - 逐帧

    @objc private func step(_ link: CADisplayLink) {
        renderFrame(at: link.targetTimestamp)
    }

    /// `hostTime` 与 `CACurrentMediaTime` 同基。
    private func renderFrame(at hostTime: Double) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let fontSize = max(Self.minimumFontSize, CGFloat(settings.fontSize) * size.height / Self.referenceHeight)
        let parameters = DanmakuLayout.Parameters(
            viewportWidth: size.width.rounded(),
            viewportHeight: size.height.rounded(),
            fontSize: fontSize.rounded(),
            scrollDuration: settings.scrollDuration,
            displayArea: settings.displayArea,
            showsScroll: settings.showsScroll,
            showsTop: settings.showsTop,
            showsBottom: settings.showsBottom)
        let (placed, maxLifetime) = controller.placement(for: parameters)
        if spriteGeneration != controller.layoutGeneration {
            removeAllSprites()
            spriteGeneration = controller.layoutGeneration
        }

        let time = clock.time(at: hostTime) - controller.shift
        let lineHeight = parameters.lineHeight
        let velocity = Double(parameters.velocity)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var live = Set<Int>()
        let visible = DanmakuLayout.visible(in: placed, at: time, maxLifetime: maxLifetime)
        for index in visible.indices where placed[index].end > time {
            let item = placed[index]
            guard let sprite = sprites[index] ?? makeSprite(for: item, parameters: parameters) else { continue }
            sprites[index] = sprite
            live.insert(index)

            // 行框左上角(pt,自上而下)
            let x: CGFloat
            let top: CGFloat
            switch item.comment.mode {
            case .scroll:
                x = parameters.viewportWidth - CGFloat((time - item.start) * velocity)
                top = CGFloat(item.lane) * lineHeight
            case .top:
                x = (parameters.viewportWidth - item.width) / 2
                top = CGFloat(item.lane) * lineHeight
            case .bottom:
                x = (parameters.viewportWidth - item.width) / 2
                top = parameters.viewportHeight - CGFloat(item.lane + 1) * lineHeight
            }
            sprite.position = CGPoint(
                x: DanmakuSprite.aligned(x - sprite.margin, scale: scale),
                y: DanmakuSprite.aligned(top - sprite.margin, scale: scale))
        }

        for index in sprites.keys where !live.contains(index) {
            if let sprite = sprites.removeValue(forKey: index) { recycle(sprite) }
        }
    }

    // MARK: - 图层

    private func makeSprite(for item: PlacedDanmaku, parameters: DanmakuLayout.Parameters) -> DanmakuSpriteLayer? {
        guard let rendered = DanmakuSprite.render(
            text: item.comment.text, color: item.comment.color,
            fontSize: parameters.fontSize, lineHeight: parameters.lineHeight, scale: scale)
        else { return nil }
        let sprite = pool.popLast() ?? DanmakuSpriteLayer()
        sprite.contents = rendered.image
        sprite.contentsScale = scale
        sprite.bounds = CGRect(origin: .zero, size: rendered.size)
        sprite.margin = rendered.margin
        container.addSublayer(sprite)
        return sprite
    }

    private func recycle(_ sprite: DanmakuSpriteLayer) {
        sprite.removeFromSuperlayer()
        sprite.contents = nil
        if pool.count < Self.poolLimit { pool.append(sprite) }
    }

    private func removeAllSprites() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sprite in sprites.values { recycle(sprite) }
        sprites.removeAll()
        CATransaction.commit()
        spriteGeneration = nil
    }
}

/// `margin`:位图四周给描边留的白(pt),摆放时把行框原点换算成位图原点。
private final class DanmakuSpriteLayer: CALayer {
    var margin: CGFloat = 0

    override init() {
        super.init()
        anchorPoint = .zero
    }

    /// Core Animation 复制表现层时调用
    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? DanmakuSpriteLayer { margin = other.margin }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 弹幕时间轴时钟:两次播放位置更新之间按倍速外推。时间基是 `CACurrentMediaTime`(秒)。
///
/// 小误差微调速度吸收,⛔ 不直接挪锚点(位置会一跳一跳):锚点取当前外推值,误差在吸收窗口内匀速吸收,
/// 速度最多偏离倍速 `maxSlewRatio`(误差大就拉长窗口)。
/// 误差 ≥ `snapThreshold`(seek)或刚从暂停恢复时直接对齐。
@MainActor
final class DanmakuClock {
    private var anchorTime = 0.0
    private var anchorHostTime = 0.0
    private var rate = 1.0
    private var isPaused = true
    /// 正在吸收的误差(弹幕时间)与吸收时长(宿主时间),秒
    private var slewError = 0.0
    private var slewWindow = 0.0

    nonisolated static let snapThreshold = 0.5
    /// 秒;取位置更新间隔(0.2–0.3s)的几倍,新误差接力时速度变化平缓
    static let slewDuration = 1.0
    static let maxSlewRatio = 0.1

    func update(position: Double, isPaused paused: Bool, speed: Double, now: Double) {
        let predicted = time(at: now)
        let error = position - predicted
        let newRate = speed.isFinite && speed > 0 ? speed : 1
        let slews = !paused && !isPaused && abs(error) < Self.snapThreshold
        if slews {
            anchorTime = predicted
            slewError = error
            slewWindow = max(Self.slewDuration, abs(error) / (newRate * Self.maxSlewRatio))
        } else {
            anchorTime = position
            slewError = 0
            slewWindow = 0
        }
        anchorHostTime = now
        rate = newRate
        isPaused = paused
    }

    func time(at hostTime: Double) -> Double {
        guard !isPaused else { return anchorTime }
        let elapsed = hostTime - anchorHostTime
        let absorbed = slewWindow > 0 ? slewError * min(1, max(0, elapsed / slewWindow)) : 0
        return anchorTime + elapsed * rate + absorbed
    }
}
