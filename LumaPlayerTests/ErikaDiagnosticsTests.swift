import XCTest
@testable import LumaPlayer

/// Erika JSON 诊断的解析(ERIKA_INTEGRATION.md §9)。
///
/// JSON 按 liberika 0.3.0 `docs/capi_reference.md`「Agent diagnostics (JSON)」与
/// `crates/erika/src/diagnostics.rs` / `trace.rs` 的字段名手写,只保留用得到的分区。
/// 真实内核的输出是否一致,要靠真机统计面板看(见 KNOWN_ISSUES.md Q48)。
final class ErikaDiagnosticsTests: XCTestCase {

    // MARK: - 诊断快照

    func testSnapshotWithHardwareDecoder() throws {
        let snapshot = try ErikaDiagnostics.snapshot(from: Data(#"""
        {"schema":1,"capturedAtUnixMs":1761134400123,
         "decoder":{"requestedBackend":"videotoolbox","activeBackend":"videotoolbox",
                    "previousBackend":null,"hardware":true,"fellBack":false,"fallbackCount":0,
                    "stage":"open_videotoolbox","reason":null,"codec":"hevc"},
         "timing":{"scheduler":{"presentedFrames":1200,"lateDroppedFrames":3,"forcedLatePresents":1}}}
        """#.utf8))

        XCTAssertEqual(snapshot.decoder?.activeBackend, "videotoolbox")
        XCTAssertEqual(snapshot.decoder?.hardware, true)
        XCTAssertEqual(snapshot.timing?.scheduler?.lateDroppedFrames, 3)
        XCTAssertNil(snapshot.decoder.flatMap(ErikaDiagnostics.fallbackReason))
    }

    /// 第一次解码器切换之前,内核给 `decoder: null` —— 不是解析失败
    func testSnapshotBeforeFirstDecoderTransition() throws {
        let snapshot = try ErikaDiagnostics.snapshot(from: Data(#"""
        {"schema":1,"decoder":null,"timing":{"scheduler":{"lateDroppedFrames":0}}}
        """#.utf8))
        XCTAssertNil(snapshot.decoder)
        XCTAssertEqual(snapshot.timing?.scheduler?.lateDroppedFrames, 0)
    }

    /// VideoToolbox 初始化失败、FFmpeg 退回软解(0.3.0 起内核如实上报)
    func testFallbackToSoftwareCarriesReason() throws {
        let snapshot = try ErikaDiagnostics.snapshot(from: Data(#"""
        {"schema":1,
         "decoder":{"requestedBackend":"videotoolbox","activeBackend":"software",
                    "hardware":false,"fellBack":true,"fallbackCount":1,
                    "reason":"hwaccel initialisation returned error"}}
        """#.utf8))
        let decoder = try XCTUnwrap(snapshot.decoder)
        XCTAssertEqual(ErikaDiagnostics.fallbackReason(decoder), "hwaccel initialisation returned error")
        XCTAssertNil(snapshot.timing)
    }

    /// 退回后又恢复了硬解:当前是硬解,不显示回退原因
    func testRestoredHardwareHasNoFallbackReason() throws {
        let decoder = try XCTUnwrap(ErikaDiagnostics.snapshot(from: Data(#"""
        {"schema":1,"decoder":{"requestedBackend":"videotoolbox","activeBackend":"videotoolbox",
         "hardware":true,"fellBack":true,"fallbackCount":1,"reason":"restored"}}
        """#.utf8)).decoder)
        XCTAssertNil(ErikaDiagnostics.fallbackReason(decoder))
    }

    func testFallbackWithoutReasonNamesRequestedBackend() throws {
        let decoder = try XCTUnwrap(ErikaDiagnostics.snapshot(from: Data(#"""
        {"schema":1,"decoder":{"requestedBackend":"videotoolbox","activeBackend":"software",
         "hardware":false,"fellBack":true,"reason":null}}
        """#.utf8)).decoder)
        XCTAssertEqual(ErikaDiagnostics.fallbackReason(decoder), "videotoolbox 不可用")
    }

    func testMalformedSnapshotThrows() {
        XCTAssertThrowsError(try ErikaDiagnostics.snapshot(from: Data(#"{"decoder":{}}"#.utf8)))
    }

    // MARK: - 日志环

    /// 两种条目:FFmpeg 原文给 `message`,结构化诊断给 `data`;重复折叠的取最后一次的时间
    func testLogPageParsesMessageAndStructuredEntries() throws {
        let page = try ErikaDiagnostics.logs(from: Data(#"""
        {"schema":1,"retained":15,"oldestSeq":1,"nextSeq":16,"redacted":true,
         "entries":[
           {"seq":3,"unixMs":1761134400123,"level":"error","source":"ffmpeg","event":null,"count":1,
            "message":"[mov,mp4 @ 0x1] moov atom not found"},
           {"seq":4,"unixMs":1761134400140,"level":"warn","source":"erika","event":"video_decoder",
            "count":2,"lastUnixMs":1761134400410,
            "data":{"stage":"open_avcodec_to_software","event":"video_decoder"}}
         ]}
        """#.utf8))

        XCTAssertEqual(page.nextSeq, 16)
        XCTAssertEqual(page.entries, [
            PlayerLogEntry(
                date: Date(timeIntervalSince1970: 1_761_134_400.123),
                level: "error", source: "ffmpeg",
                text: "[mov,mp4 @ 0x1] moov atom not found", count: 1),
            PlayerLogEntry(
                date: Date(timeIntervalSince1970: 1_761_134_400.410),
                level: "warn", source: "erika",
                text: #"{"event":"video_decoder","stage":"open_avcodec_to_software"}"#, count: 2),
        ])
    }

    func testEmptyLogPage() throws {
        let page = try ErikaDiagnostics.logs(from: Data(#"{"schema":1,"nextSeq":0,"entries":[]}"#.utf8))
        XCTAssertEqual(page, ErikaDiagnostics.LogPage(nextSeq: 0, entries: []))
    }

    /// 格式不认识就抛错,不返回空页假装「内核什么都没说」
    func testMalformedLogPageThrows() {
        XCTAssertThrowsError(try ErikaDiagnostics.logs(from: Data(#"{"entries":[]}"#.utf8)))
        XCTAssertThrowsError(try ErikaDiagnostics.logs(from: Data(#"""
        {"nextSeq":2,"entries":[{"unixMs":1,"level":"warn","source":"erika","count":1}]}
        """#.utf8)))
    }
}
