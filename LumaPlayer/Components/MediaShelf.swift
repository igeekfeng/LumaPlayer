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
            // 翻页按钮只在内容可滚时出现,按自然高度排版会让标题行在 19 / 24pt 之间跳,
            // 那一行数据到达(或货架换宽度)时整页就跟着动。钉住最小高度,见 `Metrics.shelfHeaderMinHeight`。
            .frame(minHeight: Metrics.shelfHeaderMinHeight, alignment: .leading)
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

/// 分集横排下方的滚动条,与 Emby 详情页同一副样子:覆盖式、无轨道底条,只在悬停或滚动时出现、
/// 停下后延迟淡出。按下轨道任意处滑块跳过去,接着拖连续滚。集数极多时用最小宽度保证点得中。
struct ShelfScrubber: View {
    @Binding var position: ScrollPosition
    let geometry: ShelfGeometry
    /// 由外层传入
    let isHovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 决定滑块深浅
    @State private var isHoveringThumb = false
    @State private var isScrolling = false
    @State private var hideTask: Task<Void, Never>?

    private var isVisible: Bool { isHovering || isHoveringThumb || isScrolling }

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = proxy.size.width
            let thumbWidth = thumbWidth(trackWidth: trackWidth)
            let travel = max(0, trackWidth - thumbWidth)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHoveringThumb
                                                ? Metrics.shelfScrubberThumbOpacityHover
                                                : Metrics.shelfScrubberThumbOpacity))
                    .frame(width: thumbWidth, height: Metrics.shelfScrubberThumbHeight)
                    .offset(x: travel * progress)
            }
            // 必须 .leading:ZStack 固有宽度只剩滑块,.center 会先居中再叠 offset,位置全偏
            .frame(width: trackWidth, height: proxy.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(scrubGesture(trackWidth: trackWidth, thumbWidth: thumbWidth))
        }
        .frame(height: Metrics.shelfScrubberHitHeight)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: Metrics.animationStandard), value: isVisible)
        .animation(.easeOut(duration: Metrics.animationFast), value: isHoveringThumb)
        .onHover { isHoveringThumb = $0 }
        .onChange(of: geometry.offset) { _, _ in flashWhileScrolling() }
        .onDisappear { hideTask?.cancel() }
        .accessibilityElement()
        .accessibilityLabel("分集滚动条")
        .accessibilityValue("已滚动 \(Int((progress * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: page(by: 1)
            case .decrement: page(by: -1)
            @unknown default: break
            }
        }
    }

    private func flashWhileScrolling() {
        isScrolling = true
        hideTask?.cancel()
        hideTask = Task {
            do {
                try await Task.sleep(for: .seconds(Metrics.shelfScrubberHideDelay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            isScrolling = false
        }
    }

    /// 滑块中心跟手:按下即跳、拖动即连续滚。
    private func scrubGesture(trackWidth: CGFloat, thumbWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard geometry.maxOffset > 0 else { return }
                let travel = max(1, trackWidth - thumbWidth)
                let half = thumbWidth / 2
                let x = min(max(value.location.x, half), trackWidth - half)
                let progress = (x - half) / travel
                position.scrollTo(x: progress * geometry.maxOffset)
            }
    }

    /// 容器占内容的比例;内容宽度未知时先占满
    private func thumbWidth(trackWidth: CGFloat) -> CGFloat {
        guard geometry.contentWidth > 0 else { return trackWidth }
        let ratio = geometry.containerWidth / geometry.contentWidth
        return max(Metrics.shelfScrubberThumbMinWidth, min(trackWidth, trackWidth * ratio))
    }

    /// 0...1
    private var progress: CGFloat {
        guard geometry.maxOffset > 0 else { return 0 }
        return min(max(geometry.offset / geometry.maxOffset, 0), 1)
    }

    /// 键盘 / VoiceOver 调节,一次翻大半屏(同翻页按钮)
    private func page(by direction: CGFloat) {
        let step = geometry.containerWidth * Self.pageFraction * direction
        let target = min(max(0, geometry.offset + step), geometry.maxOffset)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: Metrics.animationStandard)) {
            position.scrollTo(x: target)
        }
    }

    private static var pageFraction: CGFloat { 0.8 }
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
