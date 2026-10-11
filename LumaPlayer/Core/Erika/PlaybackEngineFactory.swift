import Foundation

/// 播放引擎工厂(组合根用)。**这是 `Core/Erika/` 之外唯一提到具体内核类型名的地方**,
/// 由 `AppContainer` 调用;上层只认 `PlaybackEngine` 协议。
///
/// 换内核时改这里(以及 `Core/Erika/` 目录),其余不动。
@MainActor
enum PlaybackEngineFactory {
    static func make(upscaler: PlayerUpscaler) throws -> any PlaybackEngine {
        try ErikaPlaybackEngine(upscaler: upscaler)
    }
}
