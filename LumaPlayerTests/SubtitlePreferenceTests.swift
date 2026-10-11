import XCTest
@testable import LumaPlayer

/// `SubtitlePreference` 的简繁判定与优先级。
///
/// 纯函数,不需要内核、不需要网络 —— 中文资源的字幕标记千奇百怪
/// (语言码有 `chi` / `zho` / `zh-Hans` / `chs`,变体常写进 title),
/// 判定规则只能靠这类用例钉住。
final class SubtitlePreferenceTests: XCTestCase {

    // MARK: - 优先级

    /// 有简体时,简体最优先(哪怕繁体轨排在前面)
    func testSimplifiedWinsOverTraditional() {
        let tracks = [
            sub(1, lang: "chi", title: "繁體中文"),
            sub(2, lang: "chi", title: "简体中文"),
            sub(3, lang: "eng"),
        ]
        XCTAssertEqual(SubtitlePreference.preferredTrackID(in: tracks), 2)
    }

    /// 没有简体时选繁体
    func testTraditionalIsNextBest() {
        let tracks = [sub(1, lang: "eng"), sub(2, lang: "chi", title: "繁體")]
        XCTAssertEqual(SubtitlePreference.preferredTrackID(in: tracks), 2)
    }

    /// 一条中文都没有 → nil(= 保持内核的默认轨)
    func testNoChineseTrackReturnsNil() {
        let tracks = [sub(1, lang: "eng"), sub(2, lang: "jpn", title: "Japanese")]
        XCTAssertNil(SubtitlePreference.preferredTrackID(in: tracks))
    }

    /// 明确繁体优先于「只标了中文」的轨:后者简繁未知,不能挤掉确定的繁体
    func testExplicitTraditionalBeatsUnspecifiedChinese() {
        let tracks = [
            sub(1, lang: "chi"),                       // 中文,未标变体
            sub(2, lang: "chi", title: "繁體字幕"),      // 明确繁体
        ]
        XCTAssertEqual(SubtitlePreference.preferredTrackID(in: tracks), 2)
    }

    /// 只有未标变体的中文轨(最常见的 `chi`)时也该选它 —— 用户要的是中文字幕
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

    /// 没有字幕轨(例如字幕被烧进画面)→ nil,不去动音轨
    func testNoSubtitleTrackReturnsNil() {
        let tracks = [PlayerTrack(id: 1, kind: .audio, source: .embedded, selected: true,
                                  title: "中文", language: "chi", codec: nil)]
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

    /// 压制组把变体写在 title 里(语言码一律 `chi`)—— 这是判定简繁的主战场
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

    /// lang 与 title 冲突时以 title 为准?不 —— 以更明确的繁体线索为准:
    /// `zh-Hans` + 「繁體」这种自相矛盾的标记,按繁体处理(它确实是繁体内容)
    func testTraditionalMarkerWinsWhenBothPresent() {
        XCTAssertEqual(variant(lang: "zh-Hans", title: "繁體"), .traditional)
    }

    /// lang 缺失(und / nil)时靠 title 判定
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
        _ id: Int64, lang: String?, title: String? = nil
    ) -> PlayerTrack {
        PlayerTrack(id: id, kind: .subtitle, source: .embedded, selected: false,
                    title: title, language: lang, codec: nil)
    }

    // MARK: - 起播字幕模式

    /// 默认模式:有中文选中文;一条中文都没有时不动内核(⛔ 不猜)
    func testSmartModeLeavesAloneWithoutChinese() {
        let tracks = [sub(1, lang: "eng"), sub(2, lang: "jpn")]
        XCTAssertEqual(
            SubtitlePreference.startupChoice(in: tracks, mode: .smart), .leaveAlone)
        XCTAssertEqual(
            SubtitlePreference.startupChoice(in: [sub(1, lang: "chi")], mode: .smart),
            .track(id: 1))
    }

    /// 「总是开」:没有中文字幕时开第一条轨,而不是不动
    func testAlwaysModeFallsBackToFirstTrack() {
        let tracks = [sub(3, lang: "eng"), sub(2, lang: "jpn", title: "日本語")]
        XCTAssertEqual(
            SubtitlePreference.startupChoice(in: tracks, mode: .always), .track(id: 2),
            "按 id 取第一条,不是数组里的第一个")
        // 有中文时仍然优先中文
        XCTAssertEqual(
            SubtitlePreference.startupChoice(in: [sub(1, lang: "eng"), sub(2, lang: "chi")], mode: .always),
            .track(id: 2))
    }

    /// 一条字幕轨都没有时两种模式都不该凭空造一条出来
    func testNoSubtitleTrackLeavesAlone() {
        let audio = [PlayerTrack(id: 1, kind: .audio, source: .embedded, selected: true,
                                 title: nil, language: "eng", codec: nil)]
        XCTAssertEqual(SubtitlePreference.startupChoice(in: audio, mode: .always), .leaveAlone)
    }

    func testNoneModeTurnsSubtitlesOff() {
        XCTAssertEqual(
            SubtitlePreference.startupChoice(in: [sub(1, lang: "chi")], mode: .none), .off)
    }
}
