import Foundation

/// 画面适配:填充 / 缩放 / 旋转 / 宽高比覆盖(MPV_INTEGRATION.md 7.4)。
///
/// 都是针对**这一部片、这一集源**的临时修正(4:3 老剧的黑边、非方形像素的宽高比、
/// 手机竖拍的视频),所以默认值与 mpv 一致,没动过等于没设;不持久化、不进设置页。
/// 跨集沿用交给 `PlayerViewModel.PageCarryOver`:同一部剧各集通常是同一种压制。
struct PictureSettings: Equatable, Sendable {

    /// `panscan`:放不下时裁边填满窗口,还是留黑边
    enum Fit: String, CaseIterable, Identifiable, Sendable {
        /// mpv 默认:按片源比例完整显示,放不下就留黑边
        case automatic
        /// 放大到填满窗口,超出部分裁掉
        case fill

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .automatic: "适应窗口"
            case .fill: "填满窗口(裁边)"
            }
        }
    }

    /// `video-aspect-override`:片源自带的 SAR 不对时才需要
    enum Aspect: String, CaseIterable, Identifiable, Sendable {
        /// `no`:不覆盖,用容器的 SAR
        case automatic
        case widescreen
        case standard

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .automatic: "自动(按片源)"
            case .widescreen: "16:9"
            case .standard: "4:3"
            }
        }

        /// mpv 收 `no` / `16:9` 这类比值字符串
        var mpvValue: String {
            switch self {
            case .automatic: "no"
            case .widescreen: "16:9"
            case .standard: "4:3"
            }
        }
    }

    var fit: Fit = .automatic
    /// mpv `video-zoom`:log2 倍率,0 = 不缩放,1 = 放大一倍
    var zoom: Double = 0
    /// 顺时针角度,只能是 `rotations` 里的值
    var rotation: Int = 0
    var aspect: Aspect = .automatic

    static let `default` = PictureSettings()

    /// ±1 对应 50%–200%:再放大会糊成一片,而且没有「放大到像素级」的需求
    static let zoomRange: ClosedRange<Double> = -1...1
    /// 滚轮 / 按钮一档约 7%
    static let zoomStep: Double = 0.1
    static let rotations: [Int] = [0, 90, 180, 270]

    /// 实际缩放倍数,给屏显与菜单文案(2^zoom)
    var zoomPercent: Int {
        Int((pow(2, zoom) * 100).rounded())
    }

    /// 夹回合法范围;非有限值退回默认(UserDefaults / 手写值都可能越界)。
    var clamped: PictureSettings {
        var copy = self
        copy.zoom = zoom.isFinite
            ? min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
            : Self.default.zoom
        if !Self.rotations.contains(rotation) { copy.rotation = Self.default.rotation }
        return copy
    }

    /// 顺序固定;每次写全,切回「自动」时上一项的值必须被覆盖。
    var mpvProperties: [(name: String, value: String)] {
        let settings = clamped
        return [
            ("panscan", settings.fit == .fill ? "1.000" : "0.000"),
            ("video-zoom", Self.number(settings.zoom)),
            // 0 与 `no` 等价(mpv 默认 `no`),显式写 0 才能把设置过的角度收回去
            ("video-rotate", String(settings.rotation)),
            ("video-aspect-override", settings.aspect.mpvValue),
        ]
    }

    /// 固定 POSIX 格式,不受系统地区的小数点影响。
    private static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
