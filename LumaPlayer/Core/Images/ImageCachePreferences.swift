import Foundation

/// 图片磁盘缓存的上限档位(全 App 一份、存 UserDefaults)。
///
/// ## 为什么上限要可调
///
/// `PosterDiskCache.defaultByteLimit`(256 MB)是拍出来的中位数:一个库几百张
/// 海报大约就是这个量级。但「够不够用」跟库有多大、屏幕是几 K、macOS 的
/// `~/Library/Caches` 还剩多少空间都有关 —— 自用播放器上,与其猜一个值,
/// 不如把档位摆出来让用户自己定。
///
/// ⛔ 不给「不限」:海报是纯派生数据,铺满磁盘时受害的是整个 App。
///
/// ## 谁读它
///
/// 组合根建 `PosterDiskCache` 时把 `byteLimitBytes` 传进去(启动即生效),
/// 设置页改档位时调 `PosterImageStore.setDiskByteLimit(_:)`(立即生效)。
/// `PosterDiskCache` 自己也有一份当前值 —— 它才是权威,这里是持久化的来源。
@MainActor
@Observable
final class ImageCachePreferences {

    // MARK: - 偏好项

    /// 磁盘缓存上限(MB)。只允许 `byteLimitOptionsMB` 里的档位。
    var byteLimitMB: Int {
        didSet { defaults.set(byteLimitMB, forKey: Key.byteLimitMB) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // ⛔ 不用 `integer(forKey:)` 判「有没有存过」:没存过它返回 0,
        // 存成字符串也返回 0,两种都会把上限悄悄压成 0(缓存等于关掉)。
        let stored = defaults.object(forKey: Key.byteLimitMB) as? Int
        self.byteLimitMB = stored.flatMap {
            Self.byteLimitOptionsMB.contains($0) ? $0 : nil
        } ?? Self.defaultByteLimitMB
    }

    /// 换成字节给 `PosterDiskCache`。
    var byteLimitBytes: Int { byteLimitMB * 1024 * 1024 }

    /// 是否还是默认档(设置页「恢复默认」按钮用)
    var isDefault: Bool { byteLimitMB == Self.defaultByteLimitMB }

    /// 默认档:与 `PosterDiskCache` 的默认值同一个数,不另立常量。
    static let defaultByteLimitMB = PosterDiskCache.defaultByteLimit / (1024 * 1024)

    /// 可选档位(MB)。与 `PosterDiskCache.byteLimitOptionsMB` 同一份 ——
    /// 缓存层按字节校验、设置页按 MB 展示,档位表只能有一处。
    static let byteLimitOptionsMB = PosterDiskCache.byteLimitOptionsMB

    /// UserDefaults key
    enum Key {
        static let byteLimitMB = "images.byteLimitMB"
    }

    @ObservationIgnored private let defaults: UserDefaults
}
