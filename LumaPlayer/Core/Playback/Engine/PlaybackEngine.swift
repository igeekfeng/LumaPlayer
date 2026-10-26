import AppKit

/// 播放引擎抽象(**与内核无关**)。
///
/// ## 为什么要有这层
/// 播放内核(当前是 Erika)还在频繁变更。把内核 API 全部收在 `Core/Erika/` 的
/// 适配器里,上层(`PlayerViewModel`、视图、设置)只依赖本协议与归一化类型,
/// 内核升级 / 换内核时改动收敛在一个目录。
///
/// ## 线程
/// 当前内核 `ErikaPlayer` 是 `@MainActor`,所以本协议也标 `@MainActor`:
/// 适配器全程在主线程,**不需要任何 `@unchecked Sendable` / `nonisolated(unsafe)`
/// 逃逸**(这也是换内核后 CLAUDE.md 硬规则 3 的 `Core/MPV/` 例外可以作废的原因)。
///
/// ## 生命周期
/// 一个引擎实例只播一个 URL;换媒体 = `close()` 后**新建**引擎。`close()` 之后
/// 任何方法都可能抛错,调用方不得复用。
@MainActor
protocol PlaybackEngine: AnyObject {

    /// 当前相位(内核状态归一化后的结果)
    var phase: PlayerPhase { get }

    // MARK: - 生命周期与播放控制

    /// 打开媒体(同步完成探测与轨道解析)。`headers` 结构化传入,值内逗号无需转义。
    func open(url: URL, headers: [String: String]) throws
    /// 开始播放(异步;最终结果以事件为准)
    func play() throws
    func pause() throws
    func stop() throws
    /// 关闭并释放媒体资源。之后引擎不可复用。
    func close()

    /// 跳转到指定秒数
    func seek(to seconds: Double) throws
    /// 倍速(1.0 = 原速)
    func setRate(_ rate: Double) throws
    /// 音量(0.0–1.0;静音由上层用 0 实现,内核无独立静音开关)
    func setVolume(_ volume: Double) throws
    /// 神经超分档位
    func setUpscaler(_ upscaler: PlayerUpscaler) throws

    // MARK: - 轨道与字幕

    func tracks() throws -> [PlayerTrack]
    /// 选音轨;`nil` = 不指定
    func selectAudioTrack(id: Int64?) throws
    /// 选字幕轨;`nil` = 关闭字幕
    func selectSubtitleTrack(id: Int64?) throws
    func setSubtitleStyle(_ style: PlayerSubtitleStyle) throws

    // MARK: - 表面 / 事件 / 统计

    /// 视频承载视图(**每次返回同一个实例**)。视图层用 `PlayerSurfaceView` 承载它,
    /// 由 SDK 视图自己驱动渲染循环,上层不需要等「渲染上下文挂好」。
    func makeVideoSurface() -> NSView

    /// 非阻塞取一个事件;队列为空返回 `nil`。
    func pollEvent() throws -> PlayerEvent?

    /// 当前统计快照(读不到就是空快照,不抛错给 UI)。
    func stats() throws -> PlayerStats

    /// 本次 `open` 以来内核记下的 warn 及以上日志(旧 → 新,条数有上限),
    /// 播放失败时附进诊断日志。内核没有日志设施时返回空数组。
    func diagnosticLogs() throws -> [PlayerLogEntry]
}
