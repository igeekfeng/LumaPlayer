import SwiftUI

/// 横向货架:标题 +「查看全部」+ 左右翻页按钮(鼠标用户没法横滑)。按钮在标题行右侧,不遮卡片。
struct MediaShelf<Content: View>: View {
    let title: String
    /// 有值时标题旁出现「查看全部」
    var seeAll: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var position = ScrollPosition()
    @State private var geometry = ShelfGeometry()

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingM) {
                Text(title)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                if let seeAll {
                    Button(action: seeAll) {
                        Label("查看全部", systemImage: "chevron.right")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
                Spacer()
                if geometry.isScrollable {
                    ShelfPagingButtons(position: $position, geometry: geometry)
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.gridSpacing) {
                    content()
                }
                .padding(.vertical, Metrics.spacingS)
            }
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ShelfGeometry.self) { proxy in
                ShelfGeometry(
                    offset: proxy.contentOffset.x,
                    contentWidth: proxy.contentSize.width,
                    containerWidth: proxy.containerSize.width
                )
            } action: { _, new in
                geometry = new
            }
        }
    }

}

/// 左右翻页按钮(首页货架与详情页分集共用)。内容能滚动时才显示,到头的一侧禁用。
struct ShelfPagingButtons: View {
    @Binding var position: ScrollPosition
    let geometry: ShelfGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ControlGroup {
            Button {
                page(by: -1)
            } label: {
                Label("上一页", systemImage: "chevron.left")
            }
            .disabled(!geometry.canScrollBack)
            Button {
                page(by: 1)
            } label: {
                Label("下一页", systemImage: "chevron.right")
            }
            .disabled(!geometry.canScrollForward)
        }
        .controlGroupStyle(.navigation)
        .labelStyle(.iconOnly)
        .fixedSize()
    }

    /// 一次翻大半屏,留一张卡的重叠。
    private func page(by direction: CGFloat) {
        let step = geometry.containerWidth * Self.pageFraction * direction
        let target = min(max(0, geometry.offset + step), geometry.maxOffset)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: Metrics.animationStandard)) {
            position.scrollTo(x: target)
        }
    }

    private static var pageFraction: CGFloat { 0.8 }
}

struct ShelfGeometry: Equatable {
    var offset: CGFloat = 0
    var contentWidth: CGFloat = 0
    var containerWidth: CGFloat = 0

    var maxOffset: CGFloat { max(0, contentWidth - containerWidth) }
    var isScrollable: Bool { maxOffset > 1 }
    var canScrollBack: Bool { offset > 1 }
    var canScrollForward: Bool { offset < maxOffset - 1 }
}

/// 「查看全部 ›」
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Metrics.spacingXS) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}
