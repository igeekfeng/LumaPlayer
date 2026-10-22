import Foundation

/// 拖动进度怎么实现。⛔ 不能靠 `plan.method` 反推:同一个 `.transcode`,Emby 可停流 +
/// `StartTimeTicks` 重新起流(API_CONTRACT.md 4.5),百度转码流没有起流位置参数、只能从头
/// (`docs/BAIDU_PAN_API.md` §2.3)。推错会静默跳回 0:00 并把进度写成 0。
enum PlaybackSeekStrategy: Sendable, Equatable {
    /// 交给播放内核 seek(静态文件 / 支持 `Range` 的直连)
    case clientSeek
    /// 停旧流 + 带起流点重新取(Emby 转码)
    case restartStream
    /// 理由给用户看;⛔ 不装作拖成功了
    case unsupported(reason: String)

    /// 进度条与方向键据此决定给不给交互
    var allowsSeeking: Bool {
        if case .unsupported = self { return false }
        return true
    }

    var unavailableReason: String? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }
}
