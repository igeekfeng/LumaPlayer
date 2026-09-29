import AppKit

/// 触控板双指横向滑动拖进度(IINA / QuickTime 的习惯)。
///
/// 为什么用本地事件监听而不是在视频层上叠一个 NSView 接 `scrollWheel`:
/// 叠上去的视图要参与 hit-test 才收得到滚动事件,而那样就会吃掉画面上的
/// 单击(暂停)/ 双击(全屏)手势。本地监听只看滚动事件,其余事件原样放行。
///
/// 规则:
/// - 只认有精确位移的设备(触控板 / 妙控鼠标);普通滚轮一格一跳,不适合拖进度;
/// - 一次手势开始后先累计位移,横向明显占优才接管,否则整次手势放行给系统
///   (纵向滑动不能被误判成拖进度);
/// - 接管后吞掉该手势及其惯性阶段的全部事件,手指离开时才 seek 一次 ——
///   转码模式下一次 seek 就是一次重新起流。
@MainActor
final class TrackpadScrubMonitor {
    private var monitor: Any?

    private enum Decision {
        case undecided
        case scrubbing
        case passThrough
    }

    private var decision = Decision.undecided
    private var accumulatedX: Double = 0
    private var accumulatedY: Double = 0

    /// - Parameters:
    ///   - window: 只处理落在这个窗口里的事件
    ///   - onScrub: 横向位移(秒,已按方向与灵敏度换算;正 = 前进)
    ///   - onEnd: 手指离开 / 手势取消
    func install(
        window: @escaping @MainActor () -> NSWindow?,
        onScrub: @escaping @MainActor (Double) -> Void,
        onEnd: @escaping @MainActor () -> Void
    ) {
        guard monitor == nil else { return }
        // 闭包在 MainActor 上下文里构造、又不是 @Sendable,编译器按 MainActor 隔离处理;
        // 本地监听本来就在主线程回调(NSEvent 文档),二者一致。
        // (不能套 `MainActor.assumeIsolated`:它要求返回值 Sendable,NSEvent 不是。)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let target = window(), event.window === target else { return event }
            return self.handle(event, onScrub: onScrub, onEnd: onEnd)
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        reset()
    }

    private func handle(
        _ event: NSEvent,
        onScrub: (Double) -> Void,
        onEnd: () -> Void
    ) -> NSEvent? {
        guard event.hasPreciseScrollingDeltas else { return event }

        // 惯性阶段:我们接管的手势,惯性一并吞掉(否则松手后画面还在「滑」);其余放行
        if !event.momentumPhase.isEmpty {
            return decision == .scrubbing ? nil : event
        }

        switch event.phase {
        case .began:
            reset()
            return event
        case .changed:
            // 统一成「手指向右 = 正」:自然滚动开启时系统已把位移反过来了
            let dx = Double(event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX)
            let dy = Double(event.scrollingDeltaY)
            if decision == .undecided {
                accumulatedX += dx
                accumulatedY += dy
                if abs(accumulatedX) >= Metrics.trackpadActivationDistance,
                   abs(accumulatedX) > abs(accumulatedY) * Metrics.trackpadHorizontalDominance {
                    decision = .scrubbing
                    onScrub(accumulatedX * Metrics.trackpadSeekSecondsPerPoint)
                    return nil
                }
                if abs(accumulatedY) >= Metrics.trackpadActivationDistance {
                    decision = .passThrough
                }
                return event
            }
            guard decision == .scrubbing else { return event }
            onScrub(dx * Metrics.trackpadSeekSecondsPerPoint)
            return nil
        case .ended, .cancelled:
            let wasScrubbing = decision == .scrubbing
            if wasScrubbing { onEnd() }
            // 惯性事件在 ended 之后才来,decision 留到下一次 began 再清
            accumulatedX = 0
            accumulatedY = 0
            return wasScrubbing ? nil : event
        default:
            return decision == .scrubbing ? nil : event
        }
    }

    private func reset() {
        decision = .undecided
        accumulatedX = 0
        accumulatedY = 0
    }
}
