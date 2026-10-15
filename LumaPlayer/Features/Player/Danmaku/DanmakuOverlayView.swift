import SwiftUI

/// 弹幕渲染层:叠在视频上、控制层下,⛔ 不接收点击(`allowsHitTesting(false)` 由挂载处给)。
///
/// ## 为什么不交给 mpv
///
/// mpv 的字幕 / OSD 只能画 ASS,弹幕要先转成整份 ASS 再 `sub-add`;那样改字号 / 透明度 /
/// 显示区域 / 偏移都得重新生成并重载字幕轨,还会占掉用户正在用的字幕轨。
/// 自己画一层 SwiftUI `Canvas` 则所有外观参数都能即时生效(`docs/DANMAKU.md` §4)。
///
/// ## 时间从哪来
///
/// 播放位置 `positionSeconds` 只有 5 Hz(`MPVPlayer` 节流 0.2 s),直接用会一跳一跳。
/// `DanmakuClock` 在两次位置更新之间按倍速外推,每帧(`TimelineView(.animation)`)取一次;
/// 新位置到来时小误差慢慢收敛、大误差(seek)直接对齐。暂停时时间轴停住,动画也停。
struct DanmakuOverlayView: View {
    let controller: DanmakuController
    let settings: DanmakuDisplaySettings
    let positionSeconds: Double
    let isPaused: Bool
    let speed: Double

    @State private var clock = DanmakuClock()

    /// `settings.fontSize` 以 1080 高的画面为基准
    private static let referenceHeight: CGFloat = 1080
    private static let minimumFontSize: CGFloat = 12

    var body: some View {
        if controller.isVisible, controller.loaded != nil {
            TimelineView(.animation(minimumInterval: nil, paused: isPaused)) { timeline in
                Canvas(rendersAsynchronously: false) { context, size in
                    draw(in: &context, size: size, date: timeline.date)
                }
            }
            .opacity(settings.opacity)
            .onAppear { syncClock() }
            .onChange(of: positionSeconds) { syncClock() }
            .onChange(of: isPaused) { syncClock() }
            .onChange(of: speed) { syncClock() }
        }
    }

    private func syncClock() {
        clock.update(position: positionSeconds, isPaused: isPaused, speed: speed, now: Date())
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, date: Date) {
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
        guard !placed.isEmpty else { return }

        let time = clock.time(at: date) - controller.shift
        let lineHeight = parameters.lineHeight
        let velocity = Double(parameters.velocity)
        let font = Font.system(size: parameters.fontSize, weight: .bold)
        context.addFilter(.shadow(color: .black.opacity(0.85), radius: 1, x: 0, y: 0))
        context.addFilter(.shadow(color: .black.opacity(0.6), radius: 2, x: 1, y: 1))

        for item in DanmakuLayout.visible(in: placed, at: time, maxLifetime: maxLifetime) where item.end > time {
            let origin: CGPoint
            switch item.comment.mode {
            case .scroll:
                origin = CGPoint(
                    x: parameters.viewportWidth - CGFloat((time - item.start) * velocity),
                    y: CGFloat(item.lane) * lineHeight)
            case .top:
                origin = CGPoint(
                    x: (parameters.viewportWidth - item.width) / 2,
                    y: CGFloat(item.lane) * lineHeight)
            case .bottom:
                origin = CGPoint(
                    x: (parameters.viewportWidth - item.width) / 2,
                    y: parameters.viewportHeight - CGFloat(item.lane + 1) * lineHeight)
            }
            let text = Text(item.comment.text).font(font).foregroundStyle(Self.color(item.comment.color))
            context.draw(text, at: origin, anchor: .topLeading)
        }
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}

/// 弹幕时间轴的时钟:在两次播放位置更新之间按倍速外推(见 `DanmakuOverlayView` 的注释)。
///
/// 引用类型放进 `@State`:更新锚点不该触发视图重算(每帧本来就在重画)。
@MainActor
final class DanmakuClock {
    private var anchorTime = 0.0
    private var anchorDate = Date()
    private var rate = 1.0
    private var isPaused = true

    /// 误差小于它视为抖动,慢慢收敛;大于它视为 seek,直接对齐
    static let snapThreshold = 0.5
    /// 每次位置更新收敛掉的误差比例
    static let convergence = 0.2

    func update(position: Double, isPaused paused: Bool, speed: Double, now: Date) {
        let predicted = time(at: now)
        let error = position - predicted
        if !paused, !isPaused, abs(error) < Self.snapThreshold {
            anchorTime = predicted + error * Self.convergence
        } else {
            anchorTime = position
        }
        anchorDate = now
        rate = speed.isFinite && speed > 0 ? speed : 1
        isPaused = paused
    }

    func time(at date: Date) -> Double {
        isPaused ? anchorTime : anchorTime + date.timeIntervalSince(anchorDate) * rate
    }
}
