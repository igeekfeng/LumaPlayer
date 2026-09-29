import Foundation

/// 一次播放会话的决策结果(ARCHITECTURE.md 6.4)。
///
/// `plan` 回答「怎么播」(地址 + 认证头 + 会话 Id),
/// `mediaSource` 保留服务端给出的源信息(容器、轨道),供播放界面展示。
/// 两者必须同源:分开选一次源就会出现「播的是 A、显示的是 B」。
struct PlaybackSession: Sendable, Equatable {
    let plan: PlaybackPlan
    let mediaSource: EmbyMediaSource
}
