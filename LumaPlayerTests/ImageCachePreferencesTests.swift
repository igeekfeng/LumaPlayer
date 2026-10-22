import XCTest
@testable import LumaPlayer

/// 图片缓存上限档位(`ImageCachePreferences`):默认档等于 `PosterDiskCache` 的默认上限;改过的档位重开还在;
/// 脏值(字符串、表外数字)回默认档,⛔ 不能当 0 传进缓存层(等于关掉缓存)。
@MainActor
final class ImageCachePreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test.LumaPlayer.imageCache.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testDefaultsToDiskCacheDefaultLimit() {
        let store = ImageCachePreferences(defaults: defaults)

        XCTAssertEqual(store.byteLimitMB, 256)
        XCTAssertEqual(store.byteLimitBytes, PosterDiskCache.defaultByteLimit)
        XCTAssertTrue(store.isDefault)
    }

    func testChangedLimitSurvivesReopening() {
        ImageCachePreferences(defaults: defaults).byteLimitMB = 1024

        let reopened = ImageCachePreferences(defaults: defaults)
        XCTAssertEqual(reopened.byteLimitMB, 1024)
        XCTAssertEqual(reopened.byteLimitBytes, 1024 * 1024 * 1024)
        XCTAssertFalse(reopened.isDefault)
    }

    /// 表外存量值(如降级回旧版本)按默认档处理
    func testOutOfRangeValueFallsBackToDefault() {
        defaults.set(12, forKey: ImageCachePreferences.Key.byteLimitMB)

        XCTAssertEqual(ImageCachePreferences(defaults: defaults).byteLimitMB, 256)
    }

    /// 存成字符串时不能被 `integer(forKey:)` 解析成 0
    func testGarbageValueFallsBackToDefault() {
        defaults.set("big", forKey: ImageCachePreferences.Key.byteLimitMB)

        let store = ImageCachePreferences(defaults: defaults)
        XCTAssertEqual(store.byteLimitMB, 256)
        XCTAssertNotEqual(store.byteLimitBytes, 0)
    }

    /// 档位表必须含默认档,否则 Picker 选不中
    func testOptionListContainsDefaultAndIsAscending() {
        let options = ImageCachePreferences.byteLimitOptionsMB

        XCTAssertTrue(options.contains(ImageCachePreferences.defaultByteLimitMB))
        XCTAssertEqual(options, options.sorted())
        XCTAssertEqual(options, PosterDiskCache.byteLimitOptionsMB)
    }
}
