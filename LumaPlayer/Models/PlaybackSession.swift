import Foundation

/// 拖动进度这件事怎么实现。**它不等于「是不是转码」**:
///
/// - Emby 的 DirectStream / Transcode 都有解:前者客户端 seek,后者停流 +
///   `StartTimeTicks` 重新起流(API_CONTRACT.md 4.5);
/// - 百度源的 DirectStream 同样能客户端 seek(CDN 支持 `Range`);
///   但它的**转码流没有解** —— `method=streaming` 没有起流位置之类的参数,
///   重新请求只会从头开始(文档 §5.4 第 3 条)。
///
/// 所以「能不能拖」必须显式带在会话上,⛔ 不能靠 `method == .directStream` 反推:
/// 一旦反推错,表现是「拖到 30 分钟,画面回到 0:00 且进度被写成 0」
/// —— 一个既静默又污染进度的错。
enum PlaybackSeekStrategy: Sendable, Equatable {
    /// 静态文件:交给播放内核 seek(精度最高)
    case clientSeek
    /// 停旧流 + 带起流点重新取一路(Emby 的转码)
    case restartStream
    /// 没有可行方案。带一句给用户看的理由 —— 由播放层显示,而不是装作拖成功了。
    case unsupported(reason: String)

    /// 能不能拖。进度条与方向键据此决定要不要给交互。
    var allowsSeeking: Bool {
        if case .unsupported = self { return false }
        return true
    }

    /// 不可拖动时的理由(可以拖动时为 nil)
    var unavailableReason: String? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }
}

/// 一次播放会话的决策结果(ARCHITECTURE.md 6.4)。
///
/// `plan` 回答「怎么播」(地址 + 认证头 + 会话 Id),
/// `mediaSource` 保留**被决策选中**的那条源(容器、轨道),供起播后核轨与
/// 播放界面展示,`decision` 是 Rust 的原始结论(服务端要做什么、能力表版本)。
/// 三者必须同源:分开选一次源就会出现「播的是 A、显示的是 B」。
///
/// ## `exp/avkit-rust-core` 上加的 `seekStrategy`
///
/// 见 `PlaybackSeekStrategy`。加在会话上而不是让播放层按 `plan.method` 推,
/// 是因为百度源的转码流「不可拖」这件事**推不出来** —— 它与 Emby 的转码流
/// 共用同一个 `PlaybackMethod.transcode`。
///
/// ## 百度源为什么也往这个形状里装
///
/// 百度没有 Emby 那样的 `MediaSource`,但**播放层要用到的三件东西是同一套**:
/// 容器名(统计)、轨道(起播后核轨)、章节(片头片尾标记)。与其在播放层加一套
/// 分支,不如在百度侧把元信息**映射**成同一形状(见 `BaiduPanPlaybackPlanner`)。
/// ⚠️ 代价说清楚:对百度源而言 `mediaSource` **不是服务端响应**,
/// 是客户端按文档 §4.3 / §5.1 拼出来的 —— 它只喂播放层,
/// ⛔ 任何一条 Emby 请求都不许拿它当依据。
struct PlaybackSession: Sendable, Equatable {
    let plan: PlaybackPlan
    /// **被决策选中**的那条 `MediaSource`(不是响应里的第一条)
    let mediaSource: EmbyMediaSource
    let decision: PlaybackDecisionFfi
    /// 拖动进度的实现方式
    let seekStrategy: PlaybackSeekStrategy

    /// 起播后核轨要用的口径:选中那条源的 `MediaStreams`。
    /// 转发一下,免得每个调用点都写一遍 `session.mediaSource.mediaStreams`。
    var sourceStreams: [EmbyMediaStream]? { mediaSource.mediaStreams }
}
