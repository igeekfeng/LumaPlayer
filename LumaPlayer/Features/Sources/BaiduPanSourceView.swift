import SwiftUI

/// 百度网盘那一页(sheet 的根)。
///
/// 按授权状态切三屏:填密钥 → 扫码 → 浏览目录。三屏共用一个 ViewModel,
/// 因为「保存密钥 → 立刻走扫码 → 授权完立刻列目录」是一条连续的流程,
/// 拆成三个 View 各自取状态反而要来回传。
///
/// ⚠️ 它是**独立的一页**,不挂在 `BrowseView` 的导航栈上:百度源与
/// 「当前 Emby 服务器」没关系,塞进 Emby 的栈会让「切服务器 → 清栈」说不通
/// (文档 §6:新增一个平行的源,不改造 Emby 那条路)。
struct BaiduPanSourceView: View {
    let container: AppContainer

    @State private var viewModel: BaiduPanSourceViewModel

    init(container: AppContainer) {
        self.container = container
        self._viewModel = State(initialValue: BaiduPanSourceViewModel(container: container))
    }

    var body: some View {
        content
            .frame(minWidth: 560, minHeight: 460)
            .task { await viewModel.reload() }
    }

    @ViewBuilder
    private var content: some View {
        if let authorization = viewModel.authorization {
            switch authorization {
            case .unconfigured:
                BaiduPanAuthorizationView(viewModel: viewModel)
            case .needsAuthorization:
                BaiduPanAuthorizationView(viewModel: viewModel)
            case .authorized:
                BaiduPanBrowserView(viewModel: viewModel)
            }
        } else if let failure = viewModel.loadFailure {
            failurePane(failure)
        } else {
            ProgressView("正在读取授权状态…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 整页级别的错误(读不出凭据文件之类)。
    ///
    /// ⚠️ 只在 `authorization == nil` 时显示:授权那一屏自己有更合适的
    /// 错误位置(表单里的提示),盖一层整页错误会把表单挤掉,让人没法改。
    private func failurePane(_ failure: LoadFailure) -> some View {
        VStack(spacing: Metrics.spacingL) {
            OnboardingFormHeader(
                systemImage: "exclamationmark.triangle.fill",
                title: "打不开百度网盘",
                subtitle: failure.message
            )
            Button("重试") { Task { await viewModel.reload() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(Metrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
