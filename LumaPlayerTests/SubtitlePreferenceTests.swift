import XCTest
@testable import LumaPlayer

/// `SubtitlePreference` 的简繁判定与优先级。中文字幕标记千奇百怪(`chi` / `zho` / `zh-Hans` / `chs`,
/// 变体常写进 title),规则只能靠用例钉住。
final class SubtitlePreferenceTests: XCTestCase {

    // MARK: - 优先级

    /// 繁体轨故意排在前面
    func testSimplifiedWinsOverTraditional() {
        let tracks = [
            sub(1, lang: "chi", title: "繁體中文"),
            sub(2, lang: "chi", title: "简体中文"),
            sub(3, lang: "eng"),
        ]
        XCTAssertEqual(SubtitlePreference.preferredTrackID(in: tracks), 2)
    }

    func testTraditionalIsNextBest() {
        let tracks = [sub(1, lang: "eng"), sub(2, lang: "chi", title: "繁體")]
        XCTAssertEqual(SubtitlePreference.preferredTrackID(in: tracks), 2)
    }

    /// nil = 保持 mpv 的 default 轨
    func testNoChineseTrackReturnsNil() {
        let tracks = [sub(1, lang: "eng"), sub(2, lang: "jpn", title: "Japanese")]
        XCTAssertNil(SubtitlePreference.preferredTrackID(in: tracks))
    }

    /// 只标了中文的轨简繁未知,不能挤掉确定的繁体
    func testExplicitTraditionalBeatsUnspecifiedChinese() {
        let tracks = [
            sub(1, lang: "chi"),                       // 中文,未标变体
            sub(2, lang: "chi", title: "繁體字幕"),      // 明确繁体
        ]
        XCTAssertEqual(SubtitlePreference.preferredTrackID(in: tracks), 2)
    }

    func testUnspecifiedChineseIsStillChosen() {
        let tracks = [sub(1, lang: "eng", title: "English"), sub(2, lang: "chi", title: "中文")]
        XCTAssertEqual(SubtitlePreference.preferredTrackID(in: tracks), 2)
    }

    /// 同档内取 id 最小的那条(与 StreamIndexMapper 一样按轨道顺序)
    func testSameTierPicksLowestID() {
        let tracks = [
            sub(3, lang: "zh-Hans", title: "A"),
            sub(2, lang: "chs", title: "B"),
            sub(1, lang: "eng"),
        ]
        XCTAssertEqual(SubtitlePreference.preferredTrackID(in: tracks), 2)
    }

    /// 字幕烧进画面时没有字幕轨 → nil,不动音轨
    func testNoSubtitleTrackReturnsNil() {
        let tracks = [MPVTrack(id: 1, type: .audio, selected: true, title: "中文", lang: "chi",
                               codec: nil, isExternal: false, isForced: false)]
        XCTAssertNil(SubtitlePreference.preferredTrackID(in: tracks))
    }

    // MARK: - 语言码

    func testLanguageCodeVariants() {
        XCTAssertEqual(variant(lang: "zh-Hans"), .simplified)
        XCTAssertEqual(variant(lang: "zh-hans"), .simplified)
        XCTAssertEqual(variant(lang: "zhs"), .simplified)
        XCTAssertEqual(variant(lang: "chs"), .simplified)
        XCTAssertEqual(variant(lang: "zh-CN"), .simplified)
        XCTAssertEqual(variant(lang: "cmn-Hans"), .simplified)

        XCTAssertEqual(variant(lang: "zh-Hant"), .traditional)
        XCTAssertEqual(variant(lang: "zh-TW"), .traditional)
        XCTAssertEqual(variant(lang: "zh-HK"), .traditional)
        XCTAssertEqual(variant(lang: "cht"), .traditional)
        XCTAssertEqual(variant(lang: "zht"), .traditional)

        XCTAssertEqual(variant(lang: "chi"), .unspecified)
        XCTAssertEqual(variant(lang: "zho"), .unspecified)
        XCTAssertEqual(variant(lang: "zh"), .unspecified)

        XCTAssertNil(variant(lang: "eng"))
        XCTAssertNil(variant(lang: "jpn"))
    }

    // MARK: - title 线索

    /// 压制组把变体写在 title 里(语言码一律 `chi`)
    func testTitleCarriesTheVariant() {
        XCTAssertEqual(variant(lang: "chi", title: "简体中文"), .simplified)
        XCTAssertEqual(variant(lang: "chi", title: "简中"), .simplified)
        XCTAssertEqual(variant(lang: "chi", title: "中文字幕(Simplified)"), .simplified)

        XCTAssertEqual(variant(lang: "chi", title: "繁體中文"), .traditional)
        XCTAssertEqual(variant(lang: "chi", title: "正體"), .traditional)
        XCTAssertEqual(variant(lang: "chi", title: "Chinese (Traditional)"), .traditional)
        XCTAssertEqual(variant(lang: "chi", title: "BIG5"), .traditional)

        XCTAssertEqual(variant(lang: "chi", title: "中英字幕"), .unspecified)
        XCTAssertEqual(variant(lang: "chi", title: "Chinese"), .unspecified)
    }

    /// lang 与 title 冲突时以更明确的繁体线索为准(`zh-Hans` + 「繁體」实为繁体内容)
    func testTraditionalMarkerWinsWhenBothPresent() {
        XCTAssertEqual(variant(lang: "zh-Hans", title: "繁體"), .traditional)
    }

    func testTitleOnly() {
        XCTAssertEqual(variant(lang: nil, title: "简体"), .simplified)
        XCTAssertEqual(variant(lang: "und", title: "简体"), .simplified)
        XCTAssertEqual(variant(lang: nil, title: "中文"), .unspecified)
        XCTAssertNil(variant(lang: nil, title: nil))
        XCTAssertNil(variant(lang: nil, title: "English"))
    }

    // MARK: - 辅助

    private func variant(lang: String?, title: String? = nil) -> SubtitlePreference.ChineseVariant? {
        SubtitlePreference.chineseVariant(
            of: sub(1, lang: lang, title: title))
    }

    private func sub(
        _ id: Int, lang: String?, title: String? = nil, forced: Bool = false
    ) -> MPVTrack {
        MPVTrack(id: id, type: .sub, selected: false, title: title, lang: lang,
                 codec: nil, isExternal: false, isForced: forced)
    }

    // MARK: - 起播字幕模式

    /// 一条中文都没有时不动 mpv(⛔ 不猜)
    func testSmartModeLeavesAloneWithoutChinese() {
        let tracks = [sub(1, lang: "eng"), sub(2, lang: "jpn")]
        XCTAssertEqual(
            SubtitlePreference.startupChoice(in: tracks, mode: .smart), .leaveAlone)
        XCTAssertEqual(
            SubtitlePreference.startupChoice(in: [sub(1, lang: "chi")], mode: .smart),
            .track(id: 1))
    }

    func testAlwaysModeFallsBackToFirstTrack() {
        let tracks = [sub(3, lang: "eng"), sub(2, lang: "jpn", title: "日本語")]
        XCTAssertEqual(
            SubtitlePreference.startupChoice(in: tracks, mode: .always), .track(id: 2),
            "按 id 取第一条,不是数组里的第一个")
        XCTAssertEqual(
            SubtitlePreference.startupChoice(in: [sub(1, lang: "eng"), sub(2, lang: "chi")], mode: .always),
            .track(id: 2))
    }

    func testNoSubtitleTrackLeavesAlone() {
        let audio = [MPVTrack(id: 1, type: .audio, selected: true, title: nil, lang: "eng",
                              codec: nil, isExternal: false, isForced: false)]
        XCTAssertEqual(SubtitlePreference.startupChoice(in: audio, mode: .always), .leaveAlone)
    }

    func testForcedOnlyMode() {
        let tracks = [sub(1, lang: "chi"), sub(2, lang: "eng", forced: true)]
        XCTAssertEqual(
            SubtitlePreference.startupChoice(in: tracks, mode: .forcedOnly), .track(id: 2))
        XCTAssertEqual(
            SubtitlePreference.startupChoice(in: [sub(1, lang: "chi")], mode: .forcedOnly), .off)
    }

    func testNoneModeTurnsSubtitlesOff() {
        XCTAssertEqual(
            SubtitlePreference.startupChoice(in: [sub(1, lang: "chi")], mode: .none), .off)
    }
}
