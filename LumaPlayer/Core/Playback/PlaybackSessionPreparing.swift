import Foundation

/// 会话准备的注入点:`PlaybackSessionCoordinator`(Emby)与 `BaiduPanSessionPreparer`(百度,
/// 复用决策器的判定部分)。抽协议是为了让播放页接线测试能用替身喂会话。
protocol PlaybackSessionPreparing: Sendable {
    /// - Parameter startTimeTicks: 转码起流位置(`API_CONTRACT.md` 4.5);`nil` = 从头
    func makeSession(startTimeTicks: Int64?) async throws -> PlaybackSession

    /// 来源给的权威总时长(秒);nil = 来源不知道,播放页沿用自己的。
    /// 百度转码流是生长式 m3u8,内核看到的时长只有已转码那段。Emby 用 `RunTimeTicks`,走默认 nil。
    var authoritativeDurationSeconds: Double? { get async }
}

extension PlaybackSessionPreparing {
    var authoritativeDurationSeconds: Double? { nil }
}
