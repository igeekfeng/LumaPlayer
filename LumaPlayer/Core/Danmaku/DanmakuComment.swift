import Foundation

/// 一条弹幕(**提供方无关**的模型;弹弹play 只是第一个提供方)。
///
/// 渲染层(`DanmakuLayout` / `DanmakuOverlayView`)只认这个类型,
/// 换 / 加提供方时只需要写一个「提供方 DTO → `DanmakuComment`」的转换。
struct DanmakuComment: Codable, Sendable, Equatable, Identifiable {

    enum Mode: Int, Codable, Sendable {
        /// 从右往左滚动
        case scroll
        /// 顶部居中静止
        case top
        /// 底部居中静止
        case bottom
    }

    /// 提供方给的弹幕 id(弹弹play 是 `cid`)
    let id: Int64
    /// 出现时间(秒,相对视频 0 点;**未**叠加偏移)
    let time: Double
    let mode: Mode
    /// 0xRRGGBB
    let color: UInt32
    let text: String
}

extension DanmakuComment {

    /// 解析弹弹play 的一条弹幕(`docs/DANDANPLAY_API.md` §5)。
    ///
    /// `p` = `出现时间,模式,颜色,用户ID`:
    /// - 时间:秒,两位小数
    /// - 模式:1 普通(滚动)、4 底部、5 顶部
    /// - 颜色:`R*256*256 + G*256 + B`
    ///
    /// 解析不了(字段不够、数字不合法、未知模式、空文本)返回 nil —— 由调用方计数后丢弃,
    /// ⛔ 不猜一个「默认滚动 / 白色」把它硬塞进去。
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

    /// 批量转换并按时间排序(渲染层按时间二分查找,要求有序)。
    /// 返回被丢弃的条数,供状态栏如实显示「已加载 N 条(丢弃 M 条无法解析)」。
    static func fromDandanplay(_ comments: [DandanplayComment]) -> (comments: [DanmakuComment], dropped: Int) {
        let parsed = comments.compactMap(DanmakuComment.init(dandanplay:))
        return (parsed.sorted { ($0.time, $0.id) < ($1.time, $1.id) }, comments.count - parsed.count)
    }
}
