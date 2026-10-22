import Foundation
import Observation

/// 全局 App 状态。
@MainActor
@Observable
final class AppState {
    var route: AppRoute = .launching
    /// 当前播放来源。唯一真相。
    var currentSource: SourceProfile?
    /// Emby 侧代码的兼容访问器:当前来源是 Emby 时的服务器档案,否则 nil;写入即写 `currentSource`。
    var currentServer: ServerProfile? {
        get {
            if case .emby(let profile) = currentSource { return profile }
            return nil
        }
        set { currentSource = newValue.map(SourceProfile.emby) }
    }
    /// 需要重新登录的那一台(token 缺失或失效),不影响其他服务器(API_CONTRACT.md 2.5)
    var serverNeedingLogin: ServerProfile?
    /// 服务器列表增 / 改 / 删后 +1。列表在 ServerRegistry(actor)里,各视图持有快照,观察它来重读
    var serverListRevision = 0
    /// 启动期异常(如本地存储损坏),由 RootView 弹提示
    var startupError: AppError?
    /// 会话恢复只做一次(防 task 重入)
    var didRestoreSession = false

    /// 正在加载的内容页(顶栏加载线、⌘R 禁用据此判断)。用集合不用布尔:push 时旧页 `onDisappear`
    /// 与新页上报先后不定,布尔会抖。
    private var loadingPages: Set<ContentPage> = []

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

    /// 播放器窗口要播的内容。nil = 没在播(窗口应关闭)。
    var nowPlaying: PlaybackRequest?
    /// 最近一次收尾上报已发完的播放。详情页 / 首页观察它重读服务端进度(Q22)。
    var lastFinishedPlayback: FinishedPlayback?
}
