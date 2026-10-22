import SwiftUI

/// 本地文件夹来源的内容页(主窗口导航栈的根页,来源 = 本地文件夹时)。
///
/// 与 `BaiduPanSourceView` 共用同一个浏览页(`FileSourceBrowserView`),差别只是
/// **没有授权那两屏**:访问权来自添加时做的书签,失效时浏览页的失败页里给
/// 「重新选择文件夹…」(`FileSourceDirectoryFailure.needsFolderReselection`)。
struct LocalFolderSourceView: View {
    let container: AppContainer
    let source: LocalFolderSource
    /// 「Reload」菜单(⌘R)的计数器:变化即重读当前目录
    let refreshToken: Int

    @State private var viewModel: FileSourceViewModel

    init(container: AppContainer, source: LocalFolderSource, refreshToken: Int) {
        self.container = container
        self.source = source
        self.refreshToken = refreshToken
        self._viewModel = State(
            initialValue: FileSourceViewModel(container: container, source: .localFolder(source)))
    }

    var body: some View {
        FileSourceBrowserView(viewModel: viewModel, store: container.posters)
            // 首次进入 = 从文件夹根列起;之后只重读当前所在的那一层(`refreshFromToolbar`)
            .task(id: refreshToken) { await viewModel.refreshFromToolbar() }
            // 设置里改了名 / 换了文件夹:把新值交给 ViewModel,再重读当前这一层
            .task(id: container.state.serverListRevision) {
                viewModel.sourceDidChange(.localFolder(source))
                await viewModel.refreshLibraryRoot()
            }
            .onChange(of: source) { _, updated in
                viewModel.sourceDidChange(.localFolder(updated))
            }
            // 进度记在本地续播库(与百度同一套):播完一场重读本地状态,
            // 「已看到 mm:ss」与续播区才会立刻跟上
            .onChange(of: container.state.lastFinishedPlayback) { _, finished in
                guard finished?.serverID == nil else { return }
                Task { await viewModel.refreshResumeState() }
            }
    }
}
