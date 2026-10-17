import Foundation
import os

/// 弹幕逐帧诊断:回答「滚动看着累,是时钟在跳还是在掉帧」。**默认关闭**,零开销(只多一次判空)。
///
/// ## 打开方式
///
/// 启动参数 `-danmakuDiagnostics YES`(进 `UserDefaults` 的参数域,不落盘):
///
/// ```
/// open -a LumaPlayer --args -danmakuDiagnostics YES
/// log stream --style compact --predicate 'subsystem == "com.local.LumaPlayer" AND category == "danmaku.frames"'
/// ```
///
/// 播放中每 `reportInterval` 秒打一行汇总(`.notice` 级别,`log stream` 默认可见)。
///
/// ## 每一项说明什么
///
/// 样本来自 `DanmakuLayerView` 的 displayLink 回调;判定以**屏幕刷新间隔**
/// (`targetTimestamp − timestamp`)为基准,不以实测中位数为基准 —— 后者在整体掉到 40 帧时
/// 会把 32 ms 当成「正常」,真掉帧反而数不出来。
///
/// - **刷新**:屏幕刷新率(Hz,刷新间隔中位数换算)。
/// - **可见**:窗口可见(`occlusionState` 含 `.visible`)的帧数 / 总帧数。窗口被挡住或在别的桌面时
///   系统会给 displayLink 降频(实测约 24 Hz、每次晚 30–40 ms),这些窗口的帧率不代表观看时的表现。
/// - **间隔**:相邻两次更新的 `targetTimestamp` 之差,即画面上弹幕实际隔多久动一次。
/// - **掉帧**:间隔里跳过的刷新数之和(`round(间隔 / 刷新间隔) − 1`),0 = 每次刷新都跟上了。
/// - **重画**:间隔不到半个刷新间隔(同一次刷新更新了两次)。
/// - **回调抖动**:实际回调间隔与 `targetTimestamp` 步长之差的最大值。
/// - **余量**:回调做完时距这一帧上屏还剩多久的最小值;负数 = 做完时这一帧已经上屏了。
/// - **时钟跳**:每帧实际位移减去「`targetTimestamp` 步长 × 倍速 × 速度」的残差 ≥ `jumpEpsilon` 的次数与大小(pt)。
///   `DanmakuClock` 靠微调速度吸收误差,正常每帧残差远小于阈值;出现跳动说明位置被直接挪了。
///   一帧内跳 ≥ `DanmakuClock.snapThreshold` 秒的算 seek / 恢复对齐,单独计数。
/// - **速度偏差**:每帧实际速度相对「倍速 × 速度」偏离的最大比例,即时钟吸收误差时的变速幅度。
/// - **耗时**:回调本身(取可见 + 新弹幕预渲染 + 改图层位置)的耗时;
///   ⚠️ 不含 Core Animation 之后的提交与 GPU 合成,那部分只能从「掉帧」间接看出。
@MainActor
final class DanmakuFrameDiagnostics {

    static let isEnabled = UserDefaults.standard.bool(forKey: "danmakuDiagnostics")
    static let reportInterval = 5.0

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "danmaku.frames")

    private var stats = DanmakuFrameStats()
    private var windowStart: Double?

    func record(_ frame: DanmakuFrameStats.Frame) {
        stats.record(frame)
        guard let start = windowStart else {
            windowStart = frame.hostTime
            return
        }
        guard frame.hostTime - start >= Self.reportInterval else { return }
        if let summary = stats.summary(window: frame.hostTime - start) {
            Self.logger.notice("\(summary.description, privacy: .public)")
        }
        stats.resetWindow()
        windowStart = frame.hostTime
    }
}

/// 逐帧样本的累积与汇总(纯值类型,单测覆盖)。
struct DanmakuFrameStats: Sendable {

    struct Frame: Sendable {
        /// 回调开始时的宿主时钟(秒,`CACurrentMediaTime`)
        var hostTime: Double
        /// displayLink 的 `targetTimestamp`:这一帧上屏的时刻(秒,同一时间基)
        var targetTime: Double
        /// 屏幕刷新间隔(秒,`targetTimestamp − timestamp`)
        var refreshInterval: Double
        /// 本帧用的弹幕时间轴时间(秒)
        var danmakuTime: Double
        /// 滚动速度(pt/s)
        var velocity: Double
        /// 播放倍速
        var rate: Double
        /// 回调耗时(秒)
        var workDuration: Double
        /// 本帧在场几条
        var visibleCount: Int
        /// 窗口是否可见(未被遮挡、在当前桌面)
        var windowVisible: Bool
    }

    struct Summary: Sendable, CustomStringConvertible {
        var window: Double
        var frameCount: Int
        var refreshInterval: Double
        var intervalMedian: Double
        var intervalP95: Double
        var intervalMax: Double
        var droppedFrames: Int
        var redraws: Int
        var callbackJitterMax: Double
        var marginMin: Double
        var velocity: Double
        var jumpCount: Int
        var jumpMax: Double
        var jumpTotal: Double
        var snapCount: Int
        var speedDeviationMax: Double
        var windowVisibleFrames: Int
        var workMean: Double
        var workP95: Double
        var workMax: Double
        var visibleMean: Double
        var visibleMax: Int

        var description: String {
            func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }
            func pt(_ value: Double) -> String { String(format: "%.1f", value) }
            let hz = refreshInterval > 0 ? String(format: "%.0f", 1 / refreshInterval) : "?"
            return "弹幕帧 \(String(format: "%.1f", window))s 刷新 \(hz)Hz 可见 \(windowVisibleFrames)/\(frameCount)"
                + " | 帧 \(frameCount) 间隔 p50 \(ms(intervalMedian)) p95 \(ms(intervalP95)) max \(ms(intervalMax))ms"
                + " 掉帧 \(droppedFrames) 重画 \(redraws)"
                + " | 回调抖动 max \(ms(callbackJitterMax))ms 余量 min \(ms(marginMin))ms"
                + " | 速度 \(pt(velocity))pt/s 时钟跳 \(jumpCount) 次 max \(pt(jumpMax)) 合计 \(pt(jumpTotal))pt seek \(snapCount)"
                + " 速度偏差 max \(String(format: "%.1f", speedDeviationMax * 100))%"
                + " | 耗时 mean \(ms(workMean)) p95 \(ms(workP95)) max \(ms(workMax))ms"
                + " | 在场 mean \(pt(visibleMean)) max \(visibleMax)"
        }
    }

    /// 间隔超过它视为暂停 / 切走后恢复,不计入(displayLink 暂停期间不回调)
    static let resumeGap = 0.25
    /// 单帧位移残差到这么大才算一次跳动(pt)。时钟微调速度时每帧残差 ≤ 速度偏差 × 每帧位移
    /// (120 Hz、216 pt/s、偏差 10% 时约 0.18 pt),阈值高于它;旧的直接挪位置每次约 0.5–1 pt,能被数到
    static let jumpEpsilon = 0.25

    private var last: Frame?
    private var intervals: [Double] = []
    private var refreshIntervals: [Double] = []
    private var droppedFrames = 0
    private var redraws = 0
    private var callbackJitters: [Double] = []
    private var margins: [Double] = []
    private var jumps: [Double] = []
    private var snapCount = 0
    private var speedDeviations: [Double] = []
    private var windowVisibleFrames = 0
    private var workDurations: [Double] = []
    private var visibleCounts: [Int] = []
    private var velocity = 0.0

    mutating func record(_ frame: Frame) {
        workDurations.append(frame.workDuration)
        visibleCounts.append(frame.visibleCount)
        if frame.windowVisible { windowVisibleFrames += 1 }
        margins.append(frame.targetTime - (frame.hostTime + frame.workDuration))
        if frame.refreshInterval > 0 { refreshIntervals.append(frame.refreshInterval) }
        velocity = frame.velocity
        defer { last = frame }
        guard let last else { return }
        let interval = frame.targetTime - last.targetTime
        guard interval < Self.resumeGap else { return }
        intervals.append(interval)

        if frame.refreshInterval > 0 {
            if interval < frame.refreshInterval * 0.5 {
                redraws += 1
            } else {
                droppedFrames += max(0, Int((interval / frame.refreshInterval).rounded()) - 1)
            }
        }
        callbackJitters.append(abs((frame.hostTime - last.hostTime) - interval))

        let residualSeconds = (frame.danmakuTime - last.danmakuTime) - interval * frame.rate
        if abs(residualSeconds) >= DanmakuClock.snapThreshold {
            snapCount += 1
        } else {
            let residualPoints = abs(residualSeconds) * frame.velocity
            if residualPoints >= Self.jumpEpsilon { jumps.append(residualPoints) }
            if interval > 0, frame.rate > 0 {
                speedDeviations.append(abs(residualSeconds) / (interval * frame.rate))
            }
        }
    }

    /// 本窗口没有任何帧间隔(只来了一帧或全在暂停)时返回 nil。
    func summary(window: Double) -> Summary? {
        guard !intervals.isEmpty else { return nil }
        let sortedIntervals = intervals.sorted()
        let sortedWork = workDurations.sorted()
        return Summary(
            window: window,
            frameCount: workDurations.count,
            refreshInterval: refreshIntervals.isEmpty ? 0 : Self.percentile(refreshIntervals.sorted(), 0.5),
            intervalMedian: Self.percentile(sortedIntervals, 0.5),
            intervalP95: Self.percentile(sortedIntervals, 0.95),
            intervalMax: sortedIntervals.last ?? 0,
            droppedFrames: droppedFrames,
            redraws: redraws,
            callbackJitterMax: callbackJitters.max() ?? 0,
            marginMin: margins.min() ?? 0,
            velocity: velocity,
            jumpCount: jumps.count,
            jumpMax: jumps.max() ?? 0,
            jumpTotal: jumps.reduce(0, +),
            snapCount: snapCount,
            speedDeviationMax: speedDeviations.max() ?? 0,
            windowVisibleFrames: windowVisibleFrames,
            workMean: workDurations.reduce(0, +) / Double(workDurations.count),
            workP95: Self.percentile(sortedWork, 0.95),
            workMax: sortedWork.last ?? 0,
            visibleMean: Double(visibleCounts.reduce(0, +)) / Double(visibleCounts.count),
            visibleMax: visibleCounts.max() ?? 0)
    }

    /// 清空本窗口的样本,保留最后一帧作为下一窗口第一个间隔的起点。
    mutating func resetWindow() {
        intervals.removeAll(keepingCapacity: true)
        refreshIntervals.removeAll(keepingCapacity: true)
        droppedFrames = 0
        redraws = 0
        callbackJitters.removeAll(keepingCapacity: true)
        margins.removeAll(keepingCapacity: true)
        jumps.removeAll(keepingCapacity: true)
        snapCount = 0
        speedDeviations.removeAll(keepingCapacity: true)
        windowVisibleFrames = 0
        workDurations.removeAll(keepingCapacity: true)
        visibleCounts.removeAll(keepingCapacity: true)
    }

    /// `sorted` 须非空且已升序
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted[Int((Double(sorted.count - 1) * p).rounded())]
    }
}
