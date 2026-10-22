import CoreGraphics
import CoreText
import Foundation

/// 单条弹幕的预渲染:出场时画一次成位图,之后每帧只挪图层。
///
/// 用描边不用阴影:阴影是软边,移动中会糊。
/// 位图尺寸与摆放原点都对齐到屏幕像素(`aligned`),避免重采样导致文字时虚时实。
enum DanmakuSprite {

    struct Rendered {
        let image: CGImage
        /// pt(= 像素 / scale)
        let size: CGSize
        /// 文字行框相对位图左上角的内缩(pt),留给描边
        let margin: CGFloat
    }

    /// pt,文字外侧可见部分
    static func outlineWidth(fontSize: CGFloat) -> CGFloat {
        max(1, fontSize * 0.06)
    }

    static func aligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }

    /// 深色字(相对亮度 < 0.15)配白边,其余配黑边
    static func usesLightOutline(_ rgb: UInt32) -> Bool {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.15
    }

    /// ⛔ 必须与 `DanmakuController.measure` 一致,否则排版宽度与实际对不上。
    static func font(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    /// 文字在 `lineHeight` 行框里垂直居中。位图上下文建不出来时返回 nil,调用方跳过这一条。
    static func render(
        text: String, color rgb: UInt32, fontSize: CGFloat, lineHeight: CGFloat, scale: CGFloat
    ) -> Rendered? {
        let font = font(size: fontSize)
        let outline = outlineWidth(fontSize: fontSize)
        let margin = outline.rounded(.up) + 1

        let fillColor = CGColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
        let strokeColor = usesLightOutline(rgb)
            ? CGColor(gray: 1, alpha: 0.9)
            : CGColor(gray: 0, alpha: 0.9)

        let fillLine = line(text, attributes: [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: fillColor,
        ])
        // 正值 = 只描不填,单位是字号的百分比;线居中于字形轮廓,外侧可见一半,所以取两倍
        let strokeLine = line(text, attributes: [
            kCTFontAttributeName: font,
            kCTStrokeColorAttributeName: strokeColor,
            kCTStrokeWidthAttributeName: (outline * 2 / fontSize * 100) as CFNumber,
        ])

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(fillLine, &ascent, &descent, nil))

        let width = textWidth + margin * 2
        let height = max(lineHeight, ascent + descent) + margin * 2
        let pixelWidth = Int((width * scale).rounded(.up))
        let pixelHeight = Int((height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        // 透明底上做字体平滑会出彩边
        context.setAllowsFontSmoothing(false)
        context.setLineJoin(.round)
        let boxHeight = height - margin * 2
        // CG 坐标原点在左下:基线 = 下边距 + 行框内垂直居中后的下伸部
        let baseline = margin + (boxHeight - (ascent + descent)) / 2 + descent
        context.textPosition = CGPoint(x: margin, y: baseline)
        CTLineDraw(strokeLine, context)
        context.textPosition = CGPoint(x: margin, y: baseline)
        CTLineDraw(fillLine, context)

        guard let image = context.makeImage() else { return nil }
        return Rendered(
            image: image,
            size: CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale),
            margin: margin)
    }

    private static func line(_ text: String, attributes: [CFString: Any]) -> CTLine {
        let keyed = Dictionary(uniqueKeysWithValues: attributes.map { (NSAttributedString.Key($0.key as String), $0.value) })
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: keyed))
    }
}
