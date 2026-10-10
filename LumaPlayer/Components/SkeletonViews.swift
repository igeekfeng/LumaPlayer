import SwiftUI

/// 首屏还没有内容时的灰色骨架占位(替代原先的居中转圈)。
///
/// 形状照着真实布局摆(海报网格 / 货架 / 详情页),这样内容到达时是「填进去」而不是
/// 「整页换掉」,不会有白屏一闪。明暗用很慢的呼吸表示「在加载」;
/// 开启「减弱动态效果」时保持静止。
///
/// ⚠️ 本类型是 `RoundedRectangle`(形状),本身是**弹性**的 —— 谁给它多大就填多大。
/// 所以每个用例都必须把尺寸钉死,两种写法二选一:
/// - 宽度已知:`.frame(width: w, height: w / 宽高比)`;
/// - 宽度由容器决定:`.aspectRatio(比, contentMode: .fit)` 交给 `Color.clear` 之类的
///   弹性占位算出高度,再把 `SkeletonBlock` 当 overlay。
/// ⛔ 不要写 `.frame(width: w).aspectRatio(比, contentMode: .fit)`:宽度被 frame 钉死、
/// 高度却由 aspectRatio 按外层(往往是 `nil`)的提议去算,结果高度失控 —— 灰色块会被
/// 上下拉长(2026-10-10 踩过)。
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = Radius.card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDim = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.secondary.opacity(isDim ? 0.10 : 0.18))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: isDim
            )
            .onAppear { if !reduceMotion { isDim = true } }
            .accessibilityHidden(true)
    }
}

/// 海报网格骨架:列宽 / 间距 / 单元结构都与 `ItemGridView` 的 `MediaCard` 对齐。
/// 媒体库页与搜索页首屏用它。
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

    /// 单元宽度由自适应网格决定,这里学 `MediaCard`:让 `Color.clear` 吃下提议、
    /// 由 `aspectRatio` 算出高度,`SkeletonBlock` 只当 overlay 填满。
    private var posterCell: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Color.clear
                .aspectRatio(Metrics.posterAspectRatio, contentMode: .fit)
                .overlay { SkeletonBlock() }
            titleLine(widthFraction: 0.75)
            titleLine(widthFraction: 0.45)
        }
    }

    /// 卡片标题 / 副标题的两行占位。用「占满再留白」表达宽度比例,不写死像素宽。
    private func titleLine(widthFraction: CGFloat) -> some View {
        GeometryReader { proxy in
            SkeletonBlock(cornerRadius: Radius.card)
                .frame(width: proxy.size.width * widthFraction)
        }
        .frame(height: Metrics.spacingM)
    }
}

/// 首页一行货架的骨架:真实标题 + 一排卡片占位(海报或横版)。
/// `HomeLibrariesRow` / `HomeResumeRow` / `HomeLatestRow` 首屏用它。
struct SkeletonShelf: View {
    let title: String
    var cardWidth: CGFloat = Metrics.posterMinWidth
    /// 卡片的宽高比(宽 / 高),与 `Metrics.posterAspectRatio` 同义
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

/// 详情页骨架:整幅 hero + 海报 + 标题 / 元信息 / 按钮的占位。
/// 结构照着 `MediaDetailView.detailContent` 摆。
struct SkeletonDetail: View {
    var body: some View {
        ScrollView {
            SkeletonDetailBody()
        }
        .scrollDisabled(true)
        .ignoresSafeArea(edges: .top)
    }
}

/// 详情页骨架的内容(不含滚动容器)。单独拆出来是为了能用 `ImageRenderer`
/// 渲染验证 —— `ScrollView` 的内容不会被 `ImageRenderer` 画出来。
///
/// 结构与 `MediaDetailView.detailContent` 一一对应:hero 与「海报 + 标题」是同一个
/// `spacing: 0` 的 `VStack`,标题区再用负 `padding(.top,)` 压进 hero(和 `DetailHero`
/// 同款),否则多出来的 `spacingXL` 会把海报行顶下去、负 padding 又压回来,视觉错位。
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
    /// 与 `DetailHero.overlapRatio` 一致:标题区压进 hero 的比例
    private var overlapRatio: CGFloat { 0.45 }

    private func line(width: CGFloat, height: CGFloat) -> some View {
        SkeletonBlock(cornerRadius: Radius.card)
            .frame(width: width, height: height)
    }
}

/// 分集横向卡片骨架:与 `EpisodeListView` 的 `EpisodeCard` 同宽同结构。
/// 剧集详情页的「正在加载季 / 分集」用它。
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
