import SwiftUI

/// 工具栏的「刷新」按钮。加载 / 刷新进行中时把刷新图标转起来并禁用 ——
/// 页面上不再出现居中的转圈,「在不在加载」只看这一个图标。
///
/// 用 `TimelineView` 按时间连续算角度,而不是 `repeatForever` 动画:
/// 后者在 `isLoading` 变回 false 时不一定停得干净,`paused` 一置真就立刻停,
/// 角度也回到 0(图标回正)。
struct RefreshToolbarButton: View {
    let isLoading: Bool
    let action: () -> Void

    /// 转一圈的时长。比系统 `ProgressView` 略慢一点,不刺眼。
    private static let spinPeriod: TimeInterval = 0.9

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: !isLoading)) { timeline in
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(angle(at: timeline.date)))
            }
        }
        .disabled(isLoading)
        .help("刷新当前页面")
        .accessibilityLabel("刷新")
    }

    /// 加载中按时间连续算角度;不在加载中固定为 0。
    private func angle(at date: Date) -> Double {
        guard isLoading else { return 0 }
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: Self.spinPeriod) / Self.spinPeriod
        return phase * 360
    }
}
