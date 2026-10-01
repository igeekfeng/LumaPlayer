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
                AddServerView(container: container)
            case .browse:
                BrowseView(container: container)
            }
        }
        .task {
            await container.restoreSession()
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
