import Foundation
import os

/// 字幕外观偏好(字号 / 颜色 / 粗体 / 描边 / 阴影或底框 / 垂直位置 / ASS 覆盖)。
///
/// 纯本地偏好:Emby 的 `UserConfiguration` 里没有外观字段,官方说明这部分由客户端自己存
/// (`FEATURE_GAP_ANALYSIS.md` P0-2),所以不经服务端、全部服务器共用一份。
///
/// 只描述「用户想要什么」;怎么翻译成 mpv 选项在 `mpvProperties`(纯函数,单测直接验),
/// 映射依据见 MPV_INTEGRATION.md 7.1。**默认值与 mpv 自身默认一致**:
/// 没改过设置时套用它等于什么都没改。
struct SubtitleStyle: Codable, Equatable, Sendable {

    /// 文字效果。阴影与底框在 mpv 里共用 `sub-back-color` / `sub-shadow-offset`
    /// 两个属性(7.1),所以是互斥的三选一,不是两个独立开关。
    enum Edge: String, Codable, CaseIterable, Sendable {
        /// 只有描边(mpv 默认)
        case outline
        /// 描边 + 右下投影
        case shadow
        /// 半透明底框(`background-box`,mpv 内置 `sub-box` profile 的做法)
        case box
    }

    /// 字号倍率(`sub-scale`)。对 ASS 字幕同样生效(`sub-ass-override` 默认就是 `scale`)。
    var scale: Double = 1
    var textColor: SubtitleColor = .white
    var isBold = false
    /// 描边粗细(`sub-outline-size`,scaled pixels;0 = 无描边)。底框模式下不用。
    var outlineSize: Double = 1.65
    var edge: Edge = .outline
    /// 底框不透明度(0–1),只在 `edge == .box` 时生效
    var boxOpacity: Double = 0.69
    /// 垂直位置(`sub-pos`,屏幕高度的百分比):100 = 原位(底部),越小越靠上。
    /// ⛔ 不开放 > 100:libass 会把文字字幕裁掉(mpv 手册 `--sub-pos` 的 Warning)。
    var position: Double = 100
    /// 对 ASS 特效字幕也强制套用颜色 / 描边 / 位置(`sub-ass-override=force`)。
    /// 默认关:force 很容易把特效字幕(招牌、歌词排版)渲染坏,mpv 手册原话「Can break rendering easily」。
    var overridesASS = false

    static let `default` = SubtitleStyle()

    // MARK: - 取值范围(UI 滑块与解码时的夹取共用)

    static let scaleRange: ClosedRange<Double> = 0.5...2.5
    static let outlineRange: ClosedRange<Double> = 0...5
    static let boxOpacityRange: ClosedRange<Double> = 0.2...1
    static let positionRange: ClosedRange<Double> = 50...100

    /// 阴影偏移(scaled pixels)。字号默认 38,2 是看得出又不发虚的量。
    static let shadowOffset = 2.0
    /// 阴影色:半透明黑
    static let shadowColor = "#80000000"
    /// mpv 自身的 `sub-back-color` 默认值(`mpv --list-options`,0.41.0)
    static let mpvDefaultBackColor = "#AF000000"
    /// 底框边距:取 mpv 内置 `sub-box` profile 的值(`mpv --show-profile=sub-box`)
    static let boxMargin = 4.0

    // MARK: - 映射到 mpv

    /// 对应的 mpv 属性,顺序固定。
    ///
    /// **每次都写全**而不是只写变了的:三种 `Edge` 之间来回切时,上一种留下的
    /// `sub-shadow-offset` / `sub-border-style` 必须被覆盖掉,否则「从底框切回描边」
    /// 会残留底框。
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
            // 阴影偏移为 0 时这个颜色画不出来;写回 mpv 默认值,只为「默认外观 = mpv 默认」严格成立
            backColor = Self.mpvDefaultBackColor
        case .shadow:
            borderStyle = "outline-and-shadow"
            outline = style.outlineSize
            offset = Self.shadowOffset
            backColor = Self.shadowColor
        case .box:
            // 与 `sub-box` profile 一致:底框自己就保证了对比度,不再叠描边
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

    /// 全部数值夹回合法范围、非有限值退回默认。
    /// 偏好是从 UserDefaults 读回来的,不能假设没被手改过。
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

    /// mpv 的 Float 选项接受普通十进制;固定 POSIX 格式,不受系统地区的小数点影响。
    private static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: - Codable

    /// 逐项 `decodeIfPresent`:以后加字段时,老版本存下的 JSON 缺键也能读,
    /// 只有缺的那一项取默认,而不是整份偏好被判坏、全部回到默认。
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

/// sRGB 颜色,分量 0–1。不直接存 SwiftUI `Color`:它不是 Codable,
/// 而且模型层不该依赖 UI 框架;与 `Color` 的互转在视图里做。
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

    /// 设置页的预设色:白(mpv 默认)、黄(电视 / 蓝光字幕的常见色)、浅灰、浅青
    static let presets: [Preset] = [
        Preset(name: "白色", color: .white),
        Preset(name: "黄色", color: SubtitleColor(red: 1, green: 0.9, blue: 0.3)),
        Preset(name: "浅灰", color: SubtitleColor(red: 0.85, green: 0.85, blue: 0.85)),
        Preset(name: "浅青", color: SubtitleColor(red: 0.6, green: 0.9, blue: 1)),
    ]

    /// mpv 颜色写法 `#AARRGGBB`(**alpha 在前**,mpv 手册 `--sub-color`)。
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

/// 字幕外观偏好的存取(UserDefaults,全 App 一份)。
///
/// 挂在 `AppContainer` 上:设置窗口改、播放窗口读,两边看到的是同一个实例;
/// `@Observable` 让播放窗口在播放中即时套用新外观(`PlayerWindowView` 的 onChange)。
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
            // 偏好损坏只影响外观,不值得挡住播放:按默认外观走,但记下来,
            // 免得以后排障时以为「设置没保存」。下次用户改设置就会覆盖掉坏数据。
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
