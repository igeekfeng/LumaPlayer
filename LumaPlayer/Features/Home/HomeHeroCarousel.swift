import SwiftUI

/// 首页顶部的 hero **轮播**:几张随机推荐轮流铺满,8 秒自动一张,
/// 也可以点右侧箭头 / 底部圆点手动切。
///
/// **为什么现在是轮播**(2026-10-15 改的,这块以前写死「⛔ 不轮播」):
/// 当时的理由是「轮播要么多发图片请求,要么换图时首屏跳」。核对后
/// **「换图首屏跳」这条不成立** —— `HomeHero.height(forWidth:)` 是按窗口宽度算的
/// 固定值(`homeHeroHeightRatio` 夹在上下限之间),标题 / 简介 / 按钮全是 overlay,
/// 换图不改动任何布局。所以只剩图片请求这一条代价,靠「只轮几张 + 提前预取
/// 下一张的背景图」把它按住。⛔ 旧理由不再成立,别照抄回去。
///
/// **背景图取不到的项会被跳过**:列表里有 backdrop tag 不等于真取得到(有的服务器回填的是
/// `Primary` 的 tag,请求直接 404,`EmbyItem.coverImageFallback`)。`HomeHero` 回报失败后
/// 这一项从轮播里拿掉 —— 否则那一页只剩一张被拉满整宽的模糊海报。全部失败时保留原列表,
/// 用 `HomeHero` 的模糊底图 + 小封面兜着,不让 hero 整块消失。
///
/// 一张时自动退化成静默的单张(推荐拿不到、退回「继续观看 / 各库最新」那张):
/// 不给箭头也不给圆点 —— 只有一个点的分页控件纯属噪音。
///
/// 自动切换在三种情况下停:**系统开了「减弱动态效果」**、**指针停在 hero 上**
/// (面板正在被阅读,或在瞄「播放」按钮 —— 内容在手下换掉是很难受的)、
/// **窗口不是 key**(切到别的 App)。手动切换不受影响。
struct HomeHeroCarousel: View {
    /// 至少一项。空数组由调用方处理 —— `heroPick` 返回 `.none` 时整个 hero 不画。
    let items: [EmbyItem]
    let serverID: UUID
    let store: PosterImageStore
    let onPlay: (EmbyItem) -> Void
    /// 正在定位分集的剧集 id(`HomeViewModel.resolvingSeriesID`),对应那一项的按钮转圈
    var resolvingItemID: String?
    let onOpenDetail: (EmbyItem) -> Void

    /// 自动切换间隔。不是设计 token,与布局无关;8 秒是 Emby Web hero 与
    /// 常见「焦点轮播」的量级(短于它读不完标题,长于它等于没在轮)。
    static let interval: Duration = .seconds(8)

    @State private var index = 0
    /// 背景图试过且没拿到的项(见类型注释)
    @State private var backdropUnavailable: Set<String> = []
    /// 指针在 hero 上(暂停自动切换,见类型注释)
    @State private var isHovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    /// 实际参与轮播的项:去掉背景图取不到的;全去掉了就退回原列表
    private var shownItems: [EmbyItem] {
        let usable = items.filter { !backdropUnavailable.contains($0.id) }
        return usable.isEmpty ? items : usable
    }

    private var canRotate: Bool { shownItems.count > 1 }

    var body: some View {
        ZStack {
            // 同时只挂当前这一项:其余项不进视图树,它们的背景图也就不会被请求
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
                    // 换了一项就整块重建:Logo 取不到的标记不能带到下一项上
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

    /// 左右箭头,贴在右侧、垂直居中。仅轮播时出现。
    ///
    /// 强制深色外观(白图标叠在玻璃上):它们永远压在**照片**上,
    /// 与系统深浅色无关 —— 和 `HomeHero.info` 同一处理。
    @ViewBuilder
    private var arrows: some View {
        if canRotate {
            HStack(spacing: Metrics.spacingS) {
                arrowButton("chevron.left", label: "上一张推荐") { step(-1) }
                arrowButton("chevron.right", label: "下一张推荐") { step(1) }
            }
            .padding(.trailing, Metrics.spacingXL)
            // 在图片区里垂直居中,不算下面的过渡带
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

    /// 分页圆点,贴图片区右下角(过渡带之上)。压在照片上,所以和箭头一样强制白色;
    /// ⛔ 别挪进过渡带 —— 那里浅色模式下渐变成白色,白点看不见。
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

    /// 从 `index` 走 `delta` 步(可负),在 `count` 张里**循环**。
    ///
    /// 抽成静态纯函数是为了能单测:轮播的边界(最后一张往后、第一张往前)
    /// 是最容易写错、又最难在界面上看出来的地方 —— 错了就只是「有时不换」。
    static func wrap(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        // Swift 的 % 对负数给负余数,先取模再加一轮
        return ((index + delta) % count + count) % count
    }

    /// 该不该自动切换。所有前提在一处表达(理由见类型注释):
    /// 至少两张、没开「减弱动态效果」、指针不在 hero 上、窗口是 key —— 缺一不可。
    static func shouldAutoAdvance(
        itemCount: Int,
        reduceMotion: Bool,
        isHovering: Bool,
        isWindowActive: Bool
    ) -> Bool {
        itemCount > 1 && !reduceMotion && !isHovering && isWindowActive
    }

    /// 自动切换的开关组合。`.task(id:)` 据此重建任务:
    /// 「减弱动态效果」打开 / 指针进入 / 窗口失去 key 都会让它立刻停下来。
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
            // 被取消(`.task(id:)` 换了 token)就退出 —— 新任务会按新状态重开
            guard !Task.isCancelled else { return }
            guard canAutoAdvance else { return }
            step(1)
        }
    }

    private func step(_ delta: Int) {
        guard canRotate else { return }
        index = Self.wrap(index, by: delta, count: shownItems.count)
    }

    /// 提前把**下一张的背景图**拉进缓存,换过去时不白屏。
    ///
    /// 只预取背景图:`HomeHero` 换图时看得见的延迟就是那张 1920 宽的图。
    /// 模糊底图用的是 300 宽的竖版海报,量级小得多,留给 `HomeHero` 按需拉 ——
    /// 多预取一张只是给服务器和磁盘缓存添麻烦。
    ///
    /// 结果不关心:预取失败就退化成「换过去时现拉」,与完全没预取一样,
    /// 而 `PosterImage` 本来就会在失败时停在模糊底图上(不弹窗、不重试风暴)。
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
