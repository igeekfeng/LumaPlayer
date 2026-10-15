import SwiftUI
import AppKit

// MARK: - 主窗口浮动顶栏
//
// ## 为什么不用系统工具栏
//
// 系统工具栏是一条「栏」:有底色、有标题、有分隔,主窗口看起来像个文件管理器;
// 原生全屏时系统还会把它整条搬进独立的 `NSToolbarFullScreenWindow`,
// `.toolbarBackgroundVisibility` / `.scrollEdgeEffect*` / `.windowToolbarFullScreenVisibility`
// 全都不生效(PITFALLS.md Q37)。所以主窗口**整条藏掉系统工具栏**(`.toolbar(.hidden, for: .windowToolbar)`,
// 窗口本身 `.hiddenTitleBar`),返回 / 搜索 / 来源这些按钮画到内容上:没有「栏底」,
// 只有浮在内容上的玻璃圆形按钮,下面垫一层渐变压暗。
//
// ## 布局
//
// 栏挂在导航栈**外层**(`BrowseView`),所有页共用一条;它经 `safeAreaInset(edge: .top)` 占位,
// 普通页面的内容从栏下沿开始,滚上去时从渐变底下穿过;有 hero 的页(详情页、首页)自己
// `ignoresSafeArea(edges: .top)`,图铺到窗口最上沿,栏压在图上。
//
// ## 可见性规则
//
// - **窗口化:常驻**。左上角是系统红绿灯,栏内按钮让出红绿灯那一列(`Metrics.chromeBarLeading`)。
// - **全屏:自动隐藏**,与播放控制栏同一套双规则(DesignTokens.swift「界面规则」):
//   指针静止 `autoHideDelay` 藏、移出窗口 `autoHidePointerExitDelay` 藏,一动鼠标就回来;
//   指针停在栏上 / 搜索框聚焦时钉住。

/// 栏底下垫的那层压暗。
enum BrowseChromeScrim {
    /// 普通页面:窗口底色 → 透明。滚上去的内容在按钮下面被盖住,不和按钮叠字
    case page
    /// 栏压在 hero 图上:很轻的黑色 → 透明,只为让红绿灯与玻璃按钮读得出来
    case hero
}

extension View {
    /// 给主窗口导航栈挂上浮动顶栏,并整条隐藏系统窗口工具栏。
    ///
    /// - Parameters:
    ///   - chrome: 全屏状态与自动隐藏(每个主窗口一份)
    ///   - scrim: 栏底的压暗方式(见 `BrowseChromeScrim`)
    ///   - isLoading: 有内容页在加载 / 刷新 → 栏下沿走一条加载线(`ChromeLoadingLine`)
    ///   - bar: 栏里的内容(返回 / 搜索 / 来源…),由调用方按当前页决定
    func browseChrome<Bar: View>(
        _ chrome: BrowseChromeController,
        scrim: BrowseChromeScrim,
        isLoading: Bool,
        @ViewBuilder bar: () -> Bar
    ) -> some View {
        modifier(BrowseChromeModifier(chrome: chrome, scrim: scrim, isLoading: isLoading, bar: bar()))
    }
}

private struct BrowseChromeModifier<Bar: View>: ViewModifier {
    let chrome: BrowseChromeController
    let scrim: BrowseChromeScrim
    let isLoading: Bool
    let bar: Bar

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                BrowseChromeBarContainer(chrome: chrome, scrim: scrim, isLoading: isLoading, bar: bar)
            }
            // 整体铺到窗口最上沿:栏落在红绿灯那一带,内容的安全区从栏下沿算起
            .ignoresSafeArea(.container, edges: .top)
            .toolbar(.hidden, for: .windowToolbar)
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
    let bar: Bar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: Metrics.spacingM) {
            bar
        }
        // 全屏没有红绿灯,不用让出那一列
        .padding(.leading, chrome.isFullScreen ? Metrics.spacingXL : Metrics.chromeBarLeading)
        .padding(.trailing, Metrics.spacingXL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.chromeBarHeight)
        .background {
            scrimView
                // 隐藏标题栏后窗口只能靠这一条拖动(按钮之间的空白处)
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
        // 栏藏起来时顶部整条不挡页面操作(滚动 / 点卡片)
        .allowsHitTesting(chrome.isVisible)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: Metrics.animationStandard),
            value: chrome.isVisible
        )
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

/// 返回按钮(⌘[)。
struct ChromeBackButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .keyboardShortcut("[", modifiers: .command)
        .help("返回(⌘[)")
        .accessibilityLabel("返回")
    }
}

/// 紧凑搜索胶囊(⌘F 聚焦)。提交式:回车才搜,不随输入逐字请求(服务器低频纪律,见 SearchViewModel)。
/// 聚焦期间栏钉住,否则字没输完栏先淡出了。
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

/// 栏下沿的加载线:有内容页在加载 / 刷新时出现(DesignTokens.swift「界面规则」加载态)。
///
/// 一小段强调色在整条宽度上来回扫。用 `TimelineView` 按时间算位置(与旧的刷新图标同一做法):
/// `isLoading` 一变假整条视图就移除,不会有停不干净的 `repeatForever` 动画。
/// 「减少动态效果」下不扫,显示一条静止的半透明线。
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

    /// 一个周期内从左外侧扫到右外侧(进出都不露头)
    private func offset(at date: Date, total: CGFloat, segment: CGFloat) -> CGFloat {
        let period = Metrics.chromeLoadingLinePeriod
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return -segment + (total + segment) * phase
    }
}

// MARK: - 状态

extension EnvironmentValues {
    /// 当前主窗口的顶栏状态。页面经它登记**自己的返回动作**(百度目录的「上一层」),
    /// 不在主窗口里时为 nil。
    @Entry var browseChrome: BrowseChromeController?
}

/// 顶栏的「环境状态」:当前窗口是否全屏、栏是否可见,以及页面登记的返回动作。
///
/// 全屏通知按窗口实例过滤(主窗口),不拿 `NSApp.keyWindow`
/// (播放器窗口进 / 退全屏时主窗口会误判,与 PITFALLS.md Q19 同类)。
@MainActor
@Observable
final class BrowseChromeController: NSObject {
    private(set) var isFullScreen = false
    private(set) var isVisible = true

    /// 页面自己的「返回」(导航栈之外的层级,目前只有百度目录的上一层)。
    /// nil = 页面没有自己的返回;导航栈不空时栈优先(见 `BrowseView.backAction`)。
    var pageBackAction: (@MainActor () -> Void)?
    /// 首页顶部有没有 hero(`HomeHeroSlot` 上报)。有就把栏底换成 hero 的压暗
    /// (`BrowseView` 只在栈空且来源是 Emby 时读它)。
    var rootHasHero = false

    @ObservationIgnored private weak var window: NSWindow?
    /// 指针停在栏上 / 搜索框聚焦:到点也不藏(两样分开记,任一为真就钉住)
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(enteredFullScreen),
            name: NSWindow.didEnterFullScreenNotification, object: newWindow)
        NotificationCenter.default.addObserver(
            self, selector: #selector(exitedFullScreen),
            name: NSWindow.didExitFullScreenNotification, object: newWindow)
    }

    /// 指针在页面上移动:窗口化无所谓(常驻),全屏下显示并重新计时。
    func pointerMoved() {
        guard isFullScreen else { return }
        reveal()
    }

    /// 指针移出窗口:窗口化无所谓,全屏下按更短的延迟藏。
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

    /// 显示栏;全屏下 `delay` 后自动藏(钉住时不藏)。
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
