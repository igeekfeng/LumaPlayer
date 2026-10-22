import AppKit

/// 触控板双指横滑拖进度。
///
/// 用本地事件监听而非叠 NSView 接 `scrollWheel`:叠上去的视图会吃掉画面的单击 / 双击手势。
///
/// - 只认精确位移设备;普通滚轮不接管。
/// - 先累计位移,横向明显占优才接管,否则整次手势放行。
/// - 接管后吞掉该手势及其惯性事件,手指离开才 seek 一次(转码模式每次 seek 都重新起流)。
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
        // 非 @Sendable 闭包按 MainActor 隔离处理,本地监听本就在主线程回调。
        // 不能套 `MainActor.assumeIsolated`:返回值 NSEvent 不是 Sendable。
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

        // 接管的手势连惯性一并吞掉
        if !event.momentumPhase.isEmpty {
            return decision == .scrubbing ? nil : event
        }

        switch event.phase {
        case .began:
            reset()
            return event
        case .changed:
            // 统一成手指向右 = 正(自然滚动时系统已反向)
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
