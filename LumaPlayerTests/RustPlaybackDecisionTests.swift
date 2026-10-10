import XCTest
@testable import LumaPlayer

/// P2 门禁：**播放决策**真的能从 Rust 过边界调到 Swift 这边。
///
/// 为什么单独一个文件：`RustCoreBridgeTests` 证明的是「边界通不通」，
/// 这里证明的是「决策语义过边界后没走样」—— 尤其是逐维度判定的结论、
/// 以及那条新增的静默失败守卫。
///
/// 数据与 Rust 侧 [`playback_fixtures.rs`] 用的是**同一批**真实响应
/// (`LumaPlayerTests/Fixtures/Playback/`)，两边断言不一致就是边界翻译错了。
///
/// 详见 `docs/DECISIONS/avkit-rust-rearchitecture.md` 第 8 节 P2。
final class RustPlaybackDecisionTests: XCTestCase {

    /// 期望的决策结果（逐维度）。
    private struct Expected {
        let method: String
        let pathActions: [String]
        let subtitleAction: String?
    }

    /// 四类真实片源 + 一条反面样本。
    /// 名字必须与 `LumaPlayerTests/Fixtures/Playback/` 下的文件一致。
    private let fourSourceClasses: [(file: String, expected: Expected)] = [
        (
            "playback_mp4_h264_aac.json",
            Expected(method: "DirectStream", pathActions: [], subtitleAction: "转换字幕为文本")
        ),
        (
            "playback_mkv_h264_aac.json",
            Expected(method: "Transcode", pathActions: ["重封装容器"], subtitleAction: "转换字幕为文本")
        ),
        (
            "playback_mkv_h264_dts.json",
            Expected(method: "Transcode", pathActions: ["重封装容器", "转码音频"], subtitleAction: nil)
        ),
        (
            "playback_mkv_hevc_pgs.json",
            Expected(method: "Transcode", pathActions: ["重封装容器"], subtitleAction: "烧录字幕")
        ),
    ]

    /// `DeviceProfile` 由 Rust 派生，Swift 只负责把它塞进请求体。
    /// 守住两条：白名单里不能有 MKV；两份白名单只有 Rust 那一份。
    func testDeviceProfileComesFromRustAndExcludesMKV() throws {
        let json = avkitDeviceProfileJson()

        XCTAssertTrue(json.contains("DirectPlayProfiles"), "实际：\(json)")
        XCTAssertTrue(json.contains("\"mp4\""), "mp4 必须在直放白名单里：\(json)")
        XCTAssertFalse(json.contains("mkv"), "MKV 不是 AVKit 原生支持，不该出现在声明里：\(json)")
        XCTAssertFalse(
            json.contains("hdmv_pgs_subtitle"),
            "位图字幕不该被声明：声明了等于要求服务端给原样位图轨"
        )
    }

    /// P2 的核心断言：四类片源的决策结果，与 Rust 侧逐条对齐。
    func testFourSourceClassesDecideIdenticallyThroughTheBoundary() throws {
        for (file, expected) in fourSourceClasses {
            let decision = try decidePlayback(playbackInfoJson: try FixtureLoader.json(file))

            XCTAssertEqual(decision.method, expected.method, "\(file) 的播放方式不对")
            XCTAssertEqual(
                decision.audit.pathActions, expected.pathActions,
                "\(file) 需要的服务端动作不对"
            )
            XCTAssertEqual(
                decision.audit.subtitleAction, expected.subtitleAction,
                "\(file) 的字幕处理不对"
            )
            XCTAssertTrue(
                decision.audit.unverifiableDimensions.isEmpty,
                "\(file) 的响应里 MediaStreams 齐全，不该出现「判不了」的维度：\(decision.audit.unverifiableDimensions)"
            )
            XCTAssertFalse(
                decision.capabilityRevision.isEmpty,
                "\(file) 的判定必须带上能力表版本号（P3 实测回填时要能对上）"
            )
        }
    }

    /// 同一条 MP4：DirectStream 且带直连地址；同一条 MKV：转码且带转码地址。
    /// 地址由服务端给，⛔ 客户端不自己拼。
    func testUrlsComeFromTheServerOnly() throws {
        let direct = try decidePlayback(
            playbackInfoJson: try FixtureLoader.json("playback_mp4_h264_aac.json"))
        XCTAssertNotNil(direct.directStreamUrl, "DirectStream 应带上服务端给的直连地址")
        XCTAssertNil(direct.transcodingUrl, "能直连时不该要转码地址")

        let transcode = try decidePlayback(
            playbackInfoJson: try FixtureLoader.json("playback_mkv_h264_dts.json"))
        XCTAssertNotNil(transcode.transcodingUrl, "转码必须用服务端给的地址")
        XCTAssertEqual(transcode.transcodingSubProtocol, "http")
    }

    /// ⭐ 静默失败守卫过边界后仍然是「报错」而不是「假装能放」。
    ///
    /// 这条 fixture 是旧 profile 下同一条 MKV 的真实响应：服务端说可以直连、
    /// 不给转码地址，而容器是 MKV。照旧算法这里会安静地走到 DirectStream。
    func testUnplayableDirectStreamIsRefusedThroughTheBoundary() throws {
        let json = try FixtureLoader.json("playback_mkv_direct_stream_silent_failure.json")

        do {
            let decision = try decidePlayback(playbackInfoJson: json)
            XCTFail("应被拒绝，实际给出 \(decision.method)（这就会黑屏）")
        } catch let failure as PlaybackFailureFfi {
            guard case let .UnplayableDirectStream(pathActions, notes, message) = failure else {
                return XCTFail("错误类型不对：\(failure)")
            }
            XCTAssertEqual(pathActions, ["重封装容器"])
            XCTAssertFalse(notes.isEmpty, "必须带上可读理由")
            XCTAssertTrue(message.contains("转码地址"), "文案要点明缺的是什么：\(message)")
        }
    }

    /// 能力表版本号要能过边界 —— P3 实测回填后靠它判断「这份结论是哪一版表得出的」。
    func testCapabilityRevisionCrossesTheBoundary() {
        let info = coreInfo()
        XCTAssertTrue(
            info.capabilityRevision.contains("avkit-capability"),
            "实际：\(info.capabilityRevision)"
        )
    }
}
