import SwiftUI

/// 百度网盘来源的内容页:按授权状态切三屏(填密钥 → 扫码 → 浏览目录)。
///
/// ⚠️ 它是**主窗口导航栈的根页**(来源 = 百度网盘时),不是独立 sheet ——
/// 「来源」是一层平等的东西,Emby 与百度共用一个导航栈与工具栏
/// (`docs/SOURCE_ABSTRACTION_PLAN.md` §0)。
struct BaiduPanSourceView: View {
    let container: AppContainer
    /// 当前来源(决定 `sourceID` —— 封面缓存 key 按它分区)
    let source: BaiduPanSource
    /// 工具栏「刷新」按钮的计数器:变化即重读授权状态与目录
    let refreshToken: Int

    @State private var viewModel: BaiduPanSourceViewModel

    init(container: AppContainer, source: BaiduPanSource, refreshToken: Int) {
        self.container = container
        self.source = source
        self.refreshToken = refreshToken
        self._viewModel = State(
            initialValue: BaiduPanSourceViewModel(container: container, source: source))
    }

    var body: some View {
        content
            // 授权那两屏(填密钥 / 扫码)也占着主窗口的标题栏 —— 给一个兜底标题,
            // 免得空着。浏览屏自己有 `navigationTitle(当前目录名)`,更靠内层,
            // 会覆盖这一条。
            .navigationTitle("百度网盘")
            // 工具栏「刷新」:首次进入 = 结构性重载(回片库根),之后只重读
            // **当前所在**的目录 —— 刷新不该把人踢回起点(`refreshFromToolbar`)。
            .task(id: refreshToken) { await viewModel.refreshFromToolbar() }
            // 设置里改过来源(片库根 / 显示名 / 增删来源)→ 重读片库根。
            // ⚠️ 只在片库根**真的变了**时才重载目录 —— 其余变更(改名 / 增删来源)
            // 不该白列一次目录(`refreshLibraryRoot`)。
            .task(id: container.state.serverListRevision) {
                await viewModel.refreshLibraryRoot()
            }
            // 百度来源没有服务端进度上报(进度记在本地续播库),所以播完一场
            // 要自己重读一次,「已看到 mm:ss」才会立刻反映在列表上。
            // ⚠️ 只重读**本地**续播状态 —— ⛔ 不重新列目录(那是 2 次百度请求,
            // 而播完一场目录内容一个字节都没变,见 `refreshResumeState`)。
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
                BaiduPanBrowserView(viewModel: viewModel, store: container.posters)
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
