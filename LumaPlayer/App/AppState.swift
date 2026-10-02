import Foundation
import Observation

/// 全局 App 状态(ViewModel 层,@MainActor + @Observable,
/// ARCHITECTURE.md 3.1.2 的分层规则)。
@MainActor
@Observable
final class AppState {
    var route: AppRoute = .launching
    var currentServer: ServerProfile?
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

    // MARK: - 播放器窗口

    /// 播放器窗口当前要播的内容。nil = 没在播(窗口应关闭)。
    /// 播放器是单实例独立窗口(ARCHITECTURE.md 7.5),换内容 = 换请求。
    var nowPlaying: PlaybackRequest?
    /// 最近一次收尾上报已发完的播放。详情页 / 首页观察它重读服务端进度(Q22)。
    var lastFinishedPlayback: FinishedPlayback?
}
