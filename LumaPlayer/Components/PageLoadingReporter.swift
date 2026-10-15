import SwiftUI

/// 内容页的标识。同一时刻屏幕上只有一页,用页面类型区分即可
/// (`MediaDetailView` 允许栈上存在多页,共用一个标识 —— 影响见 `AppState.setPageLoading`)。
enum ContentPage: String, Sendable {
    case home
    case library
    case search
    case detail
}

/// 内容页把「自己正在加载 / 刷新」上报给 `AppState`,主窗口顶栏据此显示加载线、
/// 「Reload」菜单(⌘R)据此禁用(DesignTokens.swift「界面规则」)。
///
/// 用 `.onChange(of:initial:)` 而不是在 `body` 里直接写:写 `@Observable` 属性会通知,
/// 在求值过程中改状态会触发「Modifying state during view update」告警。
/// 页面首次出现(`initial: true`)与每次状态变化都上报;离开时从集合里退出。
private struct PageLoadingReporter: ViewModifier {
    let isLoading: Bool
    let page: ContentPage
    let state: AppState

    func body(content: Content) -> some View {
        content
            .onChange(of: isLoading, initial: true) { _, newValue in
                state.setPageLoading(newValue, page: page)
            }
            .onDisappear {
                state.setPageLoading(false, page: page)
            }
    }
}

extension View {
    /// 把当前页面的加载状态上报给顶栏(见 `PageLoadingReporter`)。
    func reportsPageLoading(_ isLoading: Bool, page: ContentPage, to state: AppState) -> some View {
        modifier(PageLoadingReporter(isLoading: isLoading, page: page, state: state))
    }
}
