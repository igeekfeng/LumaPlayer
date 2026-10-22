import Foundation
import os

/// mpv 事件的 Swift 侧表示,由 `MPVPlayer` 构造,经 `MPVEventBridge` 投递到 MainActor。
enum MPVPlayerEvent: Sendable, Equatable {
    case phaseChanged(MPVPlayerPhase)
    /// 已节流,≤ 5 次/秒(§6.3)
    case timePos(Double)
    case duration(Double)
    case paused(Bool)
    case seeking(Bool)
    /// `paused-for-cache`
    case buffering(Bool)
    case eofReached(Bool)
    /// `hwdec-current`:"no" 表示软解(§3.1)
    case hwdecChanged(String)
    case volume(Double)
    case muted(Bool)
    case speed(Double)
    /// `sub-delay`,秒,正 = 字幕延后(7.1)
    case subtitleDelay(Double)
    /// `track-list` 完整快照
    case trackList([MPVTrack])
    case endFile(MPVEndFileReason)
    /// 第一帧真实视频帧已画进 layer。每实例只发一次,纯音频永不发;渲染线程发出
    case firstVideoFrameRendered
}

/// client.h `mpv_end_file_reason`(§6.2)。
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

/// mpv 事件(任意线程)→ `@MainActor` 回调的唯一通道(MPV_INTEGRATION.md §6.3)。
///
/// `time-pos` 在调用方线程上节流到 ≤ 5 次/秒再进 MainActor,避免 SwiftUI 每帧重绘,
/// 被丢弃的事件不分配 Task。节流状态由 `OSAllocatedUnfairLock` 保护,存储属性全为 `let` + Sendable,
/// 无需 `@unchecked`。
final class MPVEventBridge: Sendable {

    private let handler: @MainActor (MPVPlayerEvent) -> Void

    /// 只对 time-pos 节流
    private static let timePosMinimumInterval: TimeInterval = 0.2

    private struct ThrottleState {
        var lastTimePosForwardAt: TimeInterval = 0
        var hasForwardedTimePos = false
    }

    private let throttle = OSAllocatedUnfairLock(initialState: ThrottleState())

    init(handler: @escaping @MainActor (MPVPlayerEvent) -> Void) {
        self.handler = handler
    }

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
