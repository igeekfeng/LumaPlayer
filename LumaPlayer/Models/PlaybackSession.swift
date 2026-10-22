import Foundation

/// 一次播放会话的决策结果(API_CONTRACT.md 4.4)。
/// `plan` 回答「怎么播」(地址 + 认证头 + 会话 Id),`mediaSource` 保留**被决策选中**的那条源(容器、轨道)。
/// 两者必须同源:分开选一次源就会出现「播的是 A、显示的是 B」。
/// `seekStrategy` 挂在会话上:能不能拖**推不出来** —— Emby 与百度的转码流共用 `PlaybackMethod.transcode`,
/// 但一个能停流重起、一个只能从头开始(见 `PlaybackSeekStrategy`)。
/// ⚠️ 百度源的 `mediaSource` 不是服务端响应,而是客户端按 `docs/BAIDU_PAN_API.md` 拼出来的
/// (映射见 `BaiduPanPlaybackPlanner`)—— 只喂播放层,⛔ 任何一条 Emby 请求都不许拿它当依据。
struct PlaybackSession: Sendable, Equatable {
    let plan: PlaybackPlan
    /// **被决策选中**的那条源(不是响应里的第一条)
    let mediaSource: EmbyMediaSource
    /// 拖动进度的实现方式
    let seekStrategy: PlaybackSeekStrategy
    /// 随本次播放一起挂上去的**外挂字幕**(百度同目录的 `.srt` / `.ass`,见 `BaiduPanSubtitle`)——
    /// 它们不在视频容器里,播放内核自己发现不了。Emby 侧为空:字幕要么内嵌,要么走本项目未接的独立流(`KNOWN_ISSUES.md`)。
    /// ⚠️ 加载失败**不影响播放**:起播后再挂,挂不上只提示一句。
    var externalSubtitles: [PlaybackSubtitle] = []
}

/// 一条随播放挂载的外挂字幕。
struct PlaybackSubtitle: Sendable, Equatable {
    /// 带凭据的字幕地址(百度 `dlink` + `access_token`)
    let url: URL
    /// 菜单里显示的名字(语言标签 / 文件名)。nil = 交给 mpv 用 URL 末段
    let title: String?
}
