import AppKit
import QuartzCore
import SwiftUI

/// 弹幕渲染层:叠在视频上、控制层下,⛔ 不接收点击(`allowsHitTesting(false)` 由挂载处给)。
///
/// ## 为什么不交给 mpv
///
/// mpv 的字幕 / OSD 只能画 ASS,弹幕要先转成整份 ASS 再 `sub-add`;那样改字号 / 透明度 /
/// 显示区域 / 偏移都得重新生成并重载字幕轨,还会占掉用户正在用的字幕轨。
/// 自己画一层则所有外观参数都能即时生效(`docs/DANMAKU.md` §4)。
///
/// ## 为什么是 CALayer + displayLink,不是 SwiftUI `Canvas`
///
/// 最早用 `TimelineView` + `Canvas`:每帧在主线程把整窗口连同每条文字的模糊阴影重新光栅化,
/// 实测 120 Hz 屏上 30–40 条在场时只剩约 40 帧且间隔在 8 / 33 / 42 ms 之间乱跳,滚动一顿一顿
/// (`DanmakuFrameDiagnostics` 取证)。现在每条出场时预渲染一次位图(`DanmakuSprite`),
/// 之后每帧只改图层位置,由 Core Animation 在 GPU 上合成;位置按 displayLink 的
/// `targetTimestamp`(这一帧**上屏**的时刻)算,每帧步长均匀。
///
/// ## 时间从哪来
///
/// 播放位置 `positionSeconds` 只有 5 Hz(`MPVPlayer` 节流 0.2 s),直接用会一跳一跳。
/// `DanmakuClock` 在两次位置更新之间按倍速外推;新位置到来时小误差靠微调速度连续吸收(位置不跳)、
/// 大误差(seek)直接对齐。
/// 暂停时时间轴停住,displayLink 也停。
///
/// 滚动顺不顺的逐帧取证(帧间隔、掉帧、时钟跳动)见 `DanmakuFrameDiagnostics`,默认关闭。
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

/// 弹幕图层的承载视图:一个容器层 + 每条在场弹幕一个子层(内容是预渲染位图)。
///
/// 图层按「排版结果里的下标」缓存;`DanmakuController.layoutGeneration` 变了(换弹幕库、
/// 字号 / 窗口尺寸 / 显示区域变了)或屏幕像素密度变了,整批丢弃重建。
final class DanmakuLayerView: NSView {

    /// `settings.fontSize` 以 1080 高的画面为基准
    private static let referenceHeight: CGFloat = 1080
    private static let minimumFontSize: CGFloat = 12
    /// 回收池上限:够同屏峰值复用,不无限囤
    private static let poolLimit = 128

    private var controller: DanmakuController
    private var settings = DanmakuDisplaySettings.default
    private var isPaused = true
    private var speed = 1.0
    private var lastClockInput: (position: Double, isPaused: Bool, speed: Double)?

    private let clock = DanmakuClock()
    private let container = CALayer()
    private var sprites: [Int: DanmakuSpriteLayer] = [:]
    private var pool: [DanmakuSpriteLayer] = []
    private var spriteGeneration: Int?
    private var scale: CGFloat = 2
    private var displayLink: CADisplayLink?
    private let diagnostics = DanmakuFrameDiagnostics.isEnabled ? DanmakuFrameDiagnostics() : nil

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
        // 本视图只在代码里创建
        fatalError("init(coder:) has not been implemented")
    }

    /// 自上而下排版,与 `DanmakuLayout` 的行号方向一致
    override var isFlipped: Bool { true }

    /// 不吃点击(双保险,挂载处另有 `allowsHitTesting(false)`)
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
        self.speed = speed.isFinite && speed > 0 ? speed : 1
        container.opacity = Float(settings.opacity)

        // 只在三项真变了时同步时钟:父视图因别的原因刷新时位置还是旧值,拿它去「校正」会把时钟往回拽
        let clockInput = (position: position, isPaused: isPaused, speed: speed)
        if lastClockInput.map({ $0 != clockInput }) ?? true {
            clock.update(position: position, isPaused: isPaused, speed: speed, now: CACurrentMediaTime())
            lastClockInput = clockInput
        }
        displayLink?.isPaused = isPaused
        // 暂停时没有逐帧刷新:seek / 改外观 / 拖窗口都要手动画一帧
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

    /// 跑满屏幕的最高刷新率(ProMotion 120 Hz;系统按功耗策略可能再降)
    private func updatePreferredFrameRate() {
        guard let displayLink, let fps = window?.screen?.maximumFramesPerSecond, fps > 0 else { return }
        let rate = Float(fps)
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
    }

    // MARK: - 逐帧

    @objc private func step(_ link: CADisplayLink) {
        let start = CACurrentMediaTime()
        let frame = renderFrame(at: link.targetTimestamp)
        guard let diagnostics, let frame else { return }
        diagnostics.record(DanmakuFrameStats.Frame(
            hostTime: start,
            targetTime: link.targetTimestamp,
            refreshInterval: link.targetTimestamp - link.timestamp,
            danmakuTime: frame.time,
            velocity: frame.velocity,
            rate: speed,
            workDuration: CACurrentMediaTime() - start,
            visibleCount: frame.visibleCount,
            windowVisible: window?.occlusionState.contains(.visible) ?? false))
    }

    /// 把 `hostTime` 时刻(宿主时钟,= `CACurrentMediaTime`)该在场的弹幕摆好。
    /// 返回本帧用的时间与条数(给诊断);画面尺寸为 0 时返回 nil。
    @discardableResult
    private func renderFrame(at hostTime: Double) -> (time: Double, velocity: Double, visibleCount: Int)? {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
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
        return (time, velocity, live.count)
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

/// 一条弹幕的图层;`margin` 是预渲染位图四周给描边留的白(pt),摆放时把行框原点换算成位图原点。
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

/// 弹幕时间轴的时钟:在两次播放位置更新之间按倍速外推(见 `DanmakuOverlayView` 的注释)。
///
/// 时间基是宿主时钟(`CACurrentMediaTime`,秒),与 displayLink 的 `targetTimestamp` 同源。
///
/// ## 小误差怎么收:微调速度,不挪位置
///
/// 新位置到来时,锚点取**当前外推值**(位置连续、不跳),误差在 `slewDuration` 内匀速吸收:
/// 这段时间外推速度 = 倍速 + 误差 / 吸收时长,吸收完回到倍速,不会过冲。
/// 吸收时速度最多偏离倍速 `maxSlewRatio`(误差大就拉长吸收时间),肉眼看不出变速。
/// 早先是每次更新直接把锚点挪 20% 误差:位置每秒跳 4–5 次,每次约 1pt(诊断实测),盯着字看会一顿一顿。
///
/// 误差 ≥ `snapThreshold`(seek)、或刚从暂停恢复时直接对齐。
@MainActor
final class DanmakuClock {
    private var anchorTime = 0.0
    private var anchorHostTime = 0.0
    private var rate = 1.0
    private var isPaused = true
    /// 正在吸收的误差(秒,弹幕时间)与吸收时长(秒,宿主时间)
    private var slewError = 0.0
    private var slewWindow = 0.0

    /// 误差小于它视为抖动,微调速度吸收;大于它视为 seek,直接对齐
    nonisolated static let snapThreshold = 0.5
    /// 小误差的吸收时长(秒);位置约每 0.2–0.3 秒来一次,取它的几倍,新误差接力时速度变化平缓
    static let slewDuration = 1.0
    /// 吸收误差时外推速度相对倍速的最大偏离
    static let maxSlewRatio = 0.1

    func update(position: Double, isPaused paused: Bool, speed: Double, now: Double) {
        let predicted = time(at: now)
        let error = position - predicted
        let newRate = speed.isFinite && speed > 0 ? speed : 1
        if !paused, !isPaused, abs(error) < Self.snapThreshold {
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
