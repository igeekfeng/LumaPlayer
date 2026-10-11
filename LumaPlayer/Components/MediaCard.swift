import SwiftUI

/// 媒体库网格里的一张海报卡片(DesignTokens.swift「界面规则」)。
///
/// 非玻璃卡片、不叠玻璃(4.2 禁止区域);已看/未看完用**底部进度条**表达,
/// 不用透明度变化作为唯一提示(6.1)。
struct MediaCard: View {
    let item: EmbyItem
    let serverID: UUID
    let store: PosterImageStore

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            // 尺寸由 Color.clear 钉死,图片只当 overlay:`.fill` 的图会按自己的比例
            // 报告溢出的布局尺寸,横向货架里就会撑乱卡片宽高
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
                // 悬停:轻微放大 + 阴影(系统 hover 的惯用反馈,不叠玻璃,DesignTokens.swift「界面规则」)
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

    /// 右上角:看完了打 ✓;剧集还有没看的集就显示集数(Emby Web 同款)。
    /// 两者都有文字 / 图标语义,不只靠颜色(DesignTokens.swift「界面规则」)。
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

    /// 有 `Primary` tag 才请求图片(API_CONTRACT.md 3.3:没 tag 去请求会 404)。
    /// `MaxWidth` 取 `posterMinWidth × 2` = 300(DesignTokens.swift)。
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

    /// 副标题:剧集显示「SxEx」,其余显示年份。缺字段就不显示(不填占位符)。
    @ViewBuilder
    private var subtitle: some View {
        if let episodeLabel = item.episodeLabel {
            Text(episodeLabel)
        } else if let year = item.productionYear {
            Text(String(year))
        }
    }
}
