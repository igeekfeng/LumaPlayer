import Foundation

/// 内核自己的一条诊断日志(**与内核无关**),播放失败时附进 `network.log`。
///
/// 内核(Erika)在导出时已脱敏(URL 查询串、凭据类键值、主目录),写盘前
/// `NetworkDiagnostics` 再过一次 `SecretRedactor`。
struct PlayerLogEntry: Sendable, Equatable {
    /// 最后一次出现的时间(重复折叠时是最后一条的时间)
    let date: Date
    /// 内核给的级别名(`warn` / `error` …),原样保留
    let level: String
    /// 来源(Erika:`erika` / `ffmpeg` / `libass` …)
    let source: String
    /// 文本:非结构化日志是原文,结构化日志是其 JSON
    let text: String
    /// 被内核折叠的重复次数(≥ 1)
    let count: Int
}
