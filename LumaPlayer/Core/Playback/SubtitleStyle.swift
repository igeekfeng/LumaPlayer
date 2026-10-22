import Foundation
import os

/// 字幕外观偏好。纯本地(Emby `UserConfiguration` 没有外观字段),所有服务器共用。
///
/// 映射到 mpv 在 `mpvProperties`(MPV_INTEGRATION.md 7.1)。默认值与 mpv 自身默认一致,没改过等于没改。
struct SubtitleStyle: Codable, Equatable, Sendable {

    /// 阴影与底框共用 `sub-back-color` / `sub-shadow-offset`(7.1),所以三选一。
    enum Edge: String, Codable, CaseIterable, Sendable {
        /// 只有描边(mpv 默认)
        case outline
        /// 描边 + 右下投影
        case shadow
        /// 半透明底框(同 mpv 内置 `sub-box` profile)
        case box
    }

    /// `sub-scale`,对 ASS 同样生效
    var scale: Double = 1
    var textColor: SubtitleColor = .white
    var isBold = false
    /// `sub-outline-size`(scaled pixels,0 = 无);底框模式不用
    var outlineSize: Double = 1.65
    var edge: Edge = .outline
    /// 0–1,只在 `.box` 时生效
    var boxOpacity: Double = 0.69
    /// `sub-pos`,屏幕高度百分比,100 = 底部。⛔ 不开放 > 100:libass 会裁掉文字字幕
    var position: Double = 100
    /// `sub-ass-override=force`。默认关:force 容易把特效字幕渲染坏
    var overridesASS = false

    static let `default` = SubtitleStyle()

    // MARK: - 取值范围(UI 滑块与解码时的夹取共用)

    static let scaleRange: ClosedRange<Double> = 0.5...2.5
    static let outlineRange: ClosedRange<Double> = 0...5
    static let boxOpacityRange: ClosedRange<Double> = 0.2...1
    static let positionRange: ClosedRange<Double> = 50...100

    /// scaled pixels
    static let shadowOffset = 2.0
    static let shadowColor = "#80000000"
    /// mpv 自身的 `sub-back-color` 默认值(0.41.0)
    static let mpvDefaultBackColor = "#AF000000"
    /// mpv 内置 `sub-box` profile 的值
    static let boxMargin = 4.0

    // MARK: - 映射到 mpv

    /// 顺序固定。每次写全:切换 `Edge` 时上一种的残留属性必须被覆盖。
    var mpvProperties: [(name: String, value: String)] {
        let style = clamped
        let backColor: String
        let offset: Double
        let outline: Double
        let borderStyle: String
        switch style.edge {
        case .outline:
            borderStyle = "outline-and-shadow"
            outline = style.outlineSize
            offset = 0
            // 偏移为 0 时画不出来;写回 mpv 默认,让默认外观严格等于 mpv 默认
            backColor = Self.mpvDefaultBackColor
        case .shadow:
            borderStyle = "outline-and-shadow"
            outline = style.outlineSize
            offset = Self.shadowOffset
            backColor = Self.shadowColor
        case .box:
            // 同 `sub-box` profile:底框保证对比度,不叠描边
            borderStyle = "background-box"
            outline = 0
            offset = Self.boxMargin
            backColor = SubtitleColor.black.mpvHex(alpha: style.boxOpacity)
        }
        return [
            ("sub-ass-override", style.overridesASS ? "force" : "scale"),
            ("sub-scale", Self.number(style.scale)),
            ("sub-color", style.textColor.mpvHex(alpha: 1)),
            ("sub-bold", style.isBold ? "yes" : "no"),
            ("sub-border-style", borderStyle),
            ("sub-outline-size", Self.number(outline)),
            ("sub-shadow-offset", Self.number(offset)),
            ("sub-back-color", backColor),
            ("sub-pos", Self.number(style.position)),
        ]
    }

    /// 夹回合法范围、非有限值退回默认(UserDefaults 可能被手改)。
    var clamped: SubtitleStyle {
        var copy = self
        copy.scale = Self.clamp(scale, Self.scaleRange, fallback: Self.default.scale)
        copy.outlineSize = Self.clamp(outlineSize, Self.outlineRange, fallback: Self.default.outlineSize)
        copy.boxOpacity = Self.clamp(boxOpacity, Self.boxOpacityRange, fallback: Self.default.boxOpacity)
        copy.position = Self.clamp(position, Self.positionRange, fallback: Self.default.position)
        copy.textColor = textColor.clamped
        return copy
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// 固定 POSIX 格式,不受系统地区的小数点影响。
    private static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: - Codable

    /// 逐项 `decodeIfPresent`:加字段后旧 JSON 缺键只让那一项取默认。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        textColor = try c.decodeIfPresent(SubtitleColor.self, forKey: .textColor) ?? d.textColor
        isBold = try c.decodeIfPresent(Bool.self, forKey: .isBold) ?? d.isBold
        outlineSize = try c.decodeIfPresent(Double.self, forKey: .outlineSize) ?? d.outlineSize
        edge = try c.decodeIfPresent(Edge.self, forKey: .edge) ?? d.edge
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? d.boxOpacity
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? d.position
        overridesASS = try c.decodeIfPresent(Bool.self, forKey: .overridesASS) ?? d.overridesASS
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case scale, textColor, isBold, outlineSize, edge, boxOpacity, position, overridesASS
    }
}

/// sRGB,分量 0–1。不存 SwiftUI `Color`(非 Codable、模型层不依赖 UI),互转在视图里做。
struct SubtitleColor: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let white = SubtitleColor(red: 1, green: 1, blue: 1)
    static let black = SubtitleColor(red: 0, green: 0, blue: 0)

    struct Preset: Hashable, Sendable {
        let name: String
        let color: SubtitleColor
    }

    static let presets: [Preset] = [
        Preset(name: "白色", color: .white),
        Preset(name: "黄色", color: SubtitleColor(red: 1, green: 0.9, blue: 0.3)),
        Preset(name: "浅灰", color: SubtitleColor(red: 0.85, green: 0.85, blue: 0.85)),
        Preset(name: "浅青", color: SubtitleColor(red: 0.6, green: 0.9, blue: 1)),
    ]

    /// `#AARRGGBB`,alpha 在前(mpv `--sub-color`)。
    func mpvHex(alpha: Double) -> String {
        let c = clamped
        let a = min(max(alpha.isFinite ? alpha : 1, 0), 1)
        return String(format: "#%02X%02X%02X%02X",
                      Self.byte(a), Self.byte(c.red), Self.byte(c.green), Self.byte(c.blue))
    }

    var clamped: SubtitleColor {
        SubtitleColor(red: Self.unit(red), green: Self.unit(green), blue: Self.unit(blue))
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 1
    }

    private static func byte(_ value: Double) -> Int {
        Int((value * 255).rounded())
    }
}

/// 字幕外观偏好的存取(UserDefaults,全 App 一份,挂在 `AppContainer`)。
/// 播放中改动经 `PlayerWindowView` 的 onChange 即时套用。
@MainActor
@Observable
final class SubtitleStyleStore {
    var style: SubtitleStyle {
        didSet {
            guard style != oldValue else { return }
            persist()
        }
    }

    static let defaultsKey = "player.subtitleStyle"

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.style = Self.load(from: defaults)
    }

    func reset() {
        style = .default
    }

    private static func load(from defaults: UserDefaults) -> SubtitleStyle {
        guard let data = defaults.data(forKey: defaultsKey) else { return .default }
        do {
            return try JSONDecoder().decode(SubtitleStyle.self, from: data).clamped
        } catch {
            // 只影响外观,不挡播放;记日志,下次改设置会覆盖坏数据
            logger.error("字幕外观偏好解码失败,使用默认外观: \(String(describing: error), privacy: .public)")
            return .default
        }
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(style), forKey: Self.defaultsKey)
        } catch {
            Self.logger.error("字幕外观偏好保存失败: \(String(describing: error), privacy: .public)")
        }
    }

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "playback")
}
