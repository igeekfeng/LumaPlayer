import SwiftUI

/// 同一时刻屏幕上只有一页,按页面类型区分即可(`MediaDetailView` 多页共用一个标识,见 `AppState.setPageLoading`)。
enum ContentPage: String, Sendable {
    case home
    case library
    case search
    case detail
}

/// 内容页把加载 / 刷新状态上报给 `AppState`,顶栏据此显示加载线、⌘R 据此禁用。
/// 用 `.onChange(of:initial:)`,⛔ 不在 `body` 里直接写(会触发「Modifying state during view update」)。
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
    /// 见 `PageLoadingReporter`。
    func reportsPageLoading(_ isLoading: Bool, page: ContentPage, to state: AppState) -> some View {
        modifier(PageLoadingReporter(isLoading: isLoading, page: page, state: state))
    }
}
