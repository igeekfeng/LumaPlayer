import SwiftUI

/// 「已看」角标:叠在封面右上角的一枚实心对勾。
///
/// 视觉与 `MediaCard`(Emby 侧)里那一枚**同一套参数**(`checkmark.circle.fill` +
/// palette 渲染:白勾 + 强调色圆),所以两个来源的「已看」长得一样。
///
/// ## 两个约定
///
/// - 它对 VoiceOver **隐藏**:所在的卡片本来就有一条合成的无障碍描述
///   (里面已经念了「已看」),这里再挂一个标签会让它被念两遍。
/// - ⛔ 不用透明度 / 灰度变化表达已看(`DesignTokens.swift`「界面规则」6.1):
///   那是唯一提示时等于没提示。
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
