import Foundation

/// 一次播放的 mpv 缓冲预算:`demuxer-max-bytes`(前向)与 `demuxer-max-back-bytes`(身后)。
///
/// 两个选项的单位是字节,折算成秒随码率变,⛔ 不能拍固定值:前向见底会缓冲;
/// 回退超出身后缓冲保留的范围就得重新拉流(只有命中身后缓冲的 seek 才是纯内存操作)。
/// 只在 `mpv_initialize()` 之前设(`MPVPlayer.init`,MPV_INTEGRATION.md §3)。
struct MPVCacheBudget: Sendable, Equatable {
    /// 前向 / 身后各自要保住的秒数(按码率折算,只在换算结果高于下限时生效)。
    private static let forwardTargetSeconds: Int64 = 15
    private static let backTargetSeconds: Int64 = 30
    /// 下限:服务端不给 / 给错码率时的兜底(50 MiB 即 mpv 默认),码率再低也保住这个量。
    private static let forwardFloorBytes: Int64 = 128 * 1024 * 1024
    private static let backFloorBytes: Int64 = 50 * 1024 * 1024
    /// 上限:防极端码率吃内存(前向 + 身后最坏合计 1 GiB)。
    private static let capBytes: Int64 = 512 * 1024 * 1024

    /// `demuxer-max-bytes`:播放位置**往前**保留 / 预读的字节。
    let forwardBytes: Int64
    /// `demuxer-max-back-bytes`:播放位置**身后**保留的字节,决定回退多远不用重新拉流。
    let backBytes: Int64

    /// - Parameter bitrateBitsPerSecond: `EmbyMediaSource.bitrate`(bps)。
    ///   nil / ≤0(百度、本地这类合成源)→ 下限。
    init(bitrateBitsPerSecond: Int64?) {
        let bytesPerSecond = max(bitrateBitsPerSecond ?? 0, 0) / 8
        forwardBytes = Self.clamped(
            bytesPerSecond, seconds: Self.forwardTargetSeconds, floor: Self.forwardFloorBytes)
        backBytes = Self.clamped(
            bytesPerSecond, seconds: Self.backTargetSeconds, floor: Self.backFloorBytes)
    }

    /// 启动期 `mpv_set_option_string` 表项(MPV_INTEGRATION.md §3)。
    var options: [(name: String, value: String)] {
        [("demuxer-max-bytes", String(forwardBytes)),
         ("demuxer-max-back-bytes", String(backBytes))]
    }

    /// 秒数 × 码率 → 字节,夹在 [floor, cap]。先比较再乘:码率来自服务端,
    /// Int64 乘法溢出是运行时陷阱,不是可捕获错误。
    private static func clamped(_ bytesPerSecond: Int64, seconds: Int64, floor: Int64) -> Int64 {
        let target = bytesPerSecond > capBytes / seconds ? capBytes : bytesPerSecond * seconds
        return min(max(target, floor), capBytes)
    }
}
