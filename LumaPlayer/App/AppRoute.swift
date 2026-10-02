import Foundation

/// 根路由。
enum AppRoute: Equatable, Sendable {
    /// 启动后恢复会话中(读本地列表,毫秒级;避免误闪引导页)
    case launching
    /// 没有任何服务器:引导添加第一台
    case onboarding
    /// 浏览媒体库(主窗口,默认停在首页)。服务器管理在设置窗口(⌘,)
    case browse
}
