import SwiftUI

/// TMDB 官方字标(「TMDB」+ 胶囊),只用作详情页「在 TMDB 上打开」的入口。
///
/// 几何逐点照官方 `blue_short.svg` 的 viewBox 273.42×35.52 转写,原文件的 `A` 弧段已展开成三次贝塞尔
/// (`Arc` 在 SwiftUI `Path` 里也能画,但半径写成 `17.67` 时两端点几乎重合,展开成曲线更稳)。
/// 官方 logo 本身就是一条从左到右的渐变(浅绿 → 青 → 蓝),⛔ 再套 tint 会把官方配色盖掉。
struct TMDBLogoMark: View {
    /// 字标高度;宽度按官方比例推出来
    var height: CGFloat = Metrics.detailSecondaryMarkHeight

    var body: some View {
        TMDBWordmarkGlyph()
            .fill(TMDBGeometry.gradient)
            .frame(width: height / TMDBGeometry.aspect, height: height)
            .accessibilityHidden(true)
    }
}

struct TMDBWordmarkGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        TMDBGeometry.wordmarkPath().applying(TMDBGeometry.fitTransform(for: rect))
    }
}

/// 官方几何的唯一出处:path 坐标与渐变端点都从这里取,视图与单测共用。
enum TMDBGeometry {
    static let canvasWidth: CGFloat = 273.42
    static let canvasHeight: CGFloat = 35.52
    static var aspect: CGFloat { canvasHeight / canvasWidth }

    /// 把 273.42×35.52 画布等比缩放填进 `rect`(两者的宽高比由调用处的 frame 保证一致)
    static func fitTransform(for rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / canvasWidth, rect.height / canvasHeight)
        return CGAffineTransform(scaleX: scale, y: scale)
    }

    /// 官方 `linearGradient#linear-gradient`:`y1` / `y2` 都是 17.76(横向),
    /// 三个色标 0 / 0.56 / 1 分别对到 #90CEA1 / #3CBEC9 / #00B3E5。
    static var gradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color(.sRGB, red: 0x90 / 255, green: 0xCE / 255, blue: 0xA1 / 255), location: 0),
                .init(color: Color(.sRGB, red: 0x3C / 255, green: 0xBE / 255, blue: 0xC9 / 255), location: 0.56),
                .init(color: Color(.sRGB, red: 0x00 / 255, green: 0xB3 / 255, blue: 0xE5 / 255), location: 1)
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// 官方 path(单条复合路径,靠子路径闭合区分字母与胶囊)
    static func wordmarkPath() -> Path {
        var path = Path()
    path.move(to: CGPoint(x: 191.85, y: 35.37))
    path.addLine(to: CGPoint(x: 255.75, y: 35.37))
    path.addCurve(to: CGPoint(x: 268.245, y: 30.195), control1: CGPoint(x: 260.436, y: 35.37), control2: CGPoint(x: 264.931, y: 33.508))
    path.addCurve(to: CGPoint(x: 273.42, y: 17.7), control1: CGPoint(x: 271.558, y: 26.881), control2: CGPoint(x: 273.42, y: 22.386))
    path.addLine(to: CGPoint(x: 273.42, y: 17.7))
    path.addCurve(to: CGPoint(x: 268.255, y: 5.186), control1: CGPoint(x: 273.428, y: 13.008), control2: CGPoint(x: 271.57, y: 8.506))
    path.addCurve(to: CGPoint(x: 255.75, y: 0), control1: CGPoint(x: 264.941, y: 1.866), control2: CGPoint(x: 260.442, y: -0))
    path.addLine(to: CGPoint(x: 191.85, y: 0))
    path.addCurve(to: CGPoint(x: 179.345, y: 5.186), control1: CGPoint(x: 187.158, y: -0), control2: CGPoint(x: 182.659, y: 1.866))
    path.addCurve(to: CGPoint(x: 174.18, y: 17.7), control1: CGPoint(x: 176.03, y: 8.506), control2: CGPoint(x: 174.172, y: 13.008))
    path.addLine(to: CGPoint(x: 174.18, y: 17.7))
    path.addCurve(to: CGPoint(x: 191.85, y: 35.37), control1: CGPoint(x: 174.18, y: 27.459), control2: CGPoint(x: 182.091, y: 35.37))
    path.closeSubpath()
    path.move(to: CGPoint(x: 10.1, y: 35.42))
    path.addLine(to: CGPoint(x: 17.9, y: 35.42))
    path.addLine(to: CGPoint(x: 17.9, y: 6.92))
    path.addLine(to: CGPoint(x: 28, y: 6.92))
    path.addLine(to: CGPoint(x: 28, y: 0))
    path.addLine(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: 0, y: 6.9))
    path.addLine(to: CGPoint(x: 10.1, y: 6.9))
    path.closeSubpath()
    path.move(to: CGPoint(x: 38.2, y: 35.42))
    path.addLine(to: CGPoint(x: 46, y: 35.42))
    path.addLine(to: CGPoint(x: 46, y: 8.25))
    path.addLine(to: CGPoint(x: 46.1, y: 8.25))
    path.addLine(to: CGPoint(x: 55.05, y: 35.4))
    path.addLine(to: CGPoint(x: 61.05, y: 35.4))
    path.addLine(to: CGPoint(x: 70.3, y: 8.25))
    path.addLine(to: CGPoint(x: 70.4, y: 8.25))
    path.addLine(to: CGPoint(x: 70.4, y: 35.4))
    path.addLine(to: CGPoint(x: 78.2, y: 35.4))
    path.addLine(to: CGPoint(x: 78.2, y: 0))
    path.addLine(to: CGPoint(x: 66.45, y: 0))
    path.addLine(to: CGPoint(x: 58.25, y: 23.1))
    path.addLine(to: CGPoint(x: 58.15, y: 23.1))
    path.addLine(to: CGPoint(x: 50, y: 0))
    path.addLine(to: CGPoint(x: 38.2, y: 0))
    path.closeSubpath()
    path.move(to: CGPoint(x: 89.14, y: 0.12))
    path.addLine(to: CGPoint(x: 100.84, y: 0.12))
    path.addCurve(to: CGPoint(x: 108.92, y: 1.12), control1: CGPoint(x: 103.564, y: 0.124), control2: CGPoint(x: 106.277, y: 0.46))
    path.addCurve(to: CGPoint(x: 115.59, y: 4.2), control1: CGPoint(x: 111.327, y: 1.691), control2: CGPoint(x: 113.595, y: 2.738))
    path.addCurve(to: CGPoint(x: 120.12, y: 9.72), control1: CGPoint(x: 117.52, y: 5.651), control2: CGPoint(x: 119.073, y: 7.544))
    path.addCurve(to: CGPoint(x: 121.79, y: 17.97), control1: CGPoint(x: 121.303, y: 12.305), control2: CGPoint(x: 121.875, y: 15.128))
    path.addCurve(to: CGPoint(x: 120.17, y: 25.55), control1: CGPoint(x: 121.844, y: 20.588), control2: CGPoint(x: 121.29, y: 23.183))
    path.addCurve(to: CGPoint(x: 115.79, y: 31.05), control1: CGPoint(x: 119.127, y: 27.68), control2: CGPoint(x: 117.633, y: 29.557))
    path.addCurve(to: CGPoint(x: 109.44, y: 34.42), control1: CGPoint(x: 113.904, y: 32.562), control2: CGPoint(x: 111.75, y: 33.706))
    path.addCurve(to: CGPoint(x: 101.89, y: 35.57), control1: CGPoint(x: 106.999, y: 35.195), control2: CGPoint(x: 104.451, y: 35.583))
    path.addLine(to: CGPoint(x: 89.14, y: 35.57))
    path.closeSubpath()
    path.move(to: CGPoint(x: 96.94, y: 28.32))
    path.addLine(to: CGPoint(x: 100.94, y: 28.32))
    path.addCurve(to: CGPoint(x: 105.94, y: 27.77), control1: CGPoint(x: 102.622, y: 28.331), control2: CGPoint(x: 104.3, y: 28.147))
    path.addCurve(to: CGPoint(x: 110, y: 26), control1: CGPoint(x: 107.403, y: 27.473), control2: CGPoint(x: 108.787, y: 26.87))
    path.addCurve(to: CGPoint(x: 112.68, y: 22.65), control1: CGPoint(x: 111.158, y: 25.124), control2: CGPoint(x: 112.079, y: 23.972))
    path.addCurve(to: CGPoint(x: 113.68, y: 17.57), control1: CGPoint(x: 113.382, y: 21.051), control2: CGPoint(x: 113.724, y: 19.316))
    path.addCurve(to: CGPoint(x: 112.68, y: 13.05), control1: CGPoint(x: 113.71, y: 16.005), control2: CGPoint(x: 113.367, y: 14.456))
    path.addCurve(to: CGPoint(x: 110.05, y: 9.87), control1: CGPoint(x: 112.056, y: 11.804), control2: CGPoint(x: 111.157, y: 10.716))
    path.addCurve(to: CGPoint(x: 106.22, y: 8), control1: CGPoint(x: 108.9, y: 9.016), control2: CGPoint(x: 107.601, y: 8.382))
    path.addCurve(to: CGPoint(x: 101.54, y: 7.37), control1: CGPoint(x: 104.697, y: 7.574), control2: CGPoint(x: 103.122, y: 7.362))
    path.addLine(to: CGPoint(x: 96.94, y: 7.37))
    path.closeSubpath()
    path.move(to: CGPoint(x: 133.09, y: 0.12))
    path.addLine(to: CGPoint(x: 146.29, y: 0.12))
    path.addCurve(to: CGPoint(x: 150.92, y: 0.45), control1: CGPoint(x: 147.839, y: 0.121), control2: CGPoint(x: 149.386, y: 0.231))
    path.addCurve(to: CGPoint(x: 155.09, y: 1.75), control1: CGPoint(x: 152.375, y: 0.638), control2: CGPoint(x: 153.786, y: 1.078))
    path.addCurve(to: CGPoint(x: 158.09, y: 4.47), control1: CGPoint(x: 156.308, y: 2.382), control2: CGPoint(x: 157.342, y: 3.319))
    path.addCurve(to: CGPoint(x: 159.24, y: 9.12), control1: CGPoint(x: 158.92, y: 5.874), control2: CGPoint(x: 159.32, y: 7.491))
    path.addCurve(to: CGPoint(x: 157.57, y: 14.12), control1: CGPoint(x: 159.309, y: 10.934), control2: CGPoint(x: 158.715, y: 12.711))
    path.addCurve(to: CGPoint(x: 153.14, y: 16.94), control1: CGPoint(x: 156.401, y: 15.474), control2: CGPoint(x: 154.861, y: 16.454))
    path.addLine(to: CGPoint(x: 153.14, y: 17))
    path.addCurve(to: CGPoint(x: 156.32, y: 18), control1: CGPoint(x: 154.247, y: 17.158), control2: CGPoint(x: 155.321, y: 17.496))
    path.addCurve(to: CGPoint(x: 158.77, y: 19.85), control1: CGPoint(x: 157.242, y: 18.463), control2: CGPoint(x: 158.072, y: 19.09))
    path.addCurve(to: CGPoint(x: 160.34, y: 22.47), control1: CGPoint(x: 159.461, y: 20.611), control2: CGPoint(x: 159.995, y: 21.502))
    path.addCurve(to: CGPoint(x: 160.89, y: 25.67), control1: CGPoint(x: 160.712, y: 23.495), control2: CGPoint(x: 160.899, y: 24.579))
    path.addCurve(to: CGPoint(x: 159.69, y: 30.35), control1: CGPoint(x: 160.95, y: 27.313), control2: CGPoint(x: 160.533, y: 28.938))
    path.addCurve(to: CGPoint(x: 156.59, y: 33.35), control1: CGPoint(x: 158.906, y: 31.579), control2: CGPoint(x: 157.844, y: 32.606))
    path.addCurve(to: CGPoint(x: 152.32, y: 35), control1: CGPoint(x: 155.272, y: 34.141), control2: CGPoint(x: 153.828, y: 34.699))
    path.addCurve(to: CGPoint(x: 147.59, y: 35.5), control1: CGPoint(x: 150.765, y: 35.333), control2: CGPoint(x: 149.18, y: 35.501))
    path.addLine(to: CGPoint(x: 133.09, y: 35.5))
    path.closeSubpath()
    path.move(to: CGPoint(x: 140.89, y: 14.27))
    path.addLine(to: CGPoint(x: 146.54, y: 14.27))
    path.addCurve(to: CGPoint(x: 148.32, y: 14.07), control1: CGPoint(x: 147.139, y: 14.273), control2: CGPoint(x: 147.737, y: 14.206))
    path.addCurve(to: CGPoint(x: 149.89, y: 13.42), control1: CGPoint(x: 148.878, y: 13.949), control2: CGPoint(x: 149.41, y: 13.729))
    path.addCurve(to: CGPoint(x: 151.02, y: 12.22), control1: CGPoint(x: 150.359, y: 13.118), control2: CGPoint(x: 150.746, y: 12.706))
    path.addCurve(to: CGPoint(x: 151.44, y: 10.42), control1: CGPoint(x: 151.313, y: 11.666), control2: CGPoint(x: 151.458, y: 11.046))
    path.addCurve(to: CGPoint(x: 151, y: 8.6), control1: CGPoint(x: 151.472, y: 9.784), control2: CGPoint(x: 151.319, y: 9.151))
    path.addCurve(to: CGPoint(x: 149.77, y: 7.47), control1: CGPoint(x: 150.69, y: 8.127), control2: CGPoint(x: 150.267, y: 7.739))
    path.addCurve(to: CGPoint(x: 148, y: 6.9), control1: CGPoint(x: 149.213, y: 7.19), control2: CGPoint(x: 148.616, y: 6.998))
    path.addCurve(to: CGPoint(x: 146.15, y: 6.72), control1: CGPoint(x: 147.39, y: 6.782), control2: CGPoint(x: 146.771, y: 6.722))
    path.addLine(to: CGPoint(x: 140.85, y: 6.72))
    path.closeSubpath()
    path.move(to: CGPoint(x: 140.89, y: 28.92))
    path.addLine(to: CGPoint(x: 147.89, y: 28.92))
    path.addCurve(to: CGPoint(x: 149.72, y: 28.72), control1: CGPoint(x: 148.506, y: 28.922), control2: CGPoint(x: 149.119, y: 28.855))
    path.addCurve(to: CGPoint(x: 151.39, y: 28.02), control1: CGPoint(x: 150.317, y: 28.598), control2: CGPoint(x: 150.884, y: 28.36))
    path.addCurve(to: CGPoint(x: 152.62, y: 26.72), control1: CGPoint(x: 151.895, y: 27.687), control2: CGPoint(x: 152.315, y: 27.242))
    path.addCurve(to: CGPoint(x: 153.09, y: 24.77), control1: CGPoint(x: 152.948, y: 26.124), control2: CGPoint(x: 153.111, y: 25.45))
    path.addCurve(to: CGPoint(x: 152.47, y: 22.77), control1: CGPoint(x: 153.117, y: 24.052), control2: CGPoint(x: 152.898, y: 23.347))
    path.addCurve(to: CGPoint(x: 150.89, y: 21.59), control1: CGPoint(x: 152.05, y: 22.251), control2: CGPoint(x: 151.507, y: 21.845))
    path.addCurve(to: CGPoint(x: 148.89, y: 21.04), control1: CGPoint(x: 150.249, y: 21.323), control2: CGPoint(x: 149.577, y: 21.138))
    path.addCurve(to: CGPoint(x: 146.84, y: 20.89), control1: CGPoint(x: 148.211, y: 20.944), control2: CGPoint(x: 147.526, y: 20.893))
    path.addLine(to: CGPoint(x: 140.94, y: 20.89))
    path.closeSubpath()
        return path
    }
}
