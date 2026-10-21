import SwiftUI

/// 根视图:按 AppState.route 切换;挂载时做一次会话恢复。
struct RootView: View {
    let container: AppContainer

    var body: some View {
        Group {
            switch container.state.route {
            case .launching:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .onboarding:
                AddSourceView(container: container)
            case .browse:
                BrowseView(container: container)
            }
        }
        .task {
            await container.restoreSession()
            // 维护放在恢复之后:不拖慢进首页,清理本身只碰本地文件
            await container.cleanUpSubtitleCache()
        }
        .alert(
            "启动错误",
            isPresented: Binding(
                get: { container.state.startupError != nil },
                set: { if !$0 { container.state.startupError = nil } }
            )
        ) {
            Button("好") {}
        } message: {
            Text(container.state.startupError?.localizedDescription ?? "")
        }
    }
}
