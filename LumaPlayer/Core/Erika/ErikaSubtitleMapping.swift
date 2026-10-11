import Erika

// 归一化类型 → Erika 类型的映射。**只有本目录 import Erika**,
// 所以内核类型转换全部收在这里,上层永远不碰 Erika 的类型。

extension PlayerUpscaler {
    /// 归一化超分档位 → Erika 档位
    var erikaValue: ErikaUpscaler {
        switch self {
        case .off: .off
        case .artCNN: .artCNNC4F16
        }
    }
}

extension ErikaSubtitleStyle {
    /// 归一化字幕样式 → Erika 字幕样式。
    ///
    /// 说明:
    /// - 字号倍率走引擎的 `setSubtitleScale`(不在本结构里),这里只映射外观;
    /// - 颜色按 `0xRRGGBBAA` 打包(Erika 的约定:`primaryColorRgba` 默认
    ///   `0xFFFFFFFF` 白、`outlineColorRgba` 默认 `0x0000007F` 半透明黑);
    /// - `overrides` 是「哪些字段强行覆盖内嵌 ASS」的位掩码:默认**不覆盖**
    ///   (`[]`),这样没改过设置时等于什么都不改,与旧内核 `sub-ass-override=scale`
    ///   的默认行为一致;用户显式勾了「对 ASS 也套用」才给 `.all`。
    init(_ style: PlayerSubtitleStyle) {
        self.init()
        primaryColorRgba = Self.rgba(style.textColor, alpha: 1)
        bold = style.isBold
        switch style.edge {
        case .outline:
            borderStyle = 1
            outlineWidth = style.outlineSize
            shadowDepth = 0
            outlineColorRgba = Self.defaultOutlineRgba
        case .shadow:
            borderStyle = 1
            outlineWidth = style.outlineSize
            shadowDepth = Self.shadowDepthValue
            outlineColorRgba = Self.shadowOutlineRgba
        case .box:
            // 3 = ASS 的不透明底框(用描边色画底)
            borderStyle = 3
            outlineWidth = 0
            shadowDepth = 0
            outlineColorRgba = Self.shadowOutlineRgba
        }
        overrides = style.overridesASS ? .all : []
    }

    /// Erika 的默认描边色(半透明黑)
    static let defaultOutlineRgba: UInt32 = 0x0000007F
    /// 阴影 / 底框用的描边色(更实的黑)
    static let shadowOutlineRgba: UInt32 = 0x80000000
    /// 阴影深度(与旧内核的 2px 偏移对齐)
    static let shadowDepthValue: Double = 2

    /// sRGB 分量(0–1)→ `0xRRGGBBAA`
    static func rgba(_ color: PlayerSubtitleStyle.Color, alpha: Double) -> UInt32 {
        func byte(_ value: Double) -> UInt32 {
            let clamped = value.isFinite ? min(max(value, 0), 1) : 1
            return UInt32((clamped * 255).rounded())
        }
        let a = alpha.isFinite ? min(max(alpha, 0), 1) : 1
        return (byte(color.red) << 24) | (byte(color.green) << 16)
            | (byte(color.blue) << 8) | byte(a)
    }
}
