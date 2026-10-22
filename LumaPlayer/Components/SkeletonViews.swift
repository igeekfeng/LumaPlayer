import SwiftUI

/// 首屏无内容时的灰色骨架,形状照真实布局摆,内容到达时是「填进去」。慢呼吸表示在加载,「减弱动态效果」下静止。
///
/// 本身是弹性形状,每个用例都要钉死尺寸:宽度已知用 `.frame(width: w, height: w / 宽高比)`;
/// 宽度由容器定用 `Color.clear` + `.aspectRatio(比, contentMode: .fit)` 算高度,再把它当 overlay。
/// ⛔ 不写 `.frame(width: w).aspectRatio(比, contentMode: .fit)`:高度按外层提议算,会被拉长。
///
/// 呼吸动画必须用限定作用域的 `.animation(_:body:)` 只动 opacity。⛔ 不用 `.animation(.repeatForever…, value:)`:
/// 会把位置变化卷进无限循环,骨架被上方内容推下后会在新旧位置间永远来回晃。
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = Radius.card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDim = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.secondary)
            // 只动透明度(见类型注释)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                $0.opacity(isDim ? 0.10 : 0.18)
            }
            .onAppear { if !reduceMotion { isDim = true } }
            .accessibilityHidden(true)
    }
}

/// 海报网格骨架,与 `ItemGridView` 的 `MediaCard` 对齐。
struct SkeletonGrid: View {
    var count = 18

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Metrics.posterMinWidth), spacing: Metrics.gridSpacing)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                ForEach(0..<count, id: \.self) { _ in
                    posterCell
                }
            }
            .padding(Metrics.spacingXL)
        }
        .scrollDisabled(true)
    }

    /// 同 `MediaCard`:`Color.clear` + `aspectRatio` 算高度,`SkeletonBlock` 当 overlay。
    private var posterCell: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Color.clear
                .aspectRatio(Metrics.posterAspectRatio, contentMode: .fit)
                .overlay { SkeletonBlock() }
            titleLine(widthFraction: 0.75)
            titleLine(widthFraction: 0.45)
        }
    }

    /// 标题 / 副标题两行占位,用「占满再留白」表达宽度比例,不写死像素宽。
    private func titleLine(widthFraction: CGFloat) -> some View {
        GeometryReader { proxy in
            SkeletonBlock(cornerRadius: Radius.card)
                .frame(width: proxy.size.width * widthFraction)
        }
        .frame(height: Metrics.spacingM)
    }
}

/// 首页一行货架的骨架:真实标题 + 一排卡片占位。
struct SkeletonShelf: View {
    let title: String
    var cardWidth: CGFloat = Metrics.posterMinWidth
    /// 宽 / 高
    var aspectRatio: Double = Metrics.posterAspectRatio
    var count = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text(title)
                .font(.title3.bold())
            HStack(alignment: .top, spacing: Metrics.gridSpacing) {
                ForEach(0..<count, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: Metrics.spacingS) {
                        SkeletonBlock()
                            .frame(width: cardWidth, height: cardHeight)
                        SkeletonBlock(cornerRadius: Radius.card)
                            .frame(width: cardWidth * 0.8, height: Metrics.spacingM)
                    }
                }
            }
            .padding(.vertical, Metrics.spacingS)
        }
    }

    private var cardHeight: CGFloat { cardWidth / aspectRatio }
}

/// 详情页骨架,结构照 `MediaDetailView.detailContent`。
struct SkeletonDetail: View {
    var body: some View {
        ScrollView {
            SkeletonDetailBody()
        }
        .scrollDisabled(true)
        .ignoresSafeArea(edges: .top)
    }
}

/// 不含滚动容器,便于 `ImageRenderer` 渲染验证(它画不出 `ScrollView` 内容)。
/// hero 与「海报 + 标题」在同一个 `spacing: 0` 的 `VStack`,标题区用负 `padding(.top,)` 压进 hero
/// (同 `DetailHero`),否则视觉错位。
struct SkeletonDetailBody: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXL) {
            VStack(alignment: .leading, spacing: 0) {
                SkeletonBlock(cornerRadius: 0)
                    .frame(height: heroHeight)
                    .frame(maxWidth: .infinity)
                HStack(alignment: .bottom, spacing: Metrics.spacingXL) {
                    SkeletonBlock()
                        .frame(width: Metrics.posterMinWidth, height: posterHeight)
                    VStack(alignment: .leading, spacing: Metrics.spacingM) {
                        line(width: 280, height: Metrics.spacingXL)
                        line(width: 200, height: Metrics.spacingM)
                        line(width: 260, height: Metrics.spacingXL)
                        line(width: 160, height: Metrics.spacingM)
                    }
                }
                .padding(.horizontal, Metrics.spacingXL)
                .padding(.top, -heroHeight * overlapRatio)
            }
            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                line(width: 320, height: Metrics.spacingM)
                line(width: 480, height: Metrics.spacingM)
                line(width: 400, height: Metrics.spacingM)
            }
            .padding(.horizontal, Metrics.spacingXL)
            .padding(.bottom, Metrics.spacingXL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroHeight: CGFloat { Metrics.contentMaxWidth * 9 / 16 }
    private var posterHeight: CGFloat { Metrics.posterMinWidth / Metrics.posterAspectRatio }
    /// 与 `DetailHero.overlapRatio` 一致
    private var overlapRatio: CGFloat { 0.45 }

    private func line(width: CGFloat, height: CGFloat) -> some View {
        SkeletonBlock(cornerRadius: Radius.card)
            .frame(width: width, height: height)
    }
}

/// 分集卡片骨架,与 `EpisodeListView` 的 `EpisodeCard` 同宽同结构。
struct SkeletonEpisodeStrip: View {
    var count = 5

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacingL) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Metrics.spacingS) {
                    SkeletonBlock()
                        .frame(width: Metrics.landscapeCardWidth, height: thumbnailHeight)
                    SkeletonBlock(cornerRadius: Radius.card)
                        .frame(width: Metrics.landscapeCardWidth * 0.6, height: Metrics.spacingM)
                    SkeletonBlock(cornerRadius: Radius.card)
                        .frame(width: Metrics.landscapeCardWidth * 0.9, height: Metrics.spacingM)
                }
                .padding(Metrics.spacingS)
                .frame(width: Metrics.landscapeCardWidth, alignment: .topLeading)
            }
        }
    }

    private var thumbnailHeight: CGFloat {
        Metrics.landscapeCardWidth / Metrics.landscapeAspectRatio
    }
}
