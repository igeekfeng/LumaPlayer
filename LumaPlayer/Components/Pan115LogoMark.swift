import SwiftUI

/// 115 网盘官方字标(白色「115 云」复合路径)。
///
/// 几何逐点照官方 `icon_logo_cloud_darkblue.svg` 的 viewBox 36×36;本类型只画字标,
/// 需要连着深蓝底一起画时用 `Pan115LogoMark`。
///
/// 官方路径是 `fill-rule="evenodd"`,数字 5 的内孔靠奇偶规则留空 ——
/// ⛔ 填充必须带 `FillStyle(eoFill: true)`,换默认的非零规则会把孔填实。
struct Pan115Glyph: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / Pan115Geometry.canvasSize
        return Pan115Geometry.glyphPath().applying(
            CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        )
    }
}

/// 115 网盘品牌标记:官方深蓝圆角底 + 白色字标。
///
/// 尺寸自由,底与字标按 36 画布等比缩放;`size` 取列表行首图标边长时与其它来源的图标块同高。
struct Pan115LogoMark: View {
    var size: CGFloat = Metrics.serverRowIconSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Pan115Geometry.cornerRadius * size / Pan115Geometry.canvasSize)
                .fill(Pan115Geometry.background)
            Pan115Glyph()
                .fill(.white, style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 官方几何的唯一出处:底与字标都从这里取坐标,视图与单测共用。
enum Pan115Geometry {
    /// 官方 SVG 的 viewBox 边长
    static let canvasSize: CGFloat = 36
    /// 官方 `<rect rx="4">`
    static let cornerRadius: CGFloat = 4
    /// 官方 `<rect fill="#224888">`
    static let background = Color(.sRGB, red: 0x22 / 255, green: 0x48 / 255, blue: 0x88 / 255)

    /// 字标在 36 画布上的紧包围盒(官方几何换算后应为 x 9.83–26.53、y 6.33–29.79)。
    static var glyphBounds: CGRect {
        glyphPath().boundingRect
    }

    static func glyphPath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 25.87490, y: 6.33325))
        path.addCurve(to: CGPoint(x: 25.79580, y: 6.34453), control1: CGPoint(x: 25.84720, y: 6.33325), control2: CGPoint(x: 25.82110, y: 6.33776))
        path.addCurve(to: CGPoint(x: 25.73970, y: 6.36558), control1: CGPoint(x: 25.77730, y: 6.35129), control2: CGPoint(x: 25.75890, y: 6.35881))
        path.addCurve(to: CGPoint(x: 23.52860, y: 6.78808), control1: CGPoint(x: 25.19440, y: 6.56856), control2: CGPoint(x: 24.40410, y: 6.78808))
        path.addCurve(to: CGPoint(x: 15.14800, y: 6.78808), control1: CGPoint(x: 23.52860, y: 6.78808), control2: CGPoint(x: 16.63800, y: 6.78808))
        path.addCurve(to: CGPoint(x: 13.86010, y: 7.43235), control1: CGPoint(x: 14.61200, y: 6.78808), control2: CGPoint(x: 14.14040, y: 7.04368))
        path.addCurve(to: CGPoint(x: 9.83337, y: 15.28770), control1: CGPoint(x: 13.85780, y: 7.43686), control2: CGPoint(x: 9.83337, y: 15.28770))
        path.addCurve(to: CGPoint(x: 11.97460, y: 15.53350), control1: CGPoint(x: 9.83337, y: 15.28770), control2: CGPoint(x: 11.91780, y: 15.52520))
        path.addCurve(to: CGPoint(x: 17.56190, y: 17.24760), control1: CGPoint(x: 13.83090, y: 15.81320), control2: CGPoint(x: 16.03350, y: 16.34390))
        path.addCurve(to: CGPoint(x: 20.99180, y: 22.46110), control1: CGPoint(x: 19.75840, y: 18.54660), control2: CGPoint(x: 21.13080, y: 20.43430))
        path.addCurve(to: CGPoint(x: 13.99290, y: 28.58130), control1: CGPoint(x: 20.72230, y: 26.38920), control2: CGPoint(x: 16.95520, y: 28.15660))
        path.addCurve(to: CGPoint(x: 10.53230, y: 28.58130), control1: CGPoint(x: 11.91320, y: 28.86400), control2: CGPoint(x: 10.53230, y: 28.58130))
        path.addCurve(to: CGPoint(x: 14.67570, y: 29.66010), control1: CGPoint(x: 10.53230, y: 28.58130), control2: CGPoint(x: 12.22960, y: 29.58650))
        path.addCurve(to: CGPoint(x: 23.81810, y: 25.52090), control1: CGPoint(x: 18.85220, y: 29.78640), control2: CGPoint(x: 22.10010, y: 28.04230))
        path.addCurve(to: CGPoint(x: 17.90370, y: 13.32480), control1: CGPoint(x: 26.53080, y: 21.54250), control2: CGPoint(x: 25.01470, y: 15.21020))
        path.addCurve(to: CGPoint(x: 14.64570, y: 12.62110), control1: CGPoint(x: 16.53970, y: 12.96320), control2: CGPoint(x: 14.64570, y: 12.62110))
        path.addLine(to: CGPoint(x: 15.65880, y: 10.66950))
        path.addCurve(to: CGPoint(x: 17.11180, y: 9.72677), control1: CGPoint(x: 15.88380, y: 10.11770), control2: CGPoint(x: 16.44900, y: 9.72677))
        path.addCurve(to: CGPoint(x: 17.20400, y: 9.72978), control1: CGPoint(x: 17.14260, y: 9.72677), control2: CGPoint(x: 17.17330, y: 9.72828))
        path.addLine(to: CGPoint(x: 20.58480, y: 9.72978))
        path.addCurve(to: CGPoint(x: 20.58790, y: 9.72978), control1: CGPoint(x: 20.58560, y: 9.72978), control2: CGPoint(x: 20.58710, y: 9.72978))
        path.addCurve(to: CGPoint(x: 20.59250, y: 9.72978), control1: CGPoint(x: 20.58860, y: 9.72978), control2: CGPoint(x: 20.59020, y: 9.72978))
        path.addLine(to: CGPoint(x: 23.59620, y: 9.72978))
        path.addCurve(to: CGPoint(x: 24.96090, y: 8.96522), control1: CGPoint(x: 24.18450, y: 9.72978), control2: CGPoint(x: 24.69600, y: 9.42080))
        path.addLine(to: CGPoint(x: 24.98930, y: 8.91110))
        path.addLine(to: CGPoint(x: 26.10760, y: 6.77379))
        path.addCurve(to: CGPoint(x: 26.15440, y: 6.68433), control1: CGPoint(x: 26.12910, y: 6.74748), control2: CGPoint(x: 26.14440, y: 6.71741))
        path.addCurve(to: CGPoint(x: 26.16670, y: 6.60915), control1: CGPoint(x: 26.16210, y: 6.66028), control2: CGPoint(x: 26.16670, y: 6.63547))
        path.addCurve(to: CGPoint(x: 25.87490, y: 6.33325), control1: CGPoint(x: 26.16670, y: 6.45730), control2: CGPoint(x: 26.03610, y: 6.33325))
        path.closeSubpath()
        return path
    }
}
