import Foundation

enum AppRoute: Equatable, Sendable {
    /// 恢复会话中(毫秒级;避免误闪引导页)
    case launching
    /// 没有任何服务器:引导添加第一台
    case onboarding
    /// 主窗口,默认停在首页
    case browse
}
