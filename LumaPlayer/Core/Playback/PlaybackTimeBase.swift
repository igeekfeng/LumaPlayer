import Foundation

/// 内核时间原点 ↔ 绝对媒体位置的换算(**R13**)。
///
/// ## 为什么必须有这一层
///
/// P3 本机实测(`docs/DECISIONS/avkit-rust-rearchitecture.md` 8.5 实测二):
///
/// > 带 `StartTimeTicks=5s` 重新取一次 `PlaybackInfo`,服务端照办(变体清单的片段
/// > 地址上带着这个参数),但 `AVPlayerItem.currentTime()` **和从头起流时一样从 0 开始**。
///
/// 也就是说 **HLS 转码流的时间原点是「起流点」,不是「媒体开头」**。内核报出来的
/// 位置是相对值,如果直接当绝对位置用,后果是具体的:
/// - 续播到第 20 分钟时上报 `PositionTicks ≈ 0` → **服务端进度被写回 0**;
/// - 片头 / 片尾标记按绝对时间算,判在错的位置上。
///
/// DirectStream 没有这个问题:服务端吐的是整份文件、客户端自己 seek,
/// 所以内核位置**就是**绝对位置,偏移为 0。
///
/// ## 用法
///
/// ```swift
/// let base = PlaybackTimeBase(method: plan.method, startSeconds: startSeconds)
/// let absolute = base.absolute(fromKernel: engine.positionSeconds)   // 上报 / UI 用
/// try await engine.seek(to: base.kernel(fromAbsolute: target))       // 用户拖到 target
/// ```
///
/// ⚠️ **未核实**:起流点之后服务端是否**真的**从该处起(而不是忽略参数),
/// 以及 HLS 清单的时长是「剩余时长」还是「全长」。所以总时长**一律优先用服务端给的
/// `RunTimeTicks`**,拿不到才退回「内核时长 + 偏移」这个推断(见
/// `absoluteDuration(kernelDuration:serverDuration:)`)。两条都记在文档 R13。
struct PlaybackTimeBase: Equatable, Sendable {

    /// 内核的 0 对应的绝对媒体位置(秒)。DirectStream 恒为 0。
    let offsetSeconds: Double

    /// 按播放方式与起播点定时间基。
    ///
    /// - Parameters:
    ///   - method: `DirectStream` 时偏移为 0(客户端 seek,内核位置即绝对位置)
    ///   - startSeconds: 转码起流点(即带进 `StartTimeTicks` 的那个值)
    init(method: PlaybackMethod, startSeconds: Double) {
        switch method {
        case .directStream:
            self.offsetSeconds = 0
        case .transcode:
            self.offsetSeconds = startSeconds.isFinite ? max(0, startSeconds) : 0
        }
    }

    /// 只有偏移的直构造(测试与纯逻辑用)
    init(offsetSeconds: Double) {
        self.offsetSeconds = offsetSeconds.isFinite ? max(0, offsetSeconds) : 0
    }

    /// 内核位置 → 绝对媒体位置。上报进度、画进度条、判片头片尾都用它。
    func absolute(fromKernel seconds: Double) -> Double {
        guard seconds.isFinite else { return offsetSeconds }
        return max(0, seconds + offsetSeconds)
    }

    /// 绝对媒体位置 → 内核位置。给内核发 seek 之前必须过这一步。
    func kernel(fromAbsolute seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return max(0, seconds - offsetSeconds)
    }

    /// 总时长。**优先服务端给的** `RunTimeTicks`,它才是权威值 ——
    /// 内核时长在转码起流后只剩「从起流点到结尾」那一段,直接当总长会让进度条
    /// 显示被截短,而「内核时长 + 偏移」只是推断(文档 R13 未核实项)。
    ///
    /// - Parameters:
    ///   - kernelDuration: 内核报的时长
    ///   - serverDuration: 服务端 `RunTimeTicks` 换算来的秒数;拿不到传 nil
    func absoluteDuration(kernelDuration: Double, serverDuration: Double?) -> Double {
        if let serverDuration, serverDuration.isFinite, serverDuration > 0 { return serverDuration }
        guard kernelDuration.isFinite, kernelDuration > 0 else { return 0 }
        return kernelDuration + offsetSeconds
    }
}
