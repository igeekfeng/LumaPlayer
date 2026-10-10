import XCTest
@testable import LumaPlayer

/// R13 的纯逻辑:HLS 转码流的时间原点在起流点,不是媒体开头。
///
/// 这条是本机实测逼出来的(文档 8.5 实测二 / 第 9 节 R13),⛔ 不是推演:
/// 带 `StartTimeTicks=5s` 起流时 `AVPlayerItem.currentTime()` 仍从 0 开始。
/// 换算错了的后果很具体 —— 续播的转码流会把服务端进度**写回 0**。
///
/// 实测证据在 `Scripts/verify-avkit-playback.sh`(真起播那条腿断言时间原点仍是 0),
/// 这里验的是播放层拿它做换算的那一步。
final class PlaybackTimeBaseTests: XCTestCase {

    /// DirectStream:服务端吐整份文件、客户端自己 seek,所以内核位置**就是**绝对位置。
    func testDirectStreamHasNoOffset() {
        let base = PlaybackTimeBase(method: .directStream, startSeconds: 595)
        XCTAssertEqual(base.offsetSeconds, 0)
        XCTAssertEqual(base.absolute(fromKernel: 12), 12)
        XCTAssertEqual(base.kernel(fromAbsolute: 12), 12)
    }

    /// 转码:偏移就是起流点。
    func testTranscodeOffsetsByStartPoint() {
        let base = PlaybackTimeBase(method: .transcode, startSeconds: 5)
        XCTAssertEqual(base.absolute(fromKernel: 0), 5, "内核的 0 必须映射回起流点")
        XCTAssertEqual(base.absolute(fromKernel: 3), 8)
        XCTAssertEqual(base.kernel(fromAbsolute: 8), 3, "反过来也要对(用户在进度条上拖到 8 秒)")
    }

    /// 转码从头起流时偏移为 0 —— 与 DirectStream 行为一致。
    func testTranscodeFromZeroHasNoOffset() {
        let base = PlaybackTimeBase(method: .transcode, startSeconds: 0)
        XCTAssertEqual(base.absolute(fromKernel: 7), 7)
    }

    /// 脏输入不制造负位置,也不让 NaN 漏进上报与进度条。
    func testInvalidInputsAreClamped() {
        let base = PlaybackTimeBase(method: .transcode, startSeconds: 5)
        XCTAssertEqual(base.kernel(fromAbsolute: 2), 0, "拖到起流点之前 → 内核 0,不给负数")
        XCTAssertEqual(base.absolute(fromKernel: -1), 5, "内核报了负数也不把绝对位置拉下去")

        let nan = PlaybackTimeBase(offsetSeconds: .nan)
        XCTAssertEqual(nan.offsetSeconds, 0)
        XCTAssertEqual(nan.absolute(fromKernel: .nan), 0)
        XCTAssertEqual(nan.kernel(fromAbsolute: .infinity), 0)
    }

    /// 总时长**优先服务端**:转码起流后内核只剩「从起流点到结尾」那一段。
    func testServerDurationWinsOverKernelDuration() {
        let base = PlaybackTimeBase(method: .transcode, startSeconds: 600)
        XCTAssertEqual(base.absoluteDuration(kernelDuration: 1200, serverDuration: 1800), 1800,
                       "服务端 RunTimeTicks 是权威值")
        XCTAssertEqual(base.absoluteDuration(kernelDuration: 1200, serverDuration: nil), 1800,
                       "拿不到服务端时长时才退回「内核时长 + 偏移」(推断,见文档 R13)")
        XCTAssertEqual(base.absoluteDuration(kernelDuration: 1200, serverDuration: 0), 1800,
                       "服务端给 0 等于没给(8.1:不把缺省值当已知值)")
        XCTAssertEqual(base.absoluteDuration(kernelDuration: 0, serverDuration: nil), 0,
                       "两边都没有就是未知 —— ⛔ 不拿偏移冒充总时长")
    }
}
