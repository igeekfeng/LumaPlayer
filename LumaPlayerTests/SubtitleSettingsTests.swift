import XCTest
@testable import LumaPlayer

/// 字幕延迟与字幕外观(2026-10-06)。
///
/// 三层分开验:
/// - `SubtitleStyle` → mpv 属性的映射、夹取、持久化:纯值,直接验;
/// - 真实 libmpv 是否接受这些属性名与取值:建一个空闲的 `MPVPlayer` 设进去再读回
///   (不播放媒体,和 `MPVPlayerLifecycleTests` 一样只走 idle → shutdown);
/// - `PlayerViewModel` 的字幕延迟:夹取 / 文案 / 读回事件 / 没有会话时不响应。
///   有会话时的步进要真实播放(会话来自网络),不在这里假覆盖。
///
/// ⛔ 字幕在画面上实际长什么样(字号、底框、位置)是渲染结果,这里验不到,
/// 见 `KNOWN_ISSUES.md` Q40。
@MainActor
final class SubtitleSettingsTests: XCTestCase {

    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUp() async throws {
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        defaultsSuite = "test.LumaPlayer.subtitle.prefs.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        defaults.removePersistentDomain(forName: defaultsSuite)
        storage = nil
        credentials = nil
        defaults = nil
    }

    // MARK: - 外观 → mpv 属性

    /// 默认外观必须等于 mpv 自己的默认值(`mpv --list-options`,0.41.0):
    /// 没改过设置的用户,套用之后画面不该有任何变化。
    func testDefaultStyleMatchesMPVDefaults() {
        XCTAssertEqual(properties(SubtitleStyle.default), [
            "sub-ass-override": "scale",
            "sub-scale": "1.000",
            "sub-color": "#FFFFFFFF",
            "sub-bold": "no",
            "sub-border-style": "outline-and-shadow",
            "sub-outline-size": "1.650",
            "sub-shadow-offset": "0.000",
            "sub-back-color": "#AF000000",
            "sub-pos": "100.000",
        ])
    }

    /// 底框照 mpv 内置 `sub-box` profile:background-box + 无描边 + 边距 4,
    /// 不透明度进 `sub-back-color` 的 alpha(alpha 在前)。
    func testBoxEdgeFollowsSubBoxProfile() {
        var style = SubtitleStyle.default
        style.edge = .box
        style.boxOpacity = 0.5
        style.outlineSize = 3 // 底框模式下不该生效
        let p = properties(style)
        XCTAssertEqual(p["sub-border-style"], "background-box")
        XCTAssertEqual(p["sub-outline-size"], "0.000")
        XCTAssertEqual(p["sub-shadow-offset"], "4.000")
        XCTAssertEqual(p["sub-back-color"], "#80000000")
    }

    func testShadowEdgeKeepsOutlineAndAddsOffset() {
        var style = SubtitleStyle.default
        style.edge = .shadow
        style.outlineSize = 2.5
        let p = properties(style)
        XCTAssertEqual(p["sub-border-style"], "outline-and-shadow")
        XCTAssertEqual(p["sub-outline-size"], "2.500")
        XCTAssertEqual(p["sub-shadow-offset"], "2.000")
    }

    /// 从底框切回描边:上一种留下的边框样式与偏移必须被覆盖(所以每次都写全)。
    func testSwitchingBackFromBoxResetsEverySharedProperty() {
        var style = SubtitleStyle.default
        style.edge = .box
        let boxNames = Set(style.mpvProperties.map(\.name))
        style.edge = .outline
        XCTAssertEqual(Set(style.mpvProperties.map(\.name)), boxNames, "三种效果写的是同一组属性")
        XCTAssertEqual(properties(style), properties(.default))
    }

    /// `MPVPlayer.setSubtitleProperties` 只放行 `sub-*`,映射不能产出别的名字。
    func testAllPropertiesAreSubtitleOptions() {
        for edge in SubtitleStyle.Edge.allCases {
            var style = SubtitleStyle.default
            style.edge = edge
            for (name, _) in style.mpvProperties {
                XCTAssertTrue(name.hasPrefix("sub-"), name)
            }
        }
    }

    func testColorHexPutsAlphaFirst() {
        let yellow = SubtitleColor(red: 1, green: 0.9, blue: 0.3)
        XCTAssertEqual(yellow.mpvHex(alpha: 1), "#FFFFE64D")
        XCTAssertEqual(SubtitleColor.black.mpvHex(alpha: 0), "#00000000")
        XCTAssertEqual(SubtitleColor(red: 2, green: -1, blue: .nan).mpvHex(alpha: 9), "#FFFF00FF",
                       "越界分量夹到 0–1,非有限值按 1")
    }

    func testOutOfRangeValuesAreClamped() {
        var style = SubtitleStyle.default
        style.scale = 10
        style.position = 140 // > 100 会被 libass 裁掉,不开放
        style.outlineSize = -1
        style.boxOpacity = .nan
        let clamped = style.clamped
        XCTAssertEqual(clamped.scale, SubtitleStyle.scaleRange.upperBound)
        XCTAssertEqual(clamped.position, 100)
        XCTAssertEqual(clamped.outlineSize, 0)
        XCTAssertEqual(clamped.boxOpacity, SubtitleStyle.default.boxOpacity)
        XCTAssertEqual(properties(style)["sub-scale"], "2.500", "映射走的是夹取后的值")
    }

    func testOverrideASSUsesForce() {
        var style = SubtitleStyle.default
        style.overridesASS = true
        XCTAssertEqual(properties(style)["sub-ass-override"], "force")
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
        XCTAssertEqual(style.position, 100)
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

    // MARK: - 真实 libmpv 读回

    /// 属性名与取值写法要真被 libmpv 接受:设进去再读回,三种效果各走一遍。
    /// 名字拼错 / 颜色写法不对时 `setSubtitleProperties` 会抛错。
    func testLibmpvAcceptsEveryStyleProperty() throws {
        let player = MPVPlayer()
        defer { player.shutdown() }
        try XCTSkipIf(player.initializationFailure != nil, "libmpv 初始化失败:\(player.initializationFailure ?? "")")

        for edge in SubtitleStyle.Edge.allCases {
            var style = SubtitleStyle.default
            style.edge = edge
            style.scale = 1.25
            style.isBold = true
            style.position = 80
            style.textColor = SubtitleColor.presets[1].color
            try player.setSubtitleProperties(style.mpvProperties)

            let names = style.mpvProperties.map(\.name)
            let read = player.stringProperties(names)
            XCTAssertEqual(Set(read.keys), Set(names), "每一项都读得回来(\(edge))")
            XCTAssertEqual(read["sub-border-style"], properties(style)["sub-border-style"])
            XCTAssertEqual(read["sub-bold"], "yes")
            XCTAssertEqual(read["sub-scale"].flatMap(Double.init), 1.25)
            XCTAssertEqual(read["sub-pos"].flatMap(Double.init), 80)
            XCTAssertEqual(read["sub-color"]?.uppercased(), "#FFFFE64D")
        }
    }

    func testSetSubtitlePropertiesRejectsNonSubtitleNames() {
        let player = MPVPlayer()
        defer { player.shutdown() }
        XCTAssertThrowsError(try player.setSubtitleProperties([("speed", "2")]))
    }

    func testLibmpvSubtitleDelayReadsBack() throws {
        let player = MPVPlayer()
        defer { player.shutdown() }
        try XCTSkipIf(player.initializationFailure != nil, "libmpv 初始化失败")
        try player.setSubtitleDelay(-1.3)
        XCTAssertEqual(player.stringProperties(["sub-delay"])["sub-delay"].flatMap(Double.init), -1.3)
    }

    // MARK: - 字幕延迟(ViewModel)

    func testSubtitleDelayIsClampedAndRounded() {
        XCTAssertEqual(PlayerViewModel.clampedSubtitleDelay(0.1 + 0.1 + 0.1), 0.3)
        XCTAssertEqual(PlayerViewModel.clampedSubtitleDelay(500), Metrics.subtitleDelayRange.upperBound)
        XCTAssertEqual(PlayerViewModel.clampedSubtitleDelay(-500), Metrics.subtitleDelayRange.lowerBound)
        XCTAssertEqual(PlayerViewModel.clampedSubtitleDelay(.nan), 0)
        XCTAssertEqual(PlayerViewModel.clampedSubtitleDelay(-0.001).sign, .plus, "-0 统一成 0")
    }

    func testSubtitleDelayTextSaysLaterOrEarlier() {
        XCTAssertEqual(PlayerViewModel.subtitleDelayText(0.3), "字幕延后 0.3 秒")
        XCTAssertEqual(PlayerViewModel.subtitleDelayText(-1.5), "字幕提前 1.5 秒")
        XCTAssertEqual(PlayerViewModel.subtitleDelayText(0), "字幕无延迟")
        XCTAssertEqual(PlayerViewModel.subtitleDelayValueText(2), "+2 秒")
        XCTAssertEqual(PlayerViewModel.subtitleDelayValueText(-0.25), "-0.25 秒")
        XCTAssertEqual(PlayerViewModel.subtitleDelayValueText(0), "0 秒")
        XCTAssertEqual(PlayerViewModel.subtitleDelayValueText(-0.25, unit: "s"), "-0.25 s")
        XCTAssertEqual(PlayerViewModel.subtitleDelayValueText(0, unit: "s"), "0 s")
    }

    /// `sub-delay` 读回事件驱动 `subtitleDelay`,与其他事件一样受代次门约束。
    func testSubtitleDelayFollowsReadBackAndGenerationGate() throws {
        let viewModel = try makeViewModel()
        viewModel.handle(.subtitleDelay(0.5), generation: 0)
        XCTAssertEqual(viewModel.subtitleDelay, 0.5)

        viewModel.stop()
        viewModel.handle(.subtitleDelay(9), generation: 0)
        XCTAssertEqual(viewModel.subtitleDelay, 0.5, "上一轮播放器的迟到事件丢弃")
    }

    /// 没有会话 / 没选字幕时 Z / X 不响应:调了看不出效果,不该留下看不见的状态。
    func testSubtitleDelayIgnoredWithoutSessionOrSubtitle() throws {
        let viewModel = try makeViewModel()
        XCTAssertFalse(viewModel.canAdjustSubtitleDelay)
        viewModel.stepSubtitleDelay(later: true)
        viewModel.resetSubtitleDelay()
        XCTAssertNil(viewModel.osd, "不响应就不该有屏显")
    }

    // MARK: - 辅助

    private func properties(_ style: SubtitleStyle) -> [String: String] {
        Dictionary(uniqueKeysWithValues: style.mpvProperties.map { ($0.name, $0.value) })
    }

    private func makeViewModel() throws -> PlayerViewModel {
        let registry = try ServerRegistry(
            defaults: UserDefaults(suiteName: "test.LumaPlayer.subtitle.registry.\(UUID().uuidString)")!,
            credentials: credentials
        )
        let container = AppContainer(registry: registry, credentials: credentials, preferences: defaults)
        let item = try JSONDecoder().decode(
            EmbyItem.self, from: Data(#"{"Id":"ITEM-1","Name":"测试影片","Type":"Movie"}"#.utf8))
        return PlayerViewModel(
            container: container,
            server: ServerProfile(displayName: "emby.test", baseURL: testURL("https://emby.test"), deviceID: "DEVICE-UUID-1"),
            item: item,
            displaySleep: RecordingDisplaySleepInhibitor()
        )
    }
}
