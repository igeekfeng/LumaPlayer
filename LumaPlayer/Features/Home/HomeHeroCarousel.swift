import SwiftUI

/// hero 轮播:几张推荐轮流铺满,定时自动切,也可点箭头 / 圆点手动切。
/// 换图不改布局(`HomeHero.height(forWidth:)` 只看宽度),代价只有图片请求,靠「只轮几张 + 预取下一张」按住。
///
/// 背景图取不到的项会被跳过(有 tag 不等于取得到,见 `EmbyItem.coverImageFallback`);
/// 全部失败时保留原列表,由 `HomeHero` 的模糊底图兜着。
/// 一张时退化成静默的单张,不给箭头和圆点。
///
/// 自动切换在这些情况下停:系统开了「减弱动态效果」、指针停在 hero 上(内容别在手下换掉)、
/// 窗口不是 key。手动切换不受影响。
struct HomeHeroCarousel: View {
    /// 至少一项;`.none` 时调用方不画 hero
    let items: [EmbyItem]
    let serverID: UUID
    let store: PosterImageStore
    let onPlay: (EmbyItem) -> Void
    /// `HomeViewModel.resolvingSeriesID`
    var resolvingItemID: String?
    let onOpenDetail: (EmbyItem) -> Void

    /// 不是设计 token。短了读不完标题,长了等于没在轮。
    static let interval: Duration = .seconds(8)

    @State private var index = 0
    @State private var backdropUnavailable: Set<String> = []
    @State private var isHovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    /// 去掉背景图取不到的;全去掉了就退回原列表
    private var shownItems: [EmbyItem] {
        let usable = items.filter { !backdropUnavailable.contains($0.id) }
        return usable.isEmpty ? items : usable
    }

    private var canRotate: Bool { shownItems.count > 1 }

    var body: some View {
        ZStack {
            // 只挂当前这一项,其余项的背景图不会被请求
            ForEach(Array(shownItems.enumerated()), id: \.element.id) { offset, item in
                if offset == min(index, shownItems.count - 1) {
                    HomeHero(
                        item: item,
                        serverID: serverID,
                        store: store,
                        onPlay: { onPlay(item) },
                        isResolvingPlayback: resolvingItemID == item.id,
                        onOpenDetail: { onOpenDetail(item) },
                        onBackdropUnavailable: { backdropUnavailable.insert(item.id) }
                    )
                    // 整块重建:Logo 取不到的标记不能带到下一项
                    .id(item.id)
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: Metrics.animationSlow), value: index)
        .overlay(alignment: .trailing) { arrows }
        .overlay(alignment: .bottomTrailing) { dots }
        .onChange(of: shownItems.count) { _, count in
            if index >= count { index = 0 }
        }
        .onHover { isHovering = $0 }
        .onChange(of: index) { _, new in prefetchBackdrop(after: new) }
        .task(id: autoAdvanceToken) { await autoAdvance() }
    }

    // MARK: - 控件

    /// 强制深色外观:永远压在照片上,同 `HomeHero.info`。
    @ViewBuilder
    private var arrows: some View {
        if canRotate {
            HStack(spacing: Metrics.spacingS) {
                arrowButton("chevron.left", label: "上一张推荐") { step(-1) }
                arrowButton("chevron.right", label: "下一张推荐") { step(1) }
            }
            .padding(.trailing, Metrics.spacingXL)
            // 在图片区里垂直居中,不算过渡带
            .padding(.bottom, Metrics.homeHeroFadeBand)
            .environment(\.colorScheme, .dark)
        }
    }

    private func arrowButton(_ symbol: String, label: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .accessibilityLabel(label)
    }

    /// 白色圆点贴图片区右下角。⛔ 别挪进过渡带:浅色模式下那里是白的。
    @ViewBuilder
    private var dots: some View {
        if canRotate {
            HStack(spacing: Metrics.spacingS) {
                ForEach(shownItems.indices, id: \.self) { offset in
                    Button {
                        index = offset
                    } label: {
                        Circle()
                            .fill(Color.white.opacity(offset == index ? 1 : 0.35))
                            .frame(width: Metrics.heroDotSize, height: Metrics.heroDotSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("第 \(offset + 1) 张推荐")
                    .accessibilityAddTraits(offset == index ? [.isSelected] : [])
                }
            }
            .padding(.trailing, Metrics.spacingXL)
            .padding(.bottom, Metrics.homeHeroFadeBand + Metrics.spacingM)
        }
    }

    // MARK: - 切换

    /// 走 `delta` 步(可负),在 `count` 张里循环。
    static func wrap(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        // Swift 的 % 对负数给负余数,先取模再加一轮
        return ((index + delta) % count + count) % count
    }

    /// 前提见类型注释,缺一不可。
    static func shouldAutoAdvance(
        itemCount: Int,
        reduceMotion: Bool,
        isHovering: Bool,
        isWindowActive: Bool
    ) -> Bool {
        itemCount > 1 && !reduceMotion && !isHovering && isWindowActive
    }

    /// `.task(id:)` 据此重建任务,任一前提变化立刻生效。
    private var autoAdvanceToken: String {
        "\(shownItems.count)|\(reduceMotion)|\(isHovering)|\(isWindowActive)"
    }

    private var isWindowActive: Bool {
        switch controlActiveState {
        case .key: return true
        default: return false
        }
    }

    private var canAutoAdvance: Bool {
        Self.shouldAutoAdvance(
            itemCount: shownItems.count,
            reduceMotion: reduceMotion,
            isHovering: isHovering,
            isWindowActive: isWindowActive
        )
    }

    private func autoAdvance() async {
        guard canAutoAdvance else { return }
        while true {
            try? await Task.sleep(for: Self.interval)
            // token 变了会取消,新任务按新状态重开
            guard !Task.isCancelled else { return }
            guard canAutoAdvance else { return }
            step(1)
        }
    }

    private func step(_ delta: Int) {
        guard canRotate else { return }
        index = Self.wrap(index, by: delta, count: shownItems.count)
    }

    /// 只预取下一张的背景图(看得见的延迟就是这张大图),海报小,留给按需拉。
    /// 失败就退化成换过去时现拉,所以不关心结果。
    private func prefetchBackdrop(after index: Int) {
        let items = shownItems
        guard canRotate, items.indices.contains(index),
              let source = items[(index + 1) % items.count].backdropSource else { return }
        let spec = ImageSpec(
            serverID: serverID,
            itemID: source.itemID,
            type: .backdrop,
            tag: source.tag,
            maxWidth: Int(Metrics.homeHeroImageMaxWidth)
        )
        Task { _ = try? await store.image(for: spec) }
    }
}
