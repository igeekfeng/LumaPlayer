import SwiftUI

/// 横版(16:9)卡片:「继续观看」「下一集」用(Emby Web / Apple TV 的做法 ——
/// 续播内容用剧照而不是海报,一眼能认出停在哪一集)。
///
/// 非玻璃卡片(UI_DESIGN.md 4.2);悬停时画面上出现玻璃播放按钮,
/// 点它直接续播,点卡片其余位置打开详情。
struct LandscapeCard: View {
    let item: EmbyItem
    let serverID: UUID
    let store: PosterImageStore
    var onPlay: (() -> Void)?

    @State private var isHovering = false

    static var width: CGFloat { Metrics.landscapeCardWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            // 尺寸由 Color.clear 钉死,图片与播放按钮只当 overlay(见 HomeView.LibraryTile)
            Color.clear
                .aspectRatio(Metrics.landscapeAspectRatio, contentMode: .fit)
                .frame(width: Self.width)
                .overlay { PosterImage(spec: imageSpec, store: store, placeholderSystemImage: "play.rectangle") }
                .overlay {
                if isHovering, let onPlay {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .padding(Metrics.spacingM)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help(item.progressFraction == nil ? "播放" : "继续播放")
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(alignment: .bottom) {
                if let progress = item.progressFraction {
                    CardProgressBar(fraction: progress)
                        .padding(Metrics.spacingS)
                }
            }
            .scaleEffect(isHovering ? Self.hoverScale : 1)
            .shadow(color: .black.opacity(isHovering ? 0.25 : 0), radius: Metrics.spacingS, y: Metrics.spacingXS)
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text(primaryTitle)
                    .font(.body)
                    .lineLimit(1)
                if let secondaryTitle {
                    Text(secondaryTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Self.width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([primaryTitle, secondaryTitle].compactMap { $0 }.joined(separator: ","))
    }

    private static var hoverScale: CGFloat { 1.03 }

    /// 分集显示剧名(剧名比集名更好认),其余显示自己的名字
    private var primaryTitle: String {
        item.kind == .episode ? (item.seriesName ?? item.name) : item.name
    }

    /// 分集:「S1E2 · 集名」;其余:剩余时长,没有就年份
    private var secondaryTitle: String? {
        if item.kind == .episode {
            let parts = [item.episodeLabel, item.seriesName == nil ? nil : item.name].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        if let remaining = MediaFormat.remaining(for: item) { return "剩余 \(remaining)" }
        return item.productionYear.map(String.init)
    }

    private var imageSpec: ImageSpec? {
        item.landscapeImage.map {
            ImageSpec(
                serverID: serverID,
                itemID: $0.itemID,
                type: $0.type,
                tag: $0.tag,
                maxWidth: Int(Self.width * 2)
            )
        }
    }
}

/// 卡片底部的进度条(UI_DESIGN.md 6.1:已播放 / 未看完的清晰标记)。
/// 画在图片上,所以用白色 + 半透明轨道,不随深浅色变化。
struct CardProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.35))
                Capsule()
                    .fill(.white)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: Metrics.spacingXS)
        .accessibilityLabel("已观看 \(Int(fraction * 100))%")
    }
}
