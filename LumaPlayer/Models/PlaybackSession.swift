import Foundation

/// 一次播放会话的决策结果(ARCHITECTURE.md 6.4)。
///
/// `plan` 回答「怎么播」(地址 + 认证头 + 会话 Id),
/// `mediaSource` 保留服务端给出的那条源(容器、轨道),供起播后核轨与播放界面展示,
/// `decision` 是 Rust 的**原始结论**(服务端要做什么、字幕怎么处理、能力表版本)。
///
/// 三者必须同源:分开选一次源就会出现「播的是 A、显示的是 B」。
struct PlaybackSession: Sendable, Equatable {
    let plan: PlaybackPlan
    /// **被决策选中**的那条 `MediaSource`(不是响应里的第一条)
    let mediaSource: EmbyMediaSource
    let decision: PlaybackDecisionFfi

    /// 起播后核轨要用的口径:选中那条源的 `MediaStreams`。
    /// 转发一下,免得每个调用点都写一遍 `session.mediaSource.mediaStreams`。
    var sourceStreams: [EmbyMediaStream]? { mediaSource.mediaStreams }
}
