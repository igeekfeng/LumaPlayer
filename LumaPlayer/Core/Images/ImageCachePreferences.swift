import Foundation

/// 图片磁盘缓存的上限档位(UserDefaults)。⛔ 不给「不限」:海报是派生数据,不该铺满磁盘。
///
/// 启动时组合根把 `byteLimitBytes` 传给 `PosterDiskCache`,设置页改档位时另调
/// `PosterImageStore.setDiskByteLimit(_:)`;运行中以 `PosterDiskCache` 的值为准,这里只管持久化。
@MainActor
@Observable
final class ImageCachePreferences {

    // MARK: - 偏好项

    /// 只允许 `byteLimitOptionsMB` 里的档位
    var byteLimitMB: Int {
        didSet { defaults.set(byteLimitMB, forKey: Key.byteLimitMB) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // ⛔ 不用 `integer(forKey:)`:没存过 / 类型不对都返回 0,会把缓存悄悄关掉
        let stored = defaults.object(forKey: Key.byteLimitMB) as? Int
        self.byteLimitMB = stored.flatMap {
            Self.byteLimitOptionsMB.contains($0) ? $0 : nil
        } ?? Self.defaultByteLimitMB
    }

    var byteLimitBytes: Int { byteLimitMB * 1024 * 1024 }

    var isDefault: Bool { byteLimitMB == Self.defaultByteLimitMB }

    static let defaultByteLimitMB = PosterDiskCache.defaultByteLimit / (1024 * 1024)

    /// 档位表只在 `PosterDiskCache` 定义一处
    static let byteLimitOptionsMB = PosterDiskCache.byteLimitOptionsMB

    enum Key {
        static let byteLimitMB = "images.byteLimitMB"
    }

    @ObservationIgnored private let defaults: UserDefaults
}
