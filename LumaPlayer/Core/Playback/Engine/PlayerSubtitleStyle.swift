import Foundation

/// 内核中立的字幕外观(**播放引擎只认这个**)。
///
/// App 的字幕偏好模型是 `SubtitleStyle`(Codable、落 UserDefaults);它经
/// `SubtitleStyle.engineStyle` 转成本类型后再交给引擎,引擎适配器再翻成内核自己的
/// 字幕样式结构。这样上层偏好怎么演进都只影响一次映射,不渗进引擎接口。
///
/// 只保留当前内核能干净映射的字段:字号倍率 / 文字色 / 粗体 / 描边粗细 /
/// 边缘样式 / ASS 覆盖。mpv 专有的「垂直位置」「底框不透明度」已随换内核去掉。
struct PlayerSubtitleStyle: Sendable, Equatable {

    /// 文字效果。阴影与底框在内核里共用「边框样式 + 阴影深度」,
    /// 所以是互斥的三选一,不是两个独立开关。
    enum Edge: String, Sendable, Equatable {
        /// 只有描边(默认)
        case outline
        /// 描边 + 右下投影
        case shadow
        /// 不透明底框
        case box
    }

    /// sRGB 颜色,分量 0–1。
    struct Color: Sendable, Equatable {
        var red: Double
        var green: Double
        var blue: Double

        static let white = Color(red: 1, green: 1, blue: 1)
    }

    /// 字号倍率(1 = 内核默认字号)
    var scale: Double = 1
    var textColor: Color = .white
    var isBold = false
    /// 描边粗细;底框模式下不用
    var outlineSize: Double = 1.65
    var edge: Edge = .outline
    /// 对 ASS 特效字幕也强制套用颜色 / 描边(默认关:容易把特效字幕渲染坏)
    var overridesASS = false

    static let `default` = PlayerSubtitleStyle()
}
