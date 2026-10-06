import Foundation
import os

/// mpv 事件(属性变化 / 文件生命周期 / 状态机迁移)的 Swift 侧表示。
/// 由 `MPVPlayer` 的事件线程构造,经 `MPVEventBridge` 投递到 MainActor。
enum MPVPlayerEvent: Sendable, Equatable {
    /// 状态机迁移(loading / playing / paused / failed / destroyed …)
    case phaseChanged(MPVPlayerPhase)
    /// 当前播放秒数(已按 §6.3 节流,≤ 5 次/秒)
    case timePos(Double)
    case duration(Double)
    case paused(Bool)
    case seeking(Bool)
    /// `paused-for-cache`:缓冲中(UI 显示加载状态)
    case buffering(Bool)
    case eofReached(Bool)
    /// `hwdec-current` 属性:"no" 表示软解(§3.1,S2 用来验证 hwdec=auto 实际生效情况)
    case hwdecChanged(String)
    case volume(Double)
    /// 静音状态(`UI_DESIGN.md` 5.3 的 M 键)
    case muted(Bool)
    case speed(Double)
    /// `sub-delay` 读回值(秒,正 = 字幕延后显示;MPV_INTEGRATION.md 7.1)
    case subtitleDelay(Double)
    /// `track-list` 的完整快照(音轨/字幕菜单与 5.1 的轨道索引)
    case trackList([MPVTrack])
    /// 文件播放结束(eof=自然播完;stop=外部停止;error=加载/播放失败)
    case endFile(MPVEndFileReason)
}

/// `MPV_EVENT_END_FILE` 的 reason 映射(client.h `mpv_end_file_reason`,§6.2)。
enum MPVEndFileReason: Sendable, Equatable {
    case eof
    case stop
    case quit
    case redirect
    /// 播放失败;关联消息来自 `mpv_error_string`
    case error(String)

    init?(rawValue: Int32) {
        switch rawValue {
        case 0: self = .eof
        case 2: self = .stop
        case 3: self = .quit
        case 5: self = .redirect
        case 4: self = .error("")
        default: return nil
        }
    }
}

/// 事件桥:mpv 事件(任意线程)→ `@MainActor` 回调的唯一通道
/// (MPV_INTEGRATION.md §6.3 线程模型,强制要求)。
///
/// ## 节流规则(§6.3)
/// `time-pos` 更新频率高,合并到每秒最多 5 次再进入 MainActor,
/// 避免整个 SwiftUI 树每帧重绘。节流在**进入 MainActor 之前**完成
/// (发生在调用方线程上),因此被丢弃的事件不会产生任何 Task 分配。
///
/// ## 线程安全
/// 本类自身用 `OSAllocatedUnfairLock` 保护节流状态,全部存储属性为
/// `let` + Sendable,天然满足 `Sendable`,无需 `@unchecked`。
/// 回调统一 hop 到 MainActor 执行(闭包只捕获 Sendable 值)。
final class MPVEventBridge: Sendable {

    private let handler: @MainActor (MPVPlayerEvent) -> Void

    /// 节流窗口:两次 time-pos 转发之间的最小间隔(0.2s ≈ 5 次/秒)。
    /// 其他事件不节流。
    private static let timePosMinimumInterval: TimeInterval = 0.2

    private struct ThrottleState {
        var lastTimePosForwardAt: TimeInterval = 0
        var hasForwardedTimePos = false
    }

    private let throttle = OSAllocatedUnfairLock(initialState: ThrottleState())

    init(handler: @escaping @MainActor (MPVPlayerEvent) -> Void) {
        self.handler = handler
    }

    /// 从任意线程提交事件。time-pos 之外的类型直通。
    func submit(_ event: MPVPlayerEvent) {
        if case .timePos = event {
            let shouldForward = throttle.withLock { state -> Bool in
                let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                guard !state.hasForwardedTimePos
                        || now - state.lastTimePosForwardAt >= Self.timePosMinimumInterval
                else { return false }
                state.lastTimePosForwardAt = now
                state.hasForwardedTimePos = true
                return true
            }
            guard shouldForward else { return }
        }
        let handler = self.handler
        Task { @MainActor in
            handler(event)
        }
    }
}
