import Foundation

/// 播放结束的原因(**与内核无关**)。
///
/// 内核的「播完了」信号五花八门:mpv 有 `END_FILE` 带 reason,Erika 没有独立
/// 的 EOF 事件/状态。适配器负责把它归一成这三种,上层据此决定是弹「下一集」
/// 卡片、还是报错、还是什么都不做。
enum PlayerEndReason: Sendable, Equatable {
    /// 自然播完(到达媒体末尾)
    case eof
    /// 外部停止(我们主动 `stop()`,不是失败)
    case stopped
    /// 播放失败;关联消息面向诊断
    case error(String)
}

/// 播放引擎事件(**与内核无关**)。
///
/// 适配器(`Core/Erika/`)把内核事件翻译成这些 case,`PlayerViewModel` 只处理它们。
///
/// 刻意**不包含**的部分:
/// - 倍速 / 音量 / 静音读回:当前内核没有这些读回事件,`PlayerViewModel` 改为
///   乐观更新自己的状态(设了就认为是这个值);
/// - 字幕延迟:当前内核没有对应能力,功能已去掉;
/// - 缓冲进度 / 缓存速度:同上;
/// - 视频参数 / 解码器 / 音频输出变化:只在适配器内部缓存,供统计快照 `stats()` 用,
///   不逐条推给上层(它们变化频繁且只有统计面板需要)。
enum PlayerEvent: Sendable, Equatable {
    /// 相位迁移(loading / playing / paused / failed …)
    case phaseChanged(PlayerPhase)
    /// 当前播放秒数
    case position(Double)
    /// 总时长(秒)
    case duration(Double)
    /// 暂停 / 恢复
    case paused(Bool)
    /// 缓冲中(UI 显示加载状态)
    case buffering(Bool)
    /// 播放结束(eof / 外部停止 / 失败)
    case ended(PlayerEndReason)
    /// 轨道列表变化后的完整快照
    case tracksChanged([PlayerTrack])
    /// 当前选中的音轨 / 字幕轨变化(`nil` = 未选中 / 字幕关闭)
    case trackSelectionChanged(audio: Int64?, subtitle: Int64?)
    /// 视频表面已挂接(计时线用)
    case surfaceAttached
    /// 引擎报错(不改变相位时为提示性错误)
    case error(PlayerError)
}
