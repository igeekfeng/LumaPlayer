import Foundation

/// 一条弹幕(提供方无关)。渲染层只认这个类型,加提供方只需写一个 DTO → `DanmakuComment` 的转换。
struct DanmakuComment: Codable, Sendable, Equatable, Identifiable {

    enum Mode: Int, Codable, Sendable {
        case scroll
        /// 居中静止
        case top
        /// 居中静止
        case bottom
    }

    /// 弹弹play 是 `cid`
    let id: Int64
    /// 秒,相对视频 0 点,未叠加偏移
    let time: Double
    let mode: Mode
    /// 0xRRGGBB
    let color: UInt32
    let text: String
}

extension DanmakuComment {

    /// `docs/DANDANPLAY_API.md` §5。`p` = `出现时间(秒),模式(1 滚动 / 4 底部 / 5 顶部),颜色(RGB 整数),用户ID`。
    /// 解析不了返回 nil,由调用方计数丢弃,⛔ 不猜默认模式 / 颜色硬塞。
    init?(dandanplay comment: DandanplayComment) {
        guard let p = comment.p, let text = comment.m?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let fields = p.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3,
              let time = Double(fields[0]), time.isFinite, time >= 0,
              let rawMode = Int(fields[1]),
              let rawColor = UInt32(fields[2]), rawColor <= 0xFFFFFF else { return nil }
        let mode: Mode
        switch rawMode {
        case 1: mode = .scroll
        case 4: mode = .bottom
        case 5: mode = .top
        default: return nil
        }
        self.init(id: comment.cid, time: time, mode: mode, color: rawColor, text: text)
    }

    /// 按时间排序(渲染层二分查找要求有序);`dropped` 供状态栏如实显示丢弃条数。
    static func fromDandanplay(_ comments: [DandanplayComment]) -> (comments: [DanmakuComment], dropped: Int) {
        let parsed = comments.compactMap(DanmakuComment.init(dandanplay:))
        return (parsed.sorted { ($0.time, $0.id) < ($1.time, $1.id) }, comments.count - parsed.count)
    }
}
