import Foundation

/// 播放事件泵(**与内核无关**):按固定节奏把引擎事件队列排空并投递给上层。
///
/// 当前内核(Erika)是 **pull 模型** —— 宿主自己轮询 `pollEvent()`。这层把
/// 「轮询 + 节流」收在一处,`PlayerViewModel` 只管收归一化事件,不再关心节奏。
/// 换成 push 模型的内核时,只要适配器把事件塞进队列,这层不用动。
///
/// ## 节流
/// 位置事件在**进入上层之前**合并到每 0.2 秒最多一次(与旧内核的节流一致):
/// 内核约每 100ms 发一次位置,不节流会让 SwiftUI 与进度上报被刷屏。
/// 其余事件不节流。
///
/// ## 线程
/// 全程 `@MainActor`(与 `PlaybackEngine` 同一隔离域),无需任何并发逃逸。
/// 循环里对引擎是**逐轮弱引用获取**:引擎被释放后循环自行退出,
/// 不阻塞也不泄漏。
@MainActor
final class PlaybackEventPump {

    /// 轮询间隔(约 30Hz,足以覆盖内核 ~10Hz 的位置事件)
    static let defaultInterval: Duration = .milliseconds(33)
    /// 两次向上转发位置事件之间的最小间隔(秒)
    static let positionForwardInterval: TimeInterval = 0.2

    private var task: Task<Void, Never>?

    /// 开始泵事件。重复调用会先停掉上一轮(一个泵同时只服务一个引擎)。
    func start(
        engine: any PlaybackEngine,
        interval: Duration = PlaybackEventPump.defaultInterval,
        onEvent: @escaping @MainActor (PlayerEvent) -> Void,
        onFailure: @escaping @MainActor (PlayerError) -> Void
    ) {
        stop()
        task = Task { [weak engine] in
            var lastPositionAt: TimeInterval = 0
            var hasForwardedPosition = false
            while !Task.isCancelled {
                guard let engine else { return }
                do {
                    while let event = try engine.pollEvent() {
                        if case .position = event {
                            let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                            guard !hasForwardedPosition
                                    || now - lastPositionAt >= Self.positionForwardInterval
                            else { continue }
                            lastPositionAt = now
                            hasForwardedPosition = true
                        }
                        onEvent(event)
                    }
                } catch let error as PlayerError {
                    onFailure(error)
                } catch {
                    onFailure(PlayerError(String(describing: error)))
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    /// 停止泵事件(可重入)
    func stop() {
        task?.cancel()
        task = nil
    }
}
