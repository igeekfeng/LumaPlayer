import Foundation

/// 播放进度的出口。**两种源走两条完全不同的路**:
///
/// - Emby:`PlaybackProgressReporter` —— 按 `API_CONTRACT.md` 第 5 节上报到服务端,
///   「继续观看」是服务端能力;
/// - 百度网盘:`LocalResumeReporting` —— 百度**没有**播放进度上报接口
///   (文档 §5.2),进度只能记在本地 `WatchProgressStore`。
///
/// ## 为什么抽协议而不是给 `PlaybackProgressReporter` 加分支
///
/// 上报语义与「源」绑死:Emby 的 `PlaybackReportContext` 里
/// `itemID` / `mediaSourceID` / `playSessionID` 三个 id 只有在 Emby 那张表里才有意义。
/// 硬把它复用到百度源上,结果是「一条永远发不出去的请求 + 一个假装存在的会话」。
/// 抽一层协议之后,播放页只认「有进度要交代」这一件事,谁去交代由源的装配处决定
/// —— 与 `PlaybackEngine` 抽协议是同一个理由。
///
/// ## 为什么方法是 `async`
///
/// 两个实现都是 actor;协议必须能跨 actor 调。`PlaybackProgressReporter` 的
/// 同步 actor 方法**天然满足** `async` 要求(更宽松的签名可以作证),
/// 所以给它加一致性不需要动它的实现。
protocol PlaybackReporting: Sendable {
    /// 开始一个会话
    func begin(context: PlaybackReportContext, state: PlaybackReportState) async
    /// 刷新状态快照(定时上报用的是**发送时刻**的最新快照)
    func update(_ state: PlaybackReportState) async
    /// 用户交互触发的立即上报(5.2 的 EventName 映射)
    func reportNow(eventName: PlaybackEventName) async
    /// 结束当前会话
    func finish(finalState: PlaybackReportState, sendFinalProgress: Bool) async
    /// 等已入队的条目处理完(Emby 侧是「等 Stopped 真的到达服务端」;本地实现是空操作)
    func drain() async
}

extension PlaybackProgressReporter: PlaybackReporting {}
