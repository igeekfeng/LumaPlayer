import XCTest
@testable import LumaPlayer

/// 字幕外观偏好(2026-10-06,`FEATURE_GAP_ANALYSIS.md` P0-2)。
///
/// 两层分开验:
/// - `SubtitleStyle` → 内核中立样式(`engineStyle`)的映射、夹取:纯值,直接验;
/// - 持久化(UserDefaults 往返、缺键、坏值、老 JSON 向后兼容)。
///
/// ⛔ 字幕在画面上实际长什么样(字号、底框、位置)是渲染结果,这里验不到,
/// 见 `KNOWN_ISSUES.md`。
@MainActor
final class SubtitleStyleTests: XCTestCase {

    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUp() async throws {
        defaultsSuite = "test.LumaPlayer.subtitle.prefs.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults = nil
    }

    // MARK: - 外观 → 内核中立样式

    /// 默认外观必须等于内核默认:没改过设置的用户,套用之后画面不该有任何变化。
    func testDefaultStyleMapsToKernelDefaults() {
        let style = SubtitleStyle.default.engineStyle
        XCTAssertEqual(style.scale, 1)
        XCTAssertEqual(style.textColor, PlayerSubtitleStyle.Color.white)
        XCTAssertFalse(style.isBold)
        XCTAssertEqual(style.outlineSize, SubtitleStyle.default.outlineSize)
        XCTAssertEqual(style.edge, .outline)
        XCTAssertFalse(style.overridesASS)
    }

    func testEdgeMapsOneToOne() {
        for edge in SubtitleStyle.Edge.allCases {
            var style = SubtitleStyle.default
            style.edge = edge
            XCTAssertEqual(style.engineStyle.edge.rawValue, edge.rawValue, "\(edge)")
        }
    }

    func testTextColorMapsComponentwise() {
        var style = SubtitleStyle.default
        style.textColor = SubtitleColor(red: 1, green: 0.9, blue: 0.3)
        let color = style.engineStyle.textColor
        XCTAssertEqual(color.red, 1)
        XCTAssertEqual(color.green, 0.9)
        XCTAssertEqual(color.blue, 0.3)
    }

    func testOverrideASSFlagMaps() {
        var style = SubtitleStyle.default
        style.overridesASS = true
        XCTAssertTrue(style.engineStyle.overridesASS)
    }

    func testOutOfRangeValuesAreClampedBeforeMapping() {
        var style = SubtitleStyle.default
        style.scale = 10
        style.outlineSize = -1
        let clamped = style.clamped
        XCTAssertEqual(clamped.scale, SubtitleStyle.scaleRange.upperBound)
        XCTAssertEqual(clamped.outlineSize, 0)
        XCTAssertEqual(style.engineStyle.scale, SubtitleStyle.scaleRange.upperBound, "映射走的是夹取后的值")
    }

    func testNonFiniteValuesFallBackToDefault() {
        var style = SubtitleStyle.default
        style.scale = .nan
        style.outlineSize = .infinity
        style.textColor = SubtitleColor(red: .nan, green: 2, blue: -1)
        let clamped = style.clamped
        XCTAssertEqual(clamped.scale, SubtitleStyle.default.scale)
        XCTAssertEqual(clamped.outlineSize, SubtitleStyle.default.outlineSize)
        XCTAssertEqual(clamped.textColor, SubtitleColor(red: 1, green: 1, blue: 0))
    }

    // MARK: - 持久化

    func testStoreRoundTripsThroughUserDefaults() {
        let store = SubtitleStyleStore(defaults: defaults)
        XCTAssertEqual(store.style, .default, "没存过就是默认")
        store.style.scale = 1.4
        store.style.edge = .box
        store.style.textColor = SubtitleColor.presets[1].color

        let reloaded = SubtitleStyleStore(defaults: defaults)
        XCTAssertEqual(reloaded.style, store.style)

        reloaded.reset()
        XCTAssertEqual(SubtitleStyleStore(defaults: defaults).style, .default)
    }

    /// 以后加字段:老 JSON 缺键只让缺的那一项取默认,不是整份偏好作废。
    func testMissingKeysFallBackIndividually() throws {
        let style = try JSONDecoder().decode(
            SubtitleStyle.self, from: Data(#"{"scale":1.5,"edge":"shadow"}"#.utf8))
        XCTAssertEqual(style.scale, 1.5)
        XCTAssertEqual(style.edge, .shadow)
        XCTAssertEqual(style.textColor, .white)
        XCTAssertEqual(style.outlineSize, SubtitleStyle.default.outlineSize)
    }

    /// 换内核时删掉了 `boxOpacity` / `position` 两个键:老版本存下的 JSON
    /// 带这两个键也要能读进来(多出来的键被忽略),不整份判坏。
    func testLegacyJSONWithRemovedKeysStillDecodes() throws {
        let style = try JSONDecoder().decode(
            SubtitleStyle.self,
            from: Data(#"{"scale":1.2,"boxOpacity":0.4,"position":80,"edge":"box"}"#.utf8))
        XCTAssertEqual(style.scale, 1.2)
        XCTAssertEqual(style.edge, .box)
        XCTAssertEqual(style.outlineSize, SubtitleStyle.default.outlineSize)
    }

    /// 存坏了(手改 plist、类型不对):按默认外观走,不挡播放。
    func testCorruptedPreferenceFallsBackToDefault() {
        defaults.set(Data("not json".utf8), forKey: SubtitleStyleStore.defaultsKey)
        XCTAssertEqual(SubtitleStyleStore(defaults: defaults).style, .default)
    }

    /// 读回来的值也要夹:UserDefaults 里可能被手改成越界值。
    func testLoadedPreferenceIsClamped() {
        defaults.set(Data(#"{"scale":99}"#.utf8), forKey: SubtitleStyleStore.defaultsKey)
        XCTAssertEqual(SubtitleStyleStore(defaults: defaults).style.scale, SubtitleStyle.scaleRange.upperBound)
    }
}
