import XCTest
@testable import LumaPlayer

/// `PlaybackPreferences`:默认值、跨实例持久化、以及「UserDefaults 被手改过」时的夹取。
///
/// 每个用例都用一次性 suite —— 偏好存在 UserDefaults 里,共用 `.standard` 会让
/// 用例之间互相污染(前一个用例把默认倍速改成 2×,后一个用例的默认值断言就站不住)。
@MainActor
final class PlaybackPreferenceTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "test.LumaPlayer.preferences.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    // MARK: - 默认值

    func testDefaultsMatchShippedBehaviour() {
        let store = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(store.defaultSpeed, 1)
        XCTAssertEqual(store.seekStep, Metrics.seekStep)
        XCTAssertEqual(store.defaultVolume, Metrics.defaultVolume)
        XCTAssertEqual(store.subtitleMode, .smart)
        XCTAssertFalse(store.autoSkipIntro, "默认给按钮,不自动跳")
        XCTAssertTrue(store.autoPlayNext, "默认开,可在「下一集」提示上取消")
        XCTAssertFalse(store.floatsOnTop)
        XCTAssertTrue(store.isDefault)
    }

    // MARK: - 持久化

    /// 设置窗口改完关掉,下次启动还在 —— P0-4 要求的就是「改完留得住」
    func testValuesSurviveReopening() {
        let store = PlaybackPreferences(defaults: defaults)
        store.defaultSpeed = 1.5
        store.seekStep = 30
        store.defaultVolume = 40
        store.subtitleMode = .forcedOnly
        store.autoSkipIntro = true
        store.autoPlayNext = false
        store.floatsOnTop = true
        XCTAssertFalse(store.isDefault)

        let reopened = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(reopened.defaultSpeed, 1.5)
        XCTAssertEqual(reopened.seekStep, 30)
        XCTAssertEqual(reopened.defaultVolume, 40)
        XCTAssertEqual(reopened.subtitleMode, .forcedOnly)
        XCTAssertTrue(reopened.autoSkipIntro)
        XCTAssertFalse(reopened.autoPlayNext)
        XCTAssertTrue(reopened.floatsOnTop)
    }

    func testResetRestoresDefaults() {
        let store = PlaybackPreferences(defaults: defaults)
        store.defaultSpeed = 2
        store.seekStep = 5
        store.defaultVolume = 0
        store.subtitleMode = .none
        store.autoSkipIntro = true
        store.autoPlayNext = false
        store.floatsOnTop = true

        store.reset()
        XCTAssertTrue(store.isDefault)
        let reopened = PlaybackPreferences(defaults: defaults)
        XCTAssertTrue(reopened.isDefault, "恢复默认要真的写回 UserDefaults,不能只在内存里改")
    }

    // MARK: - 夹取(偏好可能被手改过)

    func testOutOfRangeValuesAreClampedOnLoad() {
        defaults.set(99.0, forKey: PlaybackPreferences.Key.defaultSpeed)
        defaults.set(140.0, forKey: PlaybackPreferences.Key.defaultVolume)

        let store = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(store.defaultSpeed, Metrics.speedRange.upperBound)
        XCTAssertEqual(store.defaultVolume, Metrics.volumeRange.upperBound)
    }

    /// 0 是合法值(静音起播),不能因为「读不到就用默认」那套判断被当成没存过
    func testZeroVolumeIsKept() {
        defaults.set(0.0, forKey: PlaybackPreferences.Key.defaultVolume)
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).defaultVolume, 0)
    }

    /// 步长只认设置页给的几档:手改成 7 秒,与其照用,不如退回默认
    func testUnknownSeekStepFallsBackToDefault() {
        defaults.set(7.0, forKey: PlaybackPreferences.Key.seekStep)
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).seekStep, Metrics.seekStep)

        defaults.set(15.0, forKey: PlaybackPreferences.Key.seekStep)
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).seekStep, 15)
    }

    /// 存了不认识的模式名(以后删档位 / 手改)→ 退回默认,不整份偏好判坏
    func testUnknownSubtitleModeFallsBackToDefault() {
        defaults.set("OnlyForced", forKey: PlaybackPreferences.Key.subtitleMode)
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).subtitleMode, .smart)
    }

    /// 非数字(比如被别的工具写成了字符串)→ 用默认,而不是读出 0 起播静音
    func testNonNumericValuesFallBackToDefaults() {
        defaults.set("fast", forKey: PlaybackPreferences.Key.defaultSpeed)
        defaults.set("loud", forKey: PlaybackPreferences.Key.defaultVolume)
        let store = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(store.defaultSpeed, PlaybackPreferences.defaultSpeed)
        XCTAssertEqual(store.defaultVolume, Metrics.defaultVolume)
    }

    // MARK: - 默认值与可选档位一致

    /// 设置页的 Picker 必须包含默认步长,否则一进设置页就显示成一个没选中的档
    func testDefaultSeekStepIsOneOfTheOptions() {
        XCTAssertTrue(Metrics.seekStepOptions.contains(Metrics.seekStep))
    }
}
