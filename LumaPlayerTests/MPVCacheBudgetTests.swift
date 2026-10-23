import XCTest
@testable import LumaPlayer

/// 缓冲预算按码率标定(PITFALLS.md M2):`demuxer-max-*` 单位是字节,换算成秒随码率变;
/// 回退只认身后缓冲(`demuxer-max-back-bytes`),超出就得重新拉流。
final class MPVCacheBudgetTests: XCTestCase {
    func testUnknownOrNonPositiveBitrateUsesFloors() {
        for bitrate: Int64? in [nil, 0, -1] {
            let budget = MPVCacheBudget(bitrateBitsPerSecond: bitrate)
            XCTAssertEqual(budget.forwardBytes, 134_217_728, "bitrate \(String(describing: bitrate))")
            XCTAssertEqual(budget.backBytes, 52_428_800, "bitrate \(String(describing: bitrate))")
        }
    }

    func testLowBitrateStaysAtFloors() {
        // 10 Mbps:15s ≈ 19 MB、30s ≈ 37 MB,都低于下限
        let budget = MPVCacheBudget(bitrateBitsPerSecond: 10_000_000)
        XCTAssertEqual(budget.forwardBytes, 134_217_728)
        XCTAssertEqual(budget.backBytes, 52_428_800)
    }

    func testBackBufferGrowsBeforeForward() {
        // 40 Mbps:前向仍触下限,身后已按 30 秒长到 150 MB
        let budget = MPVCacheBudget(bitrateBitsPerSecond: 40_000_000)
        XCTAssertEqual(budget.forwardBytes, 134_217_728)
        XCTAssertEqual(budget.backBytes, 150_000_000)
    }

    func testHighBitrateScalesToTargets() {
        // 80 Mbps(4K remux 量级):前向 15 秒 = 150 MB,身后 30 秒 = 300 MB
        let budget = MPVCacheBudget(bitrateBitsPerSecond: 80_000_000)
        XCTAssertEqual(budget.forwardBytes, 150_000_000)
        XCTAssertEqual(budget.backBytes, 300_000_000)
    }

    func testExtremeBitrateHitsCapWithoutOverflow() {
        let capped = MPVCacheBudget(bitrateBitsPerSecond: 300_000_000)
        XCTAssertEqual(capped.forwardBytes, 536_870_912)
        XCTAssertEqual(capped.backBytes, 536_870_912)

        let maxed = MPVCacheBudget(bitrateBitsPerSecond: Int64.max)
        XCTAssertEqual(maxed.forwardBytes, 536_870_912)
        XCTAssertEqual(maxed.backBytes, 536_870_912)
    }

    func testOptionsMatchByteValues() {
        let budget = MPVCacheBudget(bitrateBitsPerSecond: 80_000_000)
        XCTAssertEqual(budget.options.map(\.name), ["demuxer-max-bytes", "demuxer-max-back-bytes"])
        XCTAssertEqual(budget.options.map(\.value), ["150000000", "300000000"])
    }

    /// 真实 libmpv(钉死的 Vendor/mpv commit)接受这两条启动选项才算数:
    /// `MPVPlayer.init` 把任何 `mpv_set_option_string` 失败当致命,选项名写错 = 播放器起不来。
    func testRealLibmpvAcceptsBudgetStartupOptions() {
        let player = MPVPlayer(bitrateBitsPerSecond: 80_000_000)
        XCTAssertNil(player.initializationFailure)
        player.shutdown()
    }
}
