import SwiftUI

/// 「已看」角标,参数与 `MediaCard` 里那一枚一致。对 VoiceOver 隐藏:卡片的合成描述里已念「已看」。
/// ⛔ 不用透明度 / 灰度表达已看(DesignTokens.swift「界面规则」)。
struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.accentColor)
            .font(.title3)
            .padding(Metrics.spacingXS)
            .accessibilityHidden(true)
    }
}
