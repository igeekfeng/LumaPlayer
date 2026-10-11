import XCTest
@testable import LumaPlayer

final class PlaybackFailureProbeTests: XCTestCase {
    func testProbesWhenServerReturnedJSON() {
        XCTAssertTrue(PlaybackFailureProbe.shouldProbe(mpvLog: ["[ffmpeg] Mime-type: 'application/json'"]))
    }

    func testProbesWhenServerReturnedHTML() {
        XCTAssertTrue(PlaybackFailureProbe.shouldProbe(mpvLog: ["[ffmpeg] Mime-type: 'text/html; charset=UTF-8'"]))
    }

    func testDoesNotProbeForMediaOrMissingMime() {
        XCTAssertFalse(PlaybackFailureProbe.shouldProbe(mpvLog: ["[ffmpeg] Mime-type: 'video/mp4'"]))
        XCTAssertFalse(PlaybackFailureProbe.shouldProbe(mpvLog: ["[cplayer] Opening failed"]))
        XCTAssertFalse(PlaybackFailureProbe.shouldProbe(mpvLog: []))
    }

    func testProbesOnHTTPErrorStatus() {
        XCTAssertTrue(PlaybackFailureProbe.shouldProbe(mpvLog: ["[ffmpeg] https: HTTP error 403 Forbidden"]))
        XCTAssertTrue(PlaybackFailureProbe.shouldProbe(mpvLog: ["[ffmpeg] http: HTTP error 502 Bad Gateway"]))
        XCTAssertFalse(PlaybackFailureProbe.shouldProbe(mpvLog: ["[ffmpeg] https: HTTP error 30 x"]))
    }
}
