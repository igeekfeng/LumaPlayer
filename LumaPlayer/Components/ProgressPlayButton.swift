import SwiftUI

/// 详情页主按钮:液态玻璃胶囊,背景从左起的一段填充表示观看比例,文字给续播位置
/// (「继续 00:40:05」)。玻璃与填充用同一个胶囊形状,填充贴满整个按钮、不留白边。
/// ⛔ 不加悬停特效;与同排圆形玻璃按钮同高。`fraction == nil` 只画按钮,⛔ 不猜比例。
struct ProgressPlayButton: View {
    /// 续播位置(秒);nil / 0 = 从头播
    let positionSeconds: Double?
    /// 观看比例 0–1
    let fraction: Double?
    let action: () -> Void

    private var title: String {
        guard let positionSeconds, let code = MediaFormat.timecode(seconds: positionSeconds) else {
            return "播放"
        }
        return "继续 \(code)"
    }

    private var progress: Double? {
        guard let fraction, fraction.isFinite, fraction > 0 else { return nil }
        return min(fraction, 1)
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                if let progress {
                    Rectangle()
                        .fill(Color.primary.opacity(Metrics.detailPlayProgressOpacity))
                        .scaleEffect(x: progress, anchor: .leading)
                }
                Text(title)
                    .font(.system(size: Metrics.detailPlayFontSize, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .frame(width: Metrics.detailPlayButtonWidth, height: Metrics.detailActionHeight)
            .clipShape(Capsule())
            .glassEffect(.regular, in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // 详情页的主按钮:回车直接播
        .keyboardShortcut(.defaultAction)
        .help(title)
        .accessibilityValue(progress.map { "已观看 \(Int(($0 * 100).rounded()))%" } ?? "")
    }
}

/// 详情页次要按钮:同高圆形液态玻璃图标按钮,文字只进 help。
struct GlassIconButton: View {
    let systemImage: String
    let label: String
    /// 选中态强调色;nil 用系统前景色
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: Metrics.detailActionSymbolSize, weight: .medium))
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: Metrics.detailActionHeight, height: Metrics.detailActionHeight)
                .glassEffect(.regular, in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// 卡片上的紧凑形态:常显,⛔ 不加悬停特效。
struct ProgressPlayBadge: View {
    let fraction: Double?
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProgressPlayGlyph(fraction: fraction, size: Metrics.progressPlayBadgeSize)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityValue(fraction.map { "已观看 \(Int(($0 * 100).rounded()))%" } ?? "")
    }
}

private struct ProgressPlayGlyph: View {
    let fraction: Double?
    let size: CGFloat

    private var progress: Double? {
        guard let fraction, fraction.isFinite, fraction > 0 else { return nil }
        return min(max(fraction, 0), 1)
    }

    var body: some View {
        let ring = Metrics.progressPlayRingWidth
        return ZStack {
            Circle()
                .fill(Color.black.opacity(Metrics.progressPlayFillOpacity))
            if let progress {
                Circle()
                    .strokeBorder(
                        Color.white.opacity(Metrics.progressPlayRingTrackOpacity),
                        lineWidth: ring
                    )
                // padding 让 stroke 的路径半径与 strokeBorder 对齐;从 12 点顺时针走
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: ring, lineCap: .round)
                    )
                    .padding(ring / 2)
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: "play.fill")
                .resizable()
                .scaledToFit()
                .frame(width: size * Metrics.progressPlaySymbolRatio)
                .foregroundStyle(.white)
                .offset(x: size * Metrics.progressPlaySymbolOffsetRatio)
        }
        .frame(width: size, height: size)
        .shadow(
            color: .black.opacity(Metrics.progressPlayShadowOpacity),
            radius: Metrics.spacingS,
            y: Metrics.spacingXS
        )
    }
}
