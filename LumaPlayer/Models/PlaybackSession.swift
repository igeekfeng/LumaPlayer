import Foundation

/// 一次播放会话的决策结果(API_CONTRACT.md 4.4)。
///
/// `plan` 回答「怎么播」(地址 + 认证头 + 会话 Id),
/// `mediaSource` 保留**被决策选中**的那条源(容器、轨道),供播放界面展示与核轨。
/// 两者必须同源:分开选一次源就会出现「播的是 A、显示的是 B」。
///
/// ## 为什么 `seekStrategy` 挂在会话上
///
/// 见 `PlaybackSeekStrategy`。加在会话上而不是让播放层按 `plan.method` 推,
/// 是因为「能不能拖」**推不出来**:Emby 与百度的转码流共用同一个
/// `PlaybackMethod.transcode`,但一个能停流重起、一个只能从头开始。
///
/// ## 百度源为什么也往这个形状里装
///
/// 百度没有 Emby 那样的 `MediaSource`,但播放层要用到的两件东西是同一套:
/// 容器名(统计展示)与「被选中那条源」这个概念。与其在播放层加一套分支,
/// 不如在百度侧把元信息**映射**成同一形状(见 `BaiduPanPlaybackPlanner`)。
/// ⚠️ 代价说清楚:对百度源而言 `mediaSource` **不是服务端响应**,
/// 是客户端按 `docs/BAIDU_PAN_API.md` 拼出来的 —— 它只喂播放层,
/// ⛔ 任何一条 Emby 请求都不许拿它当依据。
struct PlaybackSession: Sendable, Equatable {
    let plan: PlaybackPlan
    /// **被决策选中**的那条源(不是响应里的第一条)
    let mediaSource: EmbyMediaSource
    /// 拖动进度的实现方式
    let seekStrategy: PlaybackSeekStrategy
    /// 随本次播放一起挂上去的**外挂字幕**。
    ///
    /// 来源:百度侧同目录的 `.srt` / `.ass`(见 `BaiduPanSubtitle`)——
    /// 它们不在视频容器里,播放内核自己发现不了。Emby 侧为空:字幕要么内嵌,
    /// 要么由服务端作为独立流提供(那条通路本项目没接,见 `KNOWN_ISSUES.md`)。
    ///
    /// ⚠️ 加载失败**不影响播放**:字幕是附加轨,起播后再挂,挂不上只提示一句。
    var externalSubtitles: [PlaybackSubtitle] = []
}

/// 一条随播放挂载的外挂字幕。
struct PlaybackSubtitle: Sendable, Equatable {
    /// 带凭据的字幕地址(百度 `dlink` + `access_token`)
    let url: URL
    /// 菜单里显示的名字(语言标签 / 文件名)。nil = 交给 mpv 用 URL 末段
    let title: String?
}
