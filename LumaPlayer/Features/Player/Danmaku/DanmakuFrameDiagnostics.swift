import Foundation
import os

/// 弹幕逐帧诊断:区分时钟跳动与掉帧。**默认开启**,`-danmakuDiagnostics NO` 关(参数域,不落盘)。
///
/// 常开是因为瞬移偶现,而且重启本身就会让它消失 —— 关着等它出现等于永远抓不到。
/// `.notice` 落盘,事后按时间回查即可:
///
/// ```
/// log show --last 2h --style compact --predicate 'subsystem == "com.local.LumaPlayer" AND category == "danmaku.frames"'
/// ```
///
/// 每 `reportInterval` 秒打一行 `.notice` 汇总。判定以屏幕刷新间隔(`targetTimestamp − timestamp`)
/// 为基准,⛔ 不用实测中位数(整体掉帧时会把掉帧当正常)。
///
/// - 刷新:屏幕刷新率(刷新间隔中位数换算)。
/// - 可见:窗口可见帧数 / 总帧数。被遮挡时系统给 displayLink 降频,那些帧不代表观看表现。
/// - 间隔:相邻两次 `targetTimestamp` 之差。
/// - 掉帧:Σ(`round(间隔 / 刷新间隔) − 1`)。
/// - 长停顿:间隔 ≥ 250ms 的次数(仍计入间隔与掉帧);只有显式 `breakContinuity` 或窗口可见性切换才断开比较。
/// - 重画:间隔不到半个刷新间隔。
/// - 回调抖动:实际回调间隔与 `targetTimestamp` 步长之差的最大值。
/// - 余量:回调做完距上屏的最小剩余;负数 = 已经晚了。
/// - 时钟跳:每帧位移残差 ≥ `jumpEpsilon` 的次数与大小(pt);≥ `DanmakuClock.snapThreshold` 秒的算 seek,单独计数。
/// - 速度偏差:实际速度相对「倍速 × 速度」的最大偏离比例。
/// - 耗时:回调本身耗时,不含 Core Animation 提交与 GPU 合成(只能从掉帧间接看)。
///
/// 汇总之外,跳变当场另打一行,⛔ 别指望从 5 秒汇总里读出单次瞬移有多大:
/// - `弹幕跳变`:相邻两帧整层平移 ≥ `eventJumpThreshold` pt(或跨过 seek 阈值)。
/// - `弹幕时钟对齐`:位置更新把时钟从外推值直接拽到报来的位置,带误差与「距上次位置更新」的时长 ——
///   后者异常大说明位置不再上报(缓冲 / 长停顿),⛔ 不是弹幕算错。
@MainActor
final class DanmakuFrameDiagnostics {

    static let isEnabled = UserDefaults.standard.object(forKey: "danmakuDiagnostics") as? Bool ?? true
    static let reportInterval = 5.0

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "danmaku.frames")

    private var stats = DanmakuFrameStats()
    private var windowStart: Double?
    private var lastSnapLog = 0.0

    /// 生命周期变化时显式断开;⛔ 不靠「间隔 ≥ 250ms」猜暂停(会漏记长停顿)。
    func breakContinuity() {
        stats.breakContinuity()
    }

    func record(_ frame: DanmakuFrameStats.Frame) {
        if let jump = stats.record(frame) {
            Self.logger.notice("\(Self.describe(jump), privacy: .public)")
        }
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

    /// 位置更新直接把时钟拽到报来的位置。同一秒内只留第一条:缓冲时可能连续对齐,刷屏反而看不到起点。
    func record(snap: DanmakuClock.Snap) {
        // 0.05 秒在 216 pt/s 下约 10 pt,再小看不出位移,只剩暂停恢复时的噪音
        guard abs(snap.error) >= 0.05, snap.at - lastSnapLog >= 1 else { return }
        lastSnapLog = snap.at
        func signed(_ value: Double) -> String { String(format: "%+.2f", value) }
        let line = "弹幕时钟对齐 误差 \(signed(snap.error))s 位置 \(signed(snap.position))"
            + " 外推 \(signed(snap.predicted)) 距位置更新 \(String(format: "%.0f", snap.sinceUpdate * 1000))ms"
            + (snap.resumed ? " 暂停后恢复" : "")
        Self.logger.notice("\(line, privacy: .public)")
    }

    private static func describe(_ jump: DanmakuFrameStats.Jump) -> String {
        func signed(_ value: Double) -> String { String(format: "%+.1f", value) }
        return "弹幕跳变 \(jump.snapped ? "对齐" : "漂移") 平移 \(signed(jump.points))pt / \(signed(jump.seconds))s"
            + " 时间 \(signed(jump.fromTime))→\(signed(jump.toTime))"
            + " 间隔 \(String(format: "%.1f", jump.interval * 1000))ms 倍速 \(String(format: "%.2f", jump.rate))"
            + " 在场 \(jump.visibleCount)"
            + " 可见 \(jump.windowVisible ? 1 : 0)"
    }
}

/// 逐帧样本的累积与汇总(纯值类型)。时间单位均为秒。
struct DanmakuFrameStats: Sendable {

    struct Frame: Sendable {
        /// 回调开始时的 `CACurrentMediaTime`
        var hostTime: Double
        /// 这一帧上屏时刻(同一时间基)
        var targetTime: Double
        var refreshInterval: Double
        var danmakuTime: Double
        /// pt/s
        var velocity: Double
        var rate: Double
        var workDuration: Double
        var visibleCount: Int
        var windowVisible: Bool
    }

    /// 相邻两帧之间整层弹幕平移超过肉眼可辨的量(或跨过 seek 阈值)。
    struct Jump: Sendable {
        /// 弹幕时间(秒);`points` 正数 = 往左跳
        var fromTime: Double
        var toTime: Double
        var seconds: Double
        var points: Double
        var interval: Double
        var rate: Double
        var visibleCount: Int
        var windowVisible: Bool
        /// 跨过 `DanmakuClock.snapThreshold`,按 seek 计入汇总
        var snapped: Bool
    }

    struct Summary: Sendable, CustomStringConvertible {
        var window: Double
        var frameCount: Int
        var refreshInterval: Double
        var intervalMedian: Double
        var intervalP95: Double
        var intervalMax: Double
        var droppedFrames: Int
        var longStallCount: Int
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
                + " 掉帧 \(droppedFrames) 长停顿 \(longStallCount) 重画 \(redraws)"
                + " | 回调抖动 max \(ms(callbackJitterMax))ms 余量 min \(ms(marginMin))ms"
                + " | 速度 \(pt(velocity))pt/s 时钟跳 \(jumpCount) 次 max \(pt(jumpMax)) 合计 \(pt(jumpTotal))pt seek \(snapCount)"
                + " 速度偏差 max \(String(format: "%.1f", speedDeviationMax * 100))%"
                + " | 耗时 mean \(ms(workMean)) p95 \(ms(workP95)) max \(ms(workMax))ms"
                + " | 在场 mean \(pt(visibleMean)) max \(visibleMax)"
        }
    }

    static let longStallThreshold = 0.25
    /// pt。须高于时钟微调速度的正常每帧残差(120 Hz、216 pt/s、偏差 10% 时约 0.18 pt)
    static let jumpEpsilon = 0.25
    /// pt。单独立行的门槛:正常微调的每帧残差远达不到,两倍速长吸收窗口也只有 0.4 pt 量级
    static let eventJumpThreshold = 8.0

    private var last: Frame?
    private var intervals: [Double] = []
    private var refreshIntervals: [Double] = []
    private var droppedFrames = 0
    private var longStallCount = 0
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

    @discardableResult
    mutating func record(_ frame: Frame) -> Jump? {
        workDurations.append(frame.workDuration)
        visibleCounts.append(frame.visibleCount)
        if frame.windowVisible { windowVisibleFrames += 1 }
        margins.append(frame.targetTime - (frame.hostTime + frame.workDuration))
        if frame.refreshInterval > 0 { refreshIntervals.append(frame.refreshInterval) }
        velocity = frame.velocity
        defer { last = frame }
        guard let last else { return nil }
        // 可见性切换时不比较;两帧可见性相同时,再长的间隔也保留
        guard frame.windowVisible == last.windowVisible else { return nil }
        let interval = frame.targetTime - last.targetTime
        guard interval >= 0 else { return nil }
        intervals.append(interval)
        if interval >= Self.longStallThreshold { longStallCount += 1 }

        if frame.refreshInterval > 0 {
            if interval < frame.refreshInterval * 0.5 {
                redraws += 1
            } else {
                droppedFrames += max(0, Int((interval / frame.refreshInterval).rounded()) - 1)
            }
        }
        callbackJitters.append(abs((frame.hostTime - last.hostTime) - interval))

        let residualSeconds = (frame.danmakuTime - last.danmakuTime) - interval * frame.rate
        let displacement = abs(residualSeconds) * frame.velocity
        let snapped = abs(residualSeconds) >= DanmakuClock.snapThreshold
        if snapped {
            snapCount += 1
        } else {
            if displacement >= Self.jumpEpsilon { jumps.append(displacement) }
            if interval > 0, frame.rate > 0 {
                speedDeviations.append(abs(residualSeconds) / (interval * frame.rate))
            }
        }
        guard snapped || displacement >= Self.eventJumpThreshold else { return nil }
        return Jump(
            fromTime: last.danmakuTime, toTime: frame.danmakuTime,
            seconds: residualSeconds, points: residualSeconds * frame.velocity,
            interval: interval, rate: frame.rate,
            visibleCount: frame.visibleCount, windowVisible: frame.windowVisible, snapped: snapped)
    }

    /// 本窗口没有帧间隔时返回 nil。
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
            longStallCount: longStallCount,
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

    /// 丢弃间隔起点,保留已有样本。
    mutating func breakContinuity() {
        last = nil
    }

    /// 保留最后一帧作为下一窗口的间隔起点。
    mutating func resetWindow() {
        intervals.removeAll(keepingCapacity: true)
        refreshIntervals.removeAll(keepingCapacity: true)
        droppedFrames = 0
        longStallCount = 0
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
