import SwiftUI

/// 横向货架:标题 +「查看全部」+ 左右翻页按钮(鼠标用户没法横滑)。按钮在标题行右侧,不遮卡片。
struct MediaShelf<Content: View>: View {
    let title: String
    /// 有值时标题旁出现「查看全部」
    var seeAll: (() -> Void)? = nil
    /// 上次离开界面时的横向偏移。货架随页面切换被销毁,位置只能由调用方留存
    var initialOffset: CGFloat = 0
    /// 货架被移出界面时回写当前偏移
    var onLeave: ((CGFloat) -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var position = ScrollPosition()
    @State private var geometry = ShelfGeometry()
    /// 待复位的偏移。等量出内容宽度再滚:那时才知道 `maxOffset`,内容变少时能夹住
    @State private var pendingRestore: CGFloat?

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
                if let target = pendingRestore, new.contentWidth > 0 {
                    pendingRestore = nil
                    position.scrollTo(x: min(target, new.maxOffset))
                }
            }
            // 重建(返回上一级)后回到原来的横向位置。放在 `task` 而不是 `onAppear`:
            // 那时已经过一轮布局,滚动请求不会落空;量宽回调晚到时再夹一次
            .task {
                guard initialOffset > 1 else { return }
                pendingRestore = initialOffset
                position.scrollTo(x: initialOffset)
            }
            .onDisappear { onLeave?(geometry.offset) }
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
