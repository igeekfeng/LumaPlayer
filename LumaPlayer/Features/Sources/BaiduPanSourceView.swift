import SwiftUI

/// 百度网盘来源的内容页:按授权状态切三屏(填密钥 → 扫码 → 浏览目录)。
/// ⚠️ 它是**主窗口导航栈的根页**,不是独立 sheet —— 「来源」是一层平等的东西,
/// Emby 与百度共用一个导航栈与工具栏。
struct BaiduPanSourceView: View {
    let container: AppContainer
    /// 当前来源(决定 `sourceID` —— 封面缓存 key 按它分区)
    let source: BaiduPanSource
    /// 「Reload」菜单(⌘R)的计数器:变化即重读授权状态与目录
    let refreshToken: Int

    @State private var viewModel: FileSourceViewModel

    init(container: AppContainer, source: BaiduPanSource, refreshToken: Int) {
        self.container = container
        self.source = source
        self.refreshToken = refreshToken
        self._viewModel = State(
            initialValue: FileSourceViewModel(container: container, source: source))
    }

    var body: some View {
        content
            // 授权那两屏也占着主窗口标题栏,给个兜底标题;浏览屏自己的 `navigationTitle` 更靠内层,会覆盖它。
            .navigationTitle("百度网盘")
            // ⌘R:首次进入结构性重载(回片库根),之后只重读当前目录,不把人踢回起点。
            .task(id: refreshToken) { await viewModel.refreshFromToolbar() }
            // 设置里改过来源 → 重读片库根(`refreshLibraryRoot`)。
            // ⚠️ 只有片库根真变了才重载目录,改名 / 增删来源不该白列一次。
            .task(id: container.state.serverListRevision) {
                await viewModel.refreshLibraryRoot()
            }
            // 百度没有服务端进度上报(进度记在本地续播库),播完一场要自己重读,列表才跟得上。
            // ⚠️ 只重读本地续播状态(`refreshResumeState`),⛔ 不重新列目录(2 次百度请求,内容没变)。
            .onChange(of: container.state.lastFinishedPlayback) { _, finished in
                guard finished?.serverID == nil else { return }
                Task { await viewModel.refreshResumeState() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let authorization = viewModel.authorization {
            switch authorization {
            case .unconfigured, .needsAuthorization:
                BaiduPanAuthorizationView(viewModel: viewModel)
            case .authorized:
                FileSourceBrowserView(viewModel: viewModel, store: container.posters)
            }
        } else if let failure = viewModel.loadFailure {
            failurePane(failure)
        } else {
            ProgressView("正在读取授权状态…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 整页级别的错误(读不出凭据文件之类)。
    /// ⚠️ 只在 `authorization == nil` 时显示:授权屏自己有表单内提示,整页错误会把表单挤掉。
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
