import SwiftUI

/// 加载中占位。文案要说明「在做什么」,不只靠旋转动画
/// (UI_DESIGN.md 5.2 的可读性要求同样适用于列表)。
struct LoadingStateView: View {
    let title: String

    var body: some View {
        VStack(spacing: Metrics.spacingM) {
            ProgressView()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metrics.spacingXL)
    }
}
