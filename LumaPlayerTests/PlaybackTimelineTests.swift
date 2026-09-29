import XCTest
@testable import LumaPlayer

final class PlaybackTimelineTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 0)

    func testLineReportsPerStageDeltasAndTotal() {
        var timeline = PlaybackTimeline()
        timeline.mark(.playbackInfo, elapsed: .milliseconds(500))
        timeline.mark(.glReady, elapsed: .milliseconds(560))
        timeline.mark(.playing, elapsed: .milliseconds(3160))
        timeline.mark(.firstFrame, elapsed: .milliseconds(3410))

        let line = timeline.line(method: "DirectStream", host: "emby.test", directStreamURLProvided: true, date: date)

        XCTAssertTrue(timeline.isFinished)
        XCTAssertTrue(line.contains("TIMING method=DirectStream host=emby.test dsu=provided total=3.41s"), line)
        XCTAssertTrue(line.contains("playbackInfo=0.50s glReady=0.06s playing=2.60s firstFrame=0.25s"), line)
        XCTAssertFalse(line.contains("未出画面"))
    }

    func testEachStageOnlyRecordsFirstOccurrence() {
        var timeline = PlaybackTimeline()
        timeline.mark(.playing, elapsed: .seconds(1))
        timeline.mark(.playing, elapsed: .seconds(9))
        XCTAssertEqual(timeline.marks.count, 1)
        XCTAssertEqual(timeline.marks.first?.at, .seconds(1))
    }

    func testMarksAfterFirstFrameAreIgnored() {
        var timeline = PlaybackTimeline()
        timeline.mark(.firstFrame, elapsed: .seconds(1))
        timeline.mark(.playbackInfo, elapsed: .seconds(2))
        XCTAssertEqual(timeline.marks.count, 1)
    }

    func testUnfinishedTimelineIsLabelled() {
        var timeline = PlaybackTimeline()
        timeline.mark(.playbackInfo, elapsed: .milliseconds(200))
        let line = timeline.line(method: "Transcode", host: nil, directStreamURLProvided: false, date: date)
        XCTAssertTrue(line.contains("host=?"))
        XCTAssertTrue(line.contains("dsu=absent"))
        XCTAssertTrue(line.contains("未出画面"))
    }

    /// 只有第一次记下 firstFrame 才算「结束」,之后的 time-pos 事件不能再触发日志(曾重复写 4 行)
    func testMarkReturnsTrueOnlyOnceWhenFinished() {
        var timeline = PlaybackTimeline()
        XCTAssertFalse(timeline.mark(.playing, elapsed: .seconds(1)))
        XCTAssertTrue(timeline.mark(.firstFrame, elapsed: .seconds(1)))
        XCTAssertFalse(timeline.mark(.firstFrame, elapsed: .seconds(2)))
        XCTAssertFalse(timeline.mark(.firstFrame, elapsed: .seconds(3)))
    }

    func testTimingDetailKeepsNetworkModulesAndDropsRendererNoise() {
        let log = [
            "+0.10 [libmpv_render] GL_VENDOR='Apple'",
            "+0.50 [stream_callback] Opening https://emby.test/x",
            "+7.20 [ffmpeg] Mime-type: 'video/mp4'",
            "+7.30 [demux] Detected file format: mov,mp4",
            "+7.40 [cplayer] Video --vid=1 (h264)",
        ]
        XCTAssertEqual(NetworkDiagnostics.timingDetailLines(log), Array(log[1...]))
    }

    func testIsSlowUsesTotalDuration() {
        var fast = PlaybackTimeline()
        fast.mark(.firstFrame, elapsed: .milliseconds(2900))
        XCTAssertFalse(fast.isSlow)

        var slow = PlaybackTimeline()
        slow.mark(.firstFrame, elapsed: .seconds(3))
        XCTAssertTrue(slow.isSlow)
    }
}
