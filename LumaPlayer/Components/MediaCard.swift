import SwiftUI

/// 海报卡片:非玻璃、不叠玻璃;已看 / 未看完用底部进度条表达,不只靠透明度(DesignTokens.swift「界面规则」)。
struct MediaCard: View {
    let item: EmbyItem
    let serverID: UUID
    let store: PosterImageStore

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            // 尺寸由 Color.clear 钉死,图片只当 overlay:`.fill` 的图会报告溢出尺寸,撑乱横向货架
            Color.clear
                .aspectRatio(Metrics.posterAspectRatio, contentMode: .fit)
                .overlay { PosterImage(spec: posterSpec, store: store) }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .overlay(alignment: .bottom) {
                    if let progress = item.progressFraction {
                        CardProgressBar(fraction: progress)
                            .padding(Metrics.spacingS)
                    }
                }
                .overlay(alignment: .topTrailing) { badge }
                // 悬停:轻微放大 + 阴影,不叠玻璃
                .scaleEffect(isHovering ? Self.hoverScale : 1)
                .shadow(color: .black.opacity(isHovering ? 0.25 : 0), radius: Metrics.spacingS, y: Metrics.spacingXS)
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private static var hoverScale: CGFloat { 1.03 }

    /// 右上角:看完打 ✓;剧集有没看的集显示集数。
    @ViewBuilder
    private var badge: some View {
        if item.isPlayed {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .font(.title3)
                .padding(Metrics.spacingXS)
        } else if item.kind == .series, let unplayed = item.userData?.unplayedItemCount, unplayed > 0 {
            Text("\(unplayed)")
                .font(.caption.bold())
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, Metrics.spacingS)
                .padding(.vertical, Metrics.spacingXS)
                .background(Color.accentColor, in: Capsule())
                .padding(Metrics.spacingXS)
        }
    }

    private var accessibilityText: String {
        var parts = [item.name]
        if item.isPlayed { parts.append("已看") }
        if item.kind == .series, let unplayed = item.userData?.unplayedItemCount, unplayed > 0 {
            parts.append("\(unplayed) 集未看")
        }
        if let progress = item.progressFraction { parts.append("已观看 \(Int(progress * 100))%") }
        return parts.joined(separator: ",")
    }

    /// 有 `Primary` tag 才请求(没 tag 会 404,API_CONTRACT.md 3.3)。`MaxWidth` 取 `posterMinWidth × 2`。
    private var posterSpec: ImageSpec? {
        guard let tag = item.primaryImageTagValue else { return nil }
        return ImageSpec(
            serverID: serverID,
            itemID: item.id,
            type: .primary,
            tag: tag,
            maxWidth: Int(Metrics.posterMinWidth * 2)
        )
    }

    /// 剧集显示「SxEx」,其余显示年份;缺字段不显示。
    @ViewBuilder
    private var subtitle: some View {
        if let episodeLabel = item.episodeLabel {
            Text(episodeLabel)
        } else if let year = item.productionYear {
            Text(String(year))
        }
    }
}
