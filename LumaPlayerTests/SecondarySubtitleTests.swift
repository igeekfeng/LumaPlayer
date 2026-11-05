import XCTest
@testable import LumaPlayer

/// 副字幕(`SecondarySubtitle`):可选轨过滤、位置 / 字号换算,以及 track-list 读回时主副字幕的区分。
final class SecondarySubtitleTests: XCTestCase {

    // MARK: - 位置

    /// 默认外观:主字幕在原位(100),副字幕上移两行(各 38 × 1.25 / 720 ≈ 6.6%)+ 1% 空隙
    func testDefaultPositionReservesTwoPrimaryLines() {
        let line = 38.0 * 1.25 / 720 * 100
        XCTAssertEqual(SecondarySubtitle.position(for: .default), 100 - 2 * line - 1, accuracy: 0.0001)
        XCTAssertEqual(SecondarySubtitle.position(for: .default), 85.81, accuracy: 0.01)
    }

    /// 主字幕放大,预留的高度按比例变大
    func testLargerPrimaryScaleMovesSecondaryHigher() {
        var style = SubtitleStyle.default
        style.scale = 2
        let line = 38.0 * 1.25 / 720 * 100 * 2
        XCTAssertEqual(SecondarySubtitle.position(for: style), 100 - 2 * line - 1, accuracy: 0.0001)
        XCTAssertLessThan(SecondarySubtitle.position(for: style), SecondarySubtitle.position(for: .default))
    }

    /// 主字幕上移多少,副字幕跟着上移多少(同一基准)
    func testPrimaryPositionShiftsSecondaryByTheSameAmount() {
        var style = SubtitleStyle.default
        style.position = 80
        XCTAssertEqual(SecondarySubtitle.position(for: style),
                       SecondarySubtitle.position(for: .default) - 20, accuracy: 0.0001)
    }

    /// 设置页允许的最极端组合(2.5 倍字号 + 位置 50)仍落在 mpv 的 0–150 内,不靠夹取
    func testMostExtremeAllowedStyleStaysInMPVRange() {
        var style = SubtitleStyle.default
        style.scale = SubtitleStyle.scaleRange.upperBound
        style.position = SubtitleStyle.positionRange.lowerBound
        let line = 38.0 * 1.25 / 720 * 100 * 2.5
        XCTAssertEqual(SecondarySubtitle.position(for: style), 50 - 2 * line - 1, accuracy: 0.0001)
        XCTAssertTrue(SecondarySubtitle.positionRange.contains(SecondarySubtitle.position(for: style)))
    }

    /// 非法值先夹回(UserDefaults 可能被手改),不把 NaN 传给 mpv
    func testInvalidStyleValuesAreClampedFirst() {
        var style = SubtitleStyle.default
        style.scale = .nan
        style.position = 500
        XCTAssertEqual(SecondarySubtitle.position(for: style), SecondarySubtitle.position(for: .default), accuracy: 0.0001)
        XCTAssertEqual(SecondarySubtitle.scale(for: style), 0.8, accuracy: 0.0001)
    }

    // MARK: - 字号与属性

    /// 副字幕的 scale 不乘 `sub-scale`(strip 完全覆盖),所以给的是绝对值
    func testScaleIsOneStepSmallerThanPrimary() {
        var style = SubtitleStyle.default
        style.scale = 1.5
        XCTAssertEqual(SecondarySubtitle.scale(for: style), 1.2, accuracy: 0.0001)
    }

    func testMPVPropertiesAreSecondaryPrefixedAndPOSIXFormatted() {
        let properties = SecondarySubtitle.mpvProperties(for: .default)
        XCTAssertEqual(properties.map(\.name),
                       ["secondary-sub-ass-override", "secondary-sub-scale", "secondary-sub-pos"])
        XCTAssertEqual(properties.map(\.value), ["strip", "0.800", "85.806"])
    }

    // MARK: - 可选轨

    /// 只要文本字幕;图形字幕、codec 不明、当前主字幕、非字幕轨都不给
    func testCandidatesExcludeBitmapUnknownAndPrimary() {
        let tracks = [
            sub(1, codec: "subrip"),
            sub(2, codec: "ass"),
            sub(3, codec: "hdmv_pgs_subtitle"),
            sub(4, codec: "dvd_subtitle"),
            sub(5, codec: nil),
            sub(6, codec: "webvtt"),
            MPVTrack(id: 7, type: .audio, selected: false, title: nil, lang: nil,
                     codec: "aac", isExternal: false, isForced: false),
        ]
        XCTAssertEqual(SecondarySubtitle.candidates(in: tracks, primaryID: 2).map(\.id), [1, 6])
        XCTAssertEqual(SecondarySubtitle.candidates(in: tracks, primaryID: nil).map(\.id), [1, 2, 6])
    }

    func testBitmapCodecMatchIsCaseInsensitive() {
        XCTAssertFalse(sub(1, codec: "HDMV_PGS_SUBTITLE").isTextSubtitle)
        XCTAssertTrue(sub(1, codec: "mov_text").isTextSubtitle)
    }

    // MARK: - 主副字幕读回

    /// 副字幕的 `selected` 也是 true,只能靠 `main-selection` 分
    func testMainSelectionSeparatesPrimaryAndSecondary() {
        var primary = sub(1, codec: "subrip", selected: true)
        primary.mainSelection = 0
        var secondary = sub(2, codec: "subrip", selected: true)
        secondary.mainSelection = 1
        XCTAssertTrue(primary.isPrimarySelection)
        XCTAssertFalse(primary.isSecondarySelection)
        XCTAssertTrue(secondary.isSecondarySelection)
        XCTAssertFalse(secondary.isPrimarySelection)
        // 没有该字段(旧数据 / 测试构造)按主轨算
        XCTAssertTrue(sub(3, codec: nil, selected: true).isPrimarySelection)
        XCTAssertFalse(sub(4, codec: nil).isPrimarySelection)
    }

    private func sub(_ id: Int, codec: String?, selected: Bool = false) -> MPVTrack {
        MPVTrack(id: id, type: .sub, selected: selected, title: nil, lang: nil,
                 codec: codec, isExternal: false, isForced: false)
    }
}
