import CoreGraphics
import Foundation

struct PlacedDanmaku: Sendable, Equatable {
    let comment: DanmakuComment
    /// 第几行(顶部 / 滚动从上往下数,底部从下往上数)
    let lane: Int
    /// pt
    let width: CGFloat
    /// 秒,弹幕时间轴,未叠加偏移
    let start: Double
    let end: Double
}

/// 弹幕排版(纯函数)。
/// - 滚动:同一速度 `画面宽 / scrollDuration`,所以不会追尾;上一条尾巴离开右缘再留 `gap` 即可进新的一条。
/// - 顶部 / 底部:居中静止 `staticDuration` 秒,各自一套行,可与滚动行重叠。
/// - 所有行都占着就丢掉这一条(密度控制),⛔ 不叠在别人身上。
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
        /// pt/s
        var velocity: CGFloat { viewportWidth / CGFloat(max(scrollDuration, 0.1)) }
    }

    static let staticDuration = 4.0
    /// 同一行两条滚动弹幕的最小间距,以字号为单位
    static let gapInFontSizes: CGFloat = 1.5

    /// - Parameters:
    ///   - comments: 按时间升序
    ///   - widthPerPoint: 与 `comments` 一一对应,字号 1pt 下的文字宽度(字号变了等比缩放,不必重测)
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

    /// `time` 时刻在场的弹幕(`placed` 按 `start` 升序)。两次二分,每帧只碰在场附近的几十条。
    static func visible(in placed: [PlacedDanmaku], at time: Double, maxLifetime: Double) -> ArraySlice<PlacedDanmaku> {
        let upper = partition(placed) { $0.start > time }
        let lower = partition(placed[..<upper]) { $0.start >= time - maxLifetime }
        return placed[lower..<upper]
    }

    /// `visible` 的回看窗口。
    static func maxLifetime(of placed: [PlacedDanmaku]) -> Double {
        placed.reduce(0) { max($0, $1.end - $1.start) }
    }

    /// 第一个满足 `predicate` 的下标(要求单调:前段 false、后段 true)。
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
