import Foundation
import XCTest
@testable import LumaPlayer

/// 起播后的「静默删轨」守卫(`TrackExpectation`)。
///
/// 这条守卫对应的是 P3 本机实测到的一条反直觉性质:
/// **AVFoundation 遇到不认识的编码不报错,而是把那一条轨悄悄删掉** ——
/// `playable` 仍为 true、`play()` 成功、`errorLog` 为空。
/// 表现是「有声音没画面」或反过来,而且骗过所有计数指标。
/// 所以判定只能发生在客户端,依据是服务端给的 `MediaStreams`。
///
/// XCTest 验的是**判定逻辑**;真机行为由
/// `Scripts/verify-avkit-playback.sh` 里的负例(H.264 + DTS 的 MP4)佐证。
final class TrackExpectationTests: XCTestCase {

    // MARK: - 期望的推导

    /// 一条 H.264 + AAC 的 MP4:视频与音频都必须出现
    func testVideoAndAudioRequired() {
        let requirement = TrackExpectation.requirement(forStreams: [
            stream(type: "Video", codec: "h264"),
            stream(type: "Audio", codec: "aac"),
        ])
        XCTAssertEqual(requirement, TrackExpectation.Requirement(video: true, audio: true))
    }

    /// 只有音轨的源(音乐):不因为「没有视频」而判失败
    func testAudioOnlySourceDoesNotRequireVideo() {
        let requirement = TrackExpectation.requirement(forStreams: [
            stream(type: "Audio", codec: "flac")
        ])
        XCTAssertEqual(requirement, TrackExpectation.Requirement(video: false, audio: true))
    }

    /// 字幕轨不参与判定:源里只有位图字幕时不该要求任何维度
    func testSubtitleStreamsDoNotCreateRequirement() {
        let requirement = TrackExpectation.requirement(forStreams: [
            stream(type: "Video", codec: "h264"),
            stream(type: "Subtitle", codec: "hdmv_pgs_subtitle"),
        ])
        XCTAssertEqual(requirement, TrackExpectation.Requirement(video: true, audio: false))
    }

    /// 服务端没给 `MediaStreams` → `nil`(这次无法核实),不是「不用核实」
    func testMissingStreamsIsNilNotNone() {
        XCTAssertNil(TrackExpectation.requirement(forStreams: nil))
        XCTAssertNotEqual(
            TrackExpectation.requirement(forStreams: nil),
            TrackExpectation.Requirement.none,
            "「判不了」与「不用判」必须区分开"
        )
    }

    /// 空数组是「核实过:什么轨都没有」,与 nil 不同
    func testEmptyStreamsIsVerifiedEmpty() {
        XCTAssertEqual(
            TrackExpectation.requirement(forStreams: []),
            TrackExpectation.Requirement.none
        )
    }

    // MARK: - 核验

    func testSatisfiedWhenAllRequiredTracksPresent() {
        XCTAssertEqual(
            TrackExpectation.evaluate(
                requirement: TrackExpectation.Requirement(video: true, audio: true),
                presented: TrackExpectation.Presented(video: true, audio: true)
            ),
            .satisfied
        )
    }

    /// 音频轨被静默删掉:必须报出缺的是「音频」(H.264 + DTS 的 MP4 就是这一形态)
    func testMissingAudioIsReported() {
        XCTAssertEqual(
            TrackExpectation.evaluate(
                requirement: TrackExpectation.Requirement(video: true, audio: true),
                presented: TrackExpectation.Presented(video: true, audio: false)
            ),
            .missing(["音频"])
        )
    }

    /// 视频轨被静默删掉(TS + HEVC 那一形态):「有声音没画面」
    func testMissingVideoIsReported() {
        XCTAssertEqual(
            TrackExpectation.evaluate(
                requirement: TrackExpectation.Requirement(video: true, audio: true),
                presented: TrackExpectation.Presented(video: false, audio: true)
            ),
            .missing(["视频"])
        )
    }

    /// 两条都没了时按固定顺序列出(视频在前),文案要稳定
    func testBothMissingListsVideoFirst() {
        XCTAssertEqual(
            TrackExpectation.evaluate(
                requirement: TrackExpectation.Requirement(video: true, audio: true),
                presented: TrackExpectation.Presented.none
            ),
            .missing(["视频", "音频"])
        )
    }

    /// 不要求的维度缺席不算失败
    func testUnrequiredDimensionMayBeAbsent() {
        XCTAssertEqual(
            TrackExpectation.evaluate(
                requirement: TrackExpectation.Requirement(video: false, audio: true),
                presented: TrackExpectation.Presented(video: false, audio: true)
            ),
            .satisfied
        )
    }

    /// nil 口径 → unverifiable(⛔ 不得当成 satisfied)
    func testNilRequirementIsUnverifiable() {
        XCTAssertEqual(
            TrackExpectation.evaluate(
                requirement: nil,
                presented: TrackExpectation.Presented(video: true, audio: true)
            ),
            .unverifiable
        )
    }

    // MARK: - 辅助

    private func stream(type: String, codec: String?) -> EmbyMediaStream {
        EmbyMediaStream(
            index: nil, type: type, codec: codec, language: nil,
            isDefault: nil, isTextSubtitleStream: nil, isExternal: nil,
            displayTitle: nil, title: nil, width: nil, height: nil, channels: nil
        )
    }
}
