import CoreGraphics
import Foundation

/// 一条已排好位置的弹幕。
struct PlacedDanmaku: Sendable, Equatable {
    let comment: DanmakuComment
    /// 第几行(顶部 / 滚动从上往下数,底部从下往上数)
    let lane: Int
    /// 文字宽度(pt)
    let width: CGFloat
    /// 出现 / 消失时间(秒,弹幕时间轴,未叠加偏移)
    let start: Double
    let end: Double
}

/// 弹幕排版:**纯函数**,只依赖入参(画面尺寸、字号、时长、各条宽度),单测覆盖。
///
/// ## 规则
///
/// - **滚动**:所有滚动弹幕**同一速度** `v = 画面宽 / scrollDuration`,从右缘进、左缘出,
///   在场时长 `(画面宽 + 文字宽) / v`。同速就不存在「后一条追上前一条」,
///   一行能放下一条新弹幕的条件只有一个:上一条的尾巴已经离开右缘(再留 `gap`)。
/// - **顶部 / 底部**:居中静止 `staticDuration` 秒,各自一套行,与滚动行可以重叠(同主流站点)。
/// - **放不下就丢**:所有行都占着时这一条不显示(密度控制),⛔ 不叠在别人身上。
///
/// 行数 = `画面高 × displayArea / 行高`,至少 1 行。
enum DanmakuLayout {

    struct Parameters: Sendable, Equatable {
        var viewportWidth: CGFloat
        var viewportHeight: CGFloat
        var fontSize: CGFloat
        var scrollDuration: Double
        var displayArea: Double
        var showsScroll = true
        var showsTop = true
        var showsBottom = true

        var lineHeight: CGFloat { fontSize * 1.3 }
        var laneCount: Int {
            guard lineHeight > 0, viewportHeight > 0 else { return 0 }
            return max(1, Int((viewportHeight * displayArea / lineHeight).rounded(.down)))
        }
        /// 滚动速度(pt/s)
        var velocity: CGFloat { viewportWidth / CGFloat(max(scrollDuration, 0.1)) }
    }

    static let staticDuration = 4.0
    /// 同一行两条滚动弹幕之间的最小间距(以字号为单位)
    static let gapInFontSizes: CGFloat = 1.5

    /// - Parameters:
    ///   - comments: 按时间升序
    ///   - widthPerPoint: 与 `comments` 一一对应,每条在**字号 1pt** 下的文字宽度
    ///     (测一次,字号变了等比缩放,不必重新测量)
    /// - Returns: 按 `start` 升序
    static func layout(
        _ comments: [DanmakuComment],
        widthPerPoint: [CGFloat],
        parameters p: Parameters
    ) -> [PlacedDanmaku] {
        precondition(comments.count == widthPerPoint.count, "宽度数组必须与弹幕一一对应")
        let lanes = p.laneCount
        guard lanes > 0, p.viewportWidth > 0 else { return [] }
        let velocity = Double(p.velocity)
        let gap = Double(p.fontSize * gapInFontSizes)

        // 每行「何时空出来」
        var scrollFreeAt = [Double](repeating: -.infinity, count: lanes)
        var topFreeAt = scrollFreeAt
        var bottomFreeAt = scrollFreeAt

        var placed: [PlacedDanmaku] = []
        placed.reserveCapacity(comments.count)

        for (index, comment) in comments.enumerated() {
            let width = widthPerPoint[index] * p.fontSize
            let start = comment.time
            switch comment.mode {
            case .scroll:
                guard p.showsScroll, let lane = firstFree(scrollFreeAt, at: start) else { continue }
                scrollFreeAt[lane] = start + (Double(width) + gap) / velocity
                let end = start + (Double(p.viewportWidth) + Double(width)) / velocity
                placed.append(PlacedDanmaku(comment: comment, lane: lane, width: width, start: start, end: end))
            case .top:
                guard p.showsTop, let lane = firstFree(topFreeAt, at: start) else { continue }
                topFreeAt[lane] = start + staticDuration
                placed.append(PlacedDanmaku(
                    comment: comment, lane: lane, width: width, start: start, end: start + staticDuration))
            case .bottom:
                guard p.showsBottom, let lane = firstFree(bottomFreeAt, at: start) else { continue }
                bottomFreeAt[lane] = start + staticDuration
                placed.append(PlacedDanmaku(
                    comment: comment, lane: lane, width: width, start: start, end: start + staticDuration))
            }
        }
        return placed
    }

    private static func firstFree(_ freeAt: [Double], at time: Double) -> Int? {
        freeAt.firstIndex { $0 <= time }
    }

    // MARK: - 取可见

    /// `time` 时刻在场的弹幕(`placed` 按 `start` 升序)。
    ///
    /// 二分找到「`start` 晚于 `time`」的边界,再往回扫到 `time - maxLifetime` 为止 ——
    /// 每帧只碰在场附近的几十条,弹幕总数上万也不卡。
    static func visible(in placed: [PlacedDanmaku], at time: Double, maxLifetime: Double) -> ArraySlice<PlacedDanmaku> {
        let upper = partition(placed) { $0.start > time }
        let lower = partition(placed[..<upper]) { $0.start >= time - maxLifetime }
        return placed[lower..<upper]
    }

    /// 最长在场时长(`visible` 的回看窗口)。
    static func maxLifetime(of placed: [PlacedDanmaku]) -> Double {
        placed.reduce(0) { max($0, $1.end - $1.start) }
    }

    /// 第一个满足 `predicate` 的下标(要求 `predicate` 在序列上单调:前段 false、后段 true)。
    private static func partition<C: RandomAccessCollection>(
        _ items: C, where predicate: (C.Element) -> Bool
    ) -> C.Index {
        var low = items.startIndex
        var high = items.endIndex
        while low < high {
            let mid = items.index(low, offsetBy: items.distance(from: low, to: high) / 2)
            if predicate(items[mid]) {
                high = mid
            } else {
                low = items.index(after: mid)
            }
        }
        return low
    }
}
