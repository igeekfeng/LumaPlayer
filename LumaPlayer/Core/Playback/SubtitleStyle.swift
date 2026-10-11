import Foundation
import os

/// 字幕外观偏好(字号 / 颜色 / 粗体 / 描边 / 边缘样式 / ASS 覆盖)。
///
/// 纯本地偏好:Emby 的 `UserConfiguration` 里没有外观字段,官方说明这部分由客户端自己存
/// (`FEATURE_GAP_ANALYSIS.md` P0-2),所以不经服务端、全部服务器共用一份。
///
/// 只描述「用户想要什么」;怎么翻译成内核选项在 `engineStyle`(纯函数,单测直接验),
/// 映射依据见 docs/ERIKA_INTEGRATION.md。**默认值与内核自身默认一致**:
/// 没改过设置时套用它等于什么都没改。
///
/// ⚠️ 随换内核(2026-10)**裁剪到能干净映射的子集**:去掉了 mpv 专有的
/// 「垂直位置」(`sub-pos`)与「底框不透明度」(`sub-back-color` 的 alpha)——
/// 当前内核(Erika)的字幕样式模型里没有对应字段。
struct SubtitleStyle: Codable, Equatable, Sendable {

    /// 文字效果。阴影与底框在内核里共用「边框样式 + 阴影深度」,所以是互斥的三选一,
    /// 不是两个独立开关。
    enum Edge: String, Codable, CaseIterable, Sendable {
        /// 只有描边(默认)
        case outline
        /// 描边 + 右下投影
        case shadow
        /// 半透明底框
        case box
    }

    /// 字号倍率。对 ASS 字幕同样生效(内核的 `overrides` 位掩码控制)。
    var scale: Double = 1
    var textColor: SubtitleColor = .white
    var isBold = false
    /// 描边粗细(0 = 无描边)。底框模式下不用。
    var outlineSize: Double = 1.65
    var edge: Edge = .outline
    /// 对 ASS 特效字幕也强制套用颜色 / 描边。
    /// 默认关:force 很容易把特效字幕(招牌、歌词排版)渲染坏。
    var overridesASS = false

    static let `default` = SubtitleStyle()

    // MARK: - 取值范围(UI 滑块与解码时的夹取共用)

    static let scaleRange: ClosedRange<Double> = 0.5...2.5
    static let outlineRange: ClosedRange<Double> = 0...5

    // MARK: - 映射到内核

    /// 内核中立的字幕样式(`PlaybackEngine.setSubtitleStyle` 直接吃它)。
    ///
    /// 每次都传全量而不是只传变了的:三种 `Edge` 之间来回切时,上一种留下的
    /// 阴影深度 / 边框样式必须被覆盖掉,否则「从底框切回描边」会残留底框。
    var engineStyle: PlayerSubtitleStyle {
        let style = clamped
        return PlayerSubtitleStyle(
            scale: style.scale,
            textColor: PlayerSubtitleStyle.Color(
                red: style.textColor.red,
                green: style.textColor.green,
                blue: style.textColor.blue),
            isBold: style.isBold,
            outlineSize: style.outlineSize,
            edge: PlayerSubtitleStyle.Edge(rawValue: style.edge.rawValue) ?? .outline,
            overridesASS: style.overridesASS
        )
    }

    /// 全部数值夹回合法范围、非有限值退回默认。
    /// 偏好是从 UserDefaults 读回来的,不能假设没被手改过。
    var clamped: SubtitleStyle {
        var copy = self
        copy.scale = Self.clamp(scale, Self.scaleRange, fallback: Self.default.scale)
        copy.outlineSize = Self.clamp(outlineSize, Self.outlineRange, fallback: Self.default.outlineSize)
        copy.textColor = textColor.clamped
        return copy
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Codable

    /// 逐项 `decodeIfPresent`:以后加字段时,老版本存下的 JSON 缺键也能读,
    /// 只有缺的那一项取默认,而不是整份偏好被判坏、全部回到默认。
    ///
    /// ⚠️ 老版本存下的 JSON 里可能还有 `boxOpacity` / `position` 两个键
    /// (换内核时删掉的字段)。`decodeIfPresent` 只读已知键,多出来的键被忽略,
    /// 所以老偏好能平滑读进来,只是这两项回不到 UI。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        textColor = try c.decodeIfPresent(SubtitleColor.self, forKey: .textColor) ?? d.textColor
        isBold = try c.decodeIfPresent(Bool.self, forKey: .isBold) ?? d.isBold
        outlineSize = try c.decodeIfPresent(Double.self, forKey: .outlineSize) ?? d.outlineSize
        edge = try c.decodeIfPresent(Edge.self, forKey: .edge) ?? d.edge
        overridesASS = try c.decodeIfPresent(Bool.self, forKey: .overridesASS) ?? d.overridesASS
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case scale, textColor, isBold, outlineSize, edge, overridesASS
    }
}

/// sRGB 颜色,分量 0–1。不直接存 SwiftUI `Color`:它不是 Codable,
/// 而且模型层不该依赖 UI 框架;与 `Color` 的互转在视图里做。
struct SubtitleColor: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let white = SubtitleColor(red: 1, green: 1, blue: 1)

    struct Preset: Hashable, Sendable {
        let name: String
        let color: SubtitleColor
    }

    /// 设置页的预设色:白(内核默认)、黄(电视 / 蓝光字幕的常见色)、浅灰、浅青
    static let presets: [Preset] = [
        Preset(name: "白色", color: .white),
        Preset(name: "黄色", color: SubtitleColor(red: 1, green: 0.9, blue: 0.3)),
        Preset(name: "浅灰", color: SubtitleColor(red: 0.85, green: 0.85, blue: 0.85)),
        Preset(name: "浅青", color: SubtitleColor(red: 0.6, green: 0.9, blue: 1)),
    ]

    var clamped: SubtitleColor {
        SubtitleColor(red: Self.unit(red), green: Self.unit(green), blue: Self.unit(blue))
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 1
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
