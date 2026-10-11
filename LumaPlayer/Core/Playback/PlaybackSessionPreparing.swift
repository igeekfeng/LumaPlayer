import Foundation

/// 会话准备的注入点。
///
/// 生产实现有两个:`PlaybackSessionCoordinator`(Emby,过 `PlaybackDecisionEngine`)
/// 与 `BaiduPanSessionPreparer`(百度,过同一个决策器的**判定**部分)。
///
/// 抽成协议的理由与 `PlaybackReporting` 相同:**接线规则**(什么时候 seek、
/// 什么时候上报、起播偏好什么时候套上去、转码 seek 怎么重新起流)不该依赖网络,
/// 而接线测试只能靠替身把会话喂进去。会话准备自身由各自的来源单测覆盖。
protocol PlaybackSessionPreparing: Sendable {
    /// - Parameter startTimeTicks: 转码起流位置(`API_CONTRACT.md` 4.5);
    ///   `nil` = 从头取一次会话
    func makeSession(startTimeTicks: Int64?) async throws -> PlaybackSession

    /// 来源自己知道的**权威总时长**(秒);`nil` = 这个来源没有这个信息,
    /// 播放页沿用自己已有的。
    ///
    /// ⚠️ 为什么要有它:百度转码流在未转完时,内核看到的时长只是已转码那一段
    /// (`method=streaming` 的生长式 m3u8),所以总时长必须由来源给。
    /// Emby 侧的权威时长在 `EmbyItem.RunTimeTicks` 上(既有行为),走默认实现返回 nil。
    var authoritativeDurationSeconds: Double? { get async }
}

extension PlaybackSessionPreparing {
    var authoritativeDurationSeconds: Double? { nil }
}
