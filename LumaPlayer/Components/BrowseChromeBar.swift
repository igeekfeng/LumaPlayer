import SwiftUI
import AppKit

// MARK: - 主窗口浮动顶栏
//
// 不让系统建工具栏:原生全屏时它被搬进 `NSToolbarFullScreenWindow`,各种 toolbar / scrollEdge 修饰都不生效
// (PITFALLS.md Q37)。所以窗口 `.hiddenTitleBar`、不声明 `.toolbar` 项、`.toolbar(removing: .title)`、
// push 页 `.navigationBarBackButtonHidden(true)`(系统返回按钮会建出 NSToolbar),按钮画到内容上。
// ⛔ 不用 `.toolbar(.hidden, for: .windowToolbar)`:红绿灯会跟着消失(PITFALLS.md)。
//
// 栏挂在导航栈外层(`BrowseView`),经 `safeAreaInset(edge: .top)` 占位;hero 页自己
// `ignoresSafeArea(edges: .top)`,栏压在图上。
//
// - 窗口化常驻:按钮让出红绿灯那一列;返回 chevron 中心与红绿灯同高(`trafficLightCenterY`),紧挨其右。
// - 全屏自动隐藏,同播放控制栏双规则(DesignTokens.swift「界面规则」);指针停在栏上 / 搜索框聚焦时钉住。

enum BrowseChromeScrim {
    /// 窗口底色 → 透明,滚上去的内容不和按钮叠字
    case page
    /// 很轻的黑色 → 透明,让红绿灯与玻璃按钮读得出来
    case hero
}

extension View {
    /// - Parameters:
    ///   - chrome: 每个主窗口一份
    ///   - back: nil = 不画返回
    ///   - bar: 栏右侧内容(搜索 / 来源…)
    func browseChrome<Bar: View>(
        _ chrome: BrowseChromeController,
        scrim: BrowseChromeScrim,
        isLoading: Bool,
        back: (@MainActor () -> Void)?,
        @ViewBuilder bar: () -> Bar
    ) -> some View {
        modifier(BrowseChromeModifier(
            chrome: chrome, scrim: scrim, isLoading: isLoading, back: back, bar: bar()))
    }
}

private struct BrowseChromeModifier<Bar: View>: ViewModifier {
    let chrome: BrowseChromeController
    let scrim: BrowseChromeScrim
    let isLoading: Bool
    let back: (@MainActor () -> Void)?
    let bar: Bar

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                BrowseChromeBarContainer(
                    chrome: chrome, scrim: scrim, isLoading: isLoading, back: back, bar: bar)
            }
            // 整体铺到窗口最上沿:栏落在红绿灯那一带,内容的安全区从栏下沿算起
            .ignoresSafeArea(.container, edges: .top)
            .toolbar(removing: .title)
            // 指针追踪挂在整页上:在页面任何位置动鼠标都要把栏叫回来
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    chrome.pointerMoved()
                case .ended:
                    chrome.pointerExited()
                }
            }
            .background(WindowReader { chrome.bind(window: $0) })
            .environment(\.browseChrome, chrome)
    }
}

private struct BrowseChromeBarContainer<Bar: View>: View {
    @Bindable var chrome: BrowseChromeController
    let scrim: BrowseChromeScrim
    let isLoading: Bool
    let back: (@MainActor () -> Void)?
    let bar: Bar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: Metrics.spacingM) {
            bar
        }
        .padding(.trailing, Metrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        // 返回单独定位:窗口化与红绿灯同高;全屏在栏里居中靠左
        .overlay(alignment: .topLeading) {
            if let back {
                ChromeBackButton(action: back, onHero: scrim == .hero)
                    .frame(height: backRowHeight)
                    .padding(.leading, chrome.isFullScreen ? Metrics.spacingXL : Metrics.chromeBarLeading)
            }
        }
        .frame(height: Metrics.chromeBarHeight)
        .background {
            scrimView
                // 隐藏标题栏后窗口只能靠这一条拖动
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        }
        .overlay(alignment: .bottom) {
            if isLoading {
                ChromeLoadingLine()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: Metrics.animationFast), value: isLoading)
        .onHover { chrome.setHovering($0) }
        .opacity(chrome.isVisible ? 1 : 0)
        // 藏起来时不挡页面操作
        .allowsHitTesting(chrome.isVisible)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: Metrics.animationStandard),
            value: chrome.isVisible
        )
    }

    /// 返回按钮在这一行里居中,所以行高 = 2 × 红绿灯中心距上沿
    private var backRowHeight: CGFloat {
        chrome.isFullScreen ? Metrics.chromeBarHeight : chrome.trafficLightCenterY * 2
    }

    @ViewBuilder
    private var scrimView: some View {
        switch scrim {
        case .page:
            LinearGradient(
                stops: [
                    .init(color: Color(nsColor: .windowBackgroundColor), location: 0),
                    .init(color: Color(nsColor: .windowBackgroundColor), location: Metrics.chromeScrimSolidFraction),
                    .init(color: Color(nsColor: .windowBackgroundColor).opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .hero:
            LinearGradient(
                colors: [.black.opacity(Metrics.chromeHeroScrimOpacity), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - 栏里的部件

/// 返回按钮(⌘[)。⛔ 不加玻璃圆底:它是标题栏控件的延续(同 Finder),套圆底比红绿灯还抢眼。
struct ChromeBackButton: View {
    let action: @MainActor () -> Void
    let onHero: Bool

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.title3.weight(.semibold))
                .foregroundStyle(onHero ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .opacity(isHovering ? 1 : Metrics.chromeBackIdleOpacity)
                .frame(width: Metrics.chromeBackHitSize, height: Metrics.chromeBackHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
        .keyboardShortcut("[", modifiers: .command)
        .help("返回(⌘[)")
        .accessibilityLabel("返回")
    }
}

/// 搜索胶囊(⌘F 聚焦)。回车才搜,⛔ 不逐字请求(服务器低频纪律)。聚焦期间栏钉住。
struct ChromeSearchField: View {
    @Binding var text: String
    let chrome: BrowseChromeController
    let onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.spacingXS) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索电影与剧集", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(onSubmit)
                .onExitCommand { isFocused = false }
                .frame(width: Metrics.chromeSearchWidth)
        }
        .padding(.horizontal, Metrics.spacingM)
        .frame(height: Metrics.chromeSearchHeight)
        .glassEffect(.regular, in: .capsule)
        .background {
            // ⌘F:看不见的按钮只为挂快捷键(主窗口是 key window 时才生效,不影响播放器窗口)
            Button("搜索") {
                chrome.reveal()
                isFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .onChange(of: isFocused) { _, focused in
            chrome.setSearchFocused(focused)
        }
        .help("搜索电影与剧集(⌘F,回车搜索)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("搜索电影与剧集")
    }
}

/// 栏下沿的加载线(DesignTokens.swift「界面规则」加载态)。用 `TimelineView` 按时间算位置,
/// ⛔ 不用 `repeatForever`(移除时停不干净)。「减少动态效果」下显示静止线。
struct ChromeLoadingLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if reduceMotion {
                Rectangle()
                    .fill(Color.accentColor.opacity(Metrics.chromeLoadingLineStaticOpacity))
            } else {
                TimelineView(.animation) { timeline in
                    let width = proxy.size.width * Metrics.chromeLoadingLineSegmentFraction
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: width)
                        .offset(x: offset(at: timeline.date, total: proxy.size.width, segment: width))
                }
            }
        }
        .frame(height: Metrics.chromeLoadingLineHeight)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("正在加载")
    }

    /// 从左外侧扫到右外侧
    private func offset(at date: Date, total: CGFloat, segment: CGFloat) -> CGFloat {
        let period = Metrics.chromeLoadingLinePeriod
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return -segment + (total + segment) * phase
    }
}

// MARK: - 状态

extension EnvironmentValues {
    /// 不在主窗口里时为 nil。
    @Entry var browseChrome: BrowseChromeController?
}

/// 全屏通知按窗口实例过滤,⛔ 不用 `NSApp.keyWindow`(播放器窗口进退全屏会误判,同 PITFALLS.md Q19)。
@MainActor
@Observable
final class BrowseChromeController: NSObject {
    private(set) var isFullScreen = false
    private(set) var isVisible = true

    /// 导航栈之外的返回(百度目录的上一层);栈不空时栈优先(`BrowseView.backAction`)。
    var pageBackAction: (@MainActor () -> Void)?
    /// 根页顶部有 hero 的来源,有就把栏底换成 hero 压暗;`BrowseView` 只在栈空时读。
    /// 按来源 id 记,⛔ 不改成布尔:换来源时新旧根页的上报先后不定,布尔会被后到的覆盖。
    private(set) var heroRootSources: Set<UUID> = []

    func setRootHasHero(_ hasHero: Bool, source: UUID) {
        if hasHero {
            heroRootSources.insert(source)
        } else {
            heroRootSources.remove(source)
        }
    }

    @ObservationIgnored private weak var window: NSWindow?
    /// 任一为真就钉住
    @ObservationIgnored private var isHovering = false
    @ObservationIgnored private var isSearchFocused = false
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    private var isPinned: Bool { isHovering || isSearchFocused }

    func bind(window newWindow: NSWindow?) {
        guard newWindow !== window else { return }
        if let old = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didEnterFullScreenNotification, object: old)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: old)
        }
        window = newWindow
        guard let newWindow else { return }
        isFullScreen = newWindow.styleMask.contains(.fullScreen)
        // 按钮要在下一轮布局之后才有位置
        Task { @MainActor [weak self, weak newWindow] in
            await Task.yield()
            guard let self, let newWindow else { return }
            self.measureTrafficLights(in: newWindow)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(enteredFullScreen),
            name: NSWindow.didEnterFullScreenNotification, object: newWindow)
        NotificationCenter.default.addObserver(
            self, selector: #selector(exitedFullScreen),
            name: NSWindow.didExitFullScreenNotification, object: newWindow)
    }

    func pointerMoved() {
        guard isFullScreen else { return }
        reveal()
    }

    func pointerExited() {
        guard isFullScreen else { return }
        reveal(delay: Metrics.autoHidePointerExitDelay)
    }

    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        pinChanged()
    }

    func setSearchFocused(_ focused: Bool) {
        isSearchFocused = focused
        pinChanged()
    }

    /// 全屏下 `delay` 后自动藏(钉住时不藏)。
    func reveal(delay: TimeInterval = Metrics.autoHideDelay) {
        if !isVisible { isVisible = true }
        hideTask?.cancel()
        guard isFullScreen else { return }
        hideTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.isFullScreen, !self.isPinned else { return }
            self.isVisible = false
            // 指针跟着栏一起藏,一动鼠标系统自动恢复(与播放控制栏一致)
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// 红绿灯中心距窗口上沿;读不到时为栏高的一半。
    private(set) var trafficLightCenterY: CGFloat = Metrics.chromeBarHeight / 2

    private func measureTrafficLights(in window: NSWindow) {
        guard let button = window.standardWindowButton(.closeButton),
              let content = window.contentView,
              button.window === window else { return }
        let rect = button.convert(button.bounds, to: content)
        let fromTop = content.isFlipped ? rect.midY : content.bounds.height - rect.midY
        guard fromTop > 0, fromTop < Metrics.chromeBarHeight else { return }
        trafficLightCenterY = fromTop
    }

    private func pinChanged() {
        if isPinned {
            hideTask?.cancel()
            if !isVisible { isVisible = true }
        } else if isFullScreen {
            reveal()
        }
    }

    @objc
    private func enteredFullScreen() {
        isFullScreen = true
        // 进全屏先给一栏(即便指针没动),静止后自动收
        reveal()
    }

    @objc
    private func exitedFullScreen() {
        isFullScreen = false
        hideTask?.cancel()
        isVisible = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
