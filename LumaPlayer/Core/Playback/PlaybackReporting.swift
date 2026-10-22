import Foundation

/// 播放进度的出口:Emby 走 `PlaybackProgressReporter` 上报服务端(`API_CONTRACT.md` 第 5 节);
/// 百度没有进度接口,走 `LocalResumeReporting` 记本地 `WatchProgressStore`。
///
/// ⛔ 不给 `PlaybackProgressReporter` 加来源分支:`PlaybackReportContext` 的三个 id 只对 Emby 有意义。
/// 方法是 `async` 以便跨 actor 调;actor 的同步方法天然满足,实现不用改。
protocol PlaybackReporting: Sendable {
    func begin(context: PlaybackReportContext, state: PlaybackReportState) async
    /// 定时上报用发送时刻的最新快照
    func update(_ state: PlaybackReportState) async
    /// 交互触发的立即上报(`API_CONTRACT.md` 5.2)
    func reportNow(eventName: PlaybackEventName) async
    func finish(finalState: PlaybackReportState, sendFinalProgress: Bool) async
    /// 等已入队的条目处理完(Emby:等 Stopped 到达服务端;本地:空操作)
    func drain() async
}
