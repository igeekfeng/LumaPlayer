import SwiftUI

/// 夸克网盘来源的内容页:按登录状态切两屏(扫码 → 浏览)。
///
/// 与另外两家同一个浏览页(`FileSourceBrowserView`),差别在登录:夸克 TV 端没有应用配置,
/// 凭据是扫码换来的 token 四件套(`docs/QUARK_API.md` §4)。
///
/// ⚠️ 它是**主窗口导航栈的根页**,不是独立 sheet。
/// ⚠️ 这个来源**只读**(§9):浏览页因此不给「删除」入口,只给「隐藏」。
struct QuarkSourceView: View {
    let container: AppContainer
    /// 当前来源(决定 `sourceID` —— 封面 / 续播 / 隐藏项都按它分区)
    let source: QuarkSource
    /// 「Reload」菜单(⌘R)的计数器:变化即重读登录状态与目录
    let refreshToken: Int

    /// 由 `BrowseView` 按来源 id 持有(`FileSourceViewModelStore`):切到别的来源再切回来停在原处
    let viewModel: FileSourceViewModel

    var body: some View {
        content
            // 扫码屏也占着主窗口标题栏,给个兜底标题;浏览屏自己的 `navigationTitle` 更靠内层,会覆盖它。
            .navigationTitle("夸克网盘")
            // ⌘R:首次进入结构性重载(回片库根),之后只重读当前目录,不把人踢回起点。
            .task(id: refreshToken) { await viewModel.appear(refreshToken: refreshToken) }
            // 设置里改过来源 → 重读片库根。只有真变了才重载目录,改名 / 增删来源不该白列一次。
            .task(id: container.state.serverListRevision) {
                await viewModel.refreshLibraryRoot()
            }
            // 夸克没有服务端进度上报(进度记在本地续播库),播完一场要自己重读列表。
            // ⚠️ 只重读本地续播状态,⛔ 不重新列目录(有串行限速,见 §5)。
            .onChange(of: container.state.lastFinishedPlayback) { _, finished in
                guard finished?.serverID == nil else { return }
                Task { await viewModel.refreshResumeState() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let authorization = viewModel.quarkAuthorization {
            switch authorization {
            case .needsAuthorization:
                QuarkAuthorizationView(viewModel: viewModel)
            case .authorized:
                FileSourceBrowserView(
                    viewModel: viewModel, store: container.posters, state: container.state)
            }
        } else if let failure = viewModel.loadFailure {
            failurePane(failure)
        } else {
            ProgressView("正在读取登录状态…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 整页级别的错误(读不出凭据文件之类)。
    /// ⚠️ 只在 `quarkAuthorization == nil` 时显示:扫码屏自己有提示位,整页错误会把二维码挤掉。
    private func failurePane(_ failure: LoadFailure) -> some View {
        VStack(spacing: Metrics.spacingL) {
            OnboardingFormHeader(
                systemImage: "exclamationmark.triangle.fill",
                title: "打不开夸克网盘",
                subtitle: failure.message
            )
            Button("重试") { Task { await viewModel.reload() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(Metrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
