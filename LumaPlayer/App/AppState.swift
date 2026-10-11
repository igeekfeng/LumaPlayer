import Foundation
import Observation

/// 全局 App 状态(ViewModel 层,@MainActor + @Observable,
/// CLAUDE.md「并发分层」的分层规则)。
@MainActor
@Observable
final class AppState {
    var route: AppRoute = .launching
    /// 当前**播放来源**(Emby / 百度网盘 / 未来的其它来源)。这是权威字段。
    var currentSource: SourceProfile?
    /// Emby 兼容访问器:当前来源是 Emby 时的服务器档案,否则 `nil`。
    ///
    /// 保留它是刻意的 —— `ServerProfile` 出现在 39 个文件里,让既有 Emby 侧代码
    /// 继续按这个名字读写,改造就不必碰它们(`docs/SOURCE_ABSTRACTION_PLAN.md` §6.2)。
    /// 写入时会同步写成 `.emby(_)`,所以 `currentSource` 始终是唯一真相。
    var currentServer: ServerProfile? {
        get {
            if case .emby(let profile) = currentSource { return profile }
            return nil
        }
        set { currentSource = newValue.map(SourceProfile.emby) }
    }
    /// 需要重新登录的服务器(token 缺失或已失效)。
    /// 只标这一台,其他服务器不受影响(API_CONTRACT.md 2.5)
    var serverNeedingLogin: ServerProfile?
    /// 服务器列表的修订号:增 / 改 / 删后 +1。列表本身在 ServerRegistry(actor)里,
    /// 各视图持有的是快照,观察它来重读 —— 否则在设置窗口改了名,主窗口菜单还是旧名
    var serverListRevision = 0
    /// 启动期异常(如本地存储损坏),由 RootView 弹提示
    var startupError: AppError?
    /// 会话恢复只做一次(防 task 重入)
    var didRestoreSession = false

    /// 正在加载 / 刷新的内容页。工具栏的「刷新」按钮据此把图标转起来并禁用。
    ///
    /// 用集合而不是一个布尔:栈上多页同时存在时,布尔会受「push 时旧页 `onDisappear`
    /// 与新页上报的先后顺序」影响而抖一下;集合只按每页自己的状态增删,与顺序无关。
    private var loadingPages: Set<ContentPage> = []

    /// 有任意内容页在加载 / 刷新。
    var isPageLoading: Bool { !loadingPages.isEmpty }

    /// 内容页上报自己的加载状态(见 `reportsPageLoading(_:page:to:)`)。
    func setPageLoading(_ isLoading: Bool, page: ContentPage) {
        if isLoading {
            loadingPages.insert(page)
        } else {
            loadingPages.remove(page)
        }
    }

    // MARK: - 播放器窗口

    /// 播放器窗口当前要播的内容。nil = 没在播(窗口应关闭)。
    /// 播放器是单实例独立窗口(CLAUDE.md「架构主线」),换内容 = 换请求。
    var nowPlaying: PlaybackRequest?
    /// 最近一次收尾上报已发完的播放。详情页 / 首页观察它重读服务端进度(Q22)。
    var lastFinishedPlayback: FinishedPlayback?
}
