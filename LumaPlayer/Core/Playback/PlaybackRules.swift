import Foundation

/// 播放内核的阶段(ARCHITECTURE.md §8 的状态机)。
///
/// `main` 上它由 mpv 的事件驱动(`MPVPlayerPhase`);本分支换 AVKit 后由
/// 「起播请求 → `AVPlayer` 状态」映射过来。**取值与语义保持不变** ——
/// 依赖它的策略函数(`PlaybackRules.shouldPreventDisplaySleep`)因此不必改写。
///
/// ⛔ 状态机里**没有「已结束」态**:播完时仍停在 `.playing`,要另看 `isEnded`
/// (docs/PITFALLS.md Q7)。
enum PlaybackPhase: String, Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case failed
    case tearingDown
    case destroyed
}

/// 与播放器内核无关的播放策略:纯函数,不碰网络、不碰内核,可单测。
///
/// ## 为什么单独提出一个命名空间
///
/// 这些规则原本是 `PlayerViewModel` 上的静态方法。`exp/avkit-rust-core`
/// 摘掉 libmpv 时 `PlayerViewModel` 整个删了 —— 但**规则本身不是内核的实现细节**,
/// 它们写在 `API_CONTRACT.md`(续播位置、上报时机)与 `docs/PITFALLS.md`
/// (Q7 播完态)里,换内核也要照同一套走。所以搬到这里留着,不随内核一起消失。
enum PlaybackRules {

    /// 续播起点:往回退 `Metrics.resumeRewind` 秒接上前情,不退到 0 以下。
    /// 没有续播位置(0)时原样返回 0。
    static func resumePosition(from saved: Double) -> Double {
        guard saved > 0 else { return 0 }
        return max(0, saved - Metrics.resumeRewind)
    }

    /// 判定「已到续播点附近」的容差(秒)。精确 seek 的落点误差很小,3 秒足够
    /// 覆盖首个位置回调的延迟,又不会把文件开头误判为已就位。
    static let settledPositionTolerance: Double = 3

    /// 位置回调是否已可信。
    ///
    /// 只有 DirectStream + 非零续播点才需要等:客户端 seek 生效之前,内核报的是
    /// **文件开头**;若此时上报,服务端进度会被改回 0。
    /// 转码流从 `StartTimeTicks` 处起流,没有这一步客户端 seek,因此不必等。
    static func isSettledPosition(
        _ value: Double, startSeconds: Double, method: PlaybackMethod?
    ) -> Bool {
        guard startSeconds > 0, method == .directStream else { return true }
        return abs(value - startSeconds) < settledPositionTolerance
    }

    /// 播放期是否该阻止**显示器**休眠(与 `DisplaySleepAssertion` 配套)。
    ///
    /// 只在**正在播放**时抑制,暂停 / 播完 / 加载中 / 失败 / 拆播放器都还给系统
    /// (⛔ 不是「始终抑制」)。三个判据各有各的必要性:
    /// - `phase == .playing`:暂停是 `.paused`,加载是 `.loading`,失败是 `.failed`;
    /// - `!isPaused`:起播前就按了暂停时,phase 仍会随「文件就绪」变成 `.playing`,
    ///   只看 phase 会为一张暂停中的画面占着断言;
    /// - `!isEnded`:**播完时 phase 停在 `.playing`**(§8 状态机没有「已结束」态,
    ///   `docs/PITFALLS.md` Q7),不看这个就会让播完卡片一直占着断言。
    static func shouldPreventDisplaySleep(
        phase: PlaybackPhase, isPaused: Bool, isEnded: Bool
    ) -> Bool {
        phase == .playing && !isPaused && !isEnded
    }
}
