import CoreGraphics
import SwiftUI
import XCTest
@testable import LumaPlayer

/// `BaiduPanLogoMark` 的**离屏渲染**验证。
///
/// `ImageRenderer` 把标记光栅化成 `CGImage`,再采样像素:确认蓝色云标与红色字标都真的画出来了、
/// 且云标的渐变方向与官方 `userSpaceOnUse` 端点一致(亮度沿渐变方向递减)。
///
/// 不靠 `Path.contains` 挑采样点 —— 官方 path 是 `fill-rule="evenodd"`,`contains` 的「内部」
/// 与实际填充区域并不等价;改为统计蓝色像素的亮度与渐变方向投影的相关性。
///
/// ⚠️ 像素缓冲区必须在 `rasterize` 内拷贝出来再返回:`CGContext(data:)` 不持有缓冲区,
/// 上下文返回后底层数组出作用域即被释放,继续读 `ctx.data` 会读到已释放内存。
@MainActor
final class BaiduPanLogoRenderTests: XCTestCase {
    func testRendersCloudGradientAndRedWordmark() {
        let size: CGFloat = 570
        let height = size * BaiduPanGeometry.aspect

        let renderer = ImageRenderer(content: BaiduPanLogoMark(size: size))
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            return XCTFail("ImageRenderer 没有产出 CGImage")
        }
        XCTAssertEqual(image.width, Int(size), accuracy: 1)
        XCTAssertEqual(image.height, Int(height), accuracy: 1)
        guard let buffer = rasterize(image) else {
            return XCTFail("无法栅格化 CGImage")
        }

        let width = image.width
        let heightPixels = image.height
        // 收集非透明像素(视图坐标 y 向下)与颜色。
        var pixels: [Pixel] = []
        var i = 0
        while i < width * heightPixels {
            let a = buffer[i * 4 + 3]
            if a > 0 {
                let x = i % width
                let y = heightPixels - 1 - (i / width)
                // 缓冲区是 `premultipliedLast`:抗锯齿边缘像素的 RGB 已被 alpha 预乘,
                // 直接除以 255 会把边缘算成近黑色,污染渐变方向的亮度统计。这里反预乘回纯色。
                let alpha = Double(a)
                pixels.append(Pixel(
                    x: CGFloat(x),
                    y: CGFloat(y),
                    red: Double(buffer[i * 4]) / alpha,
                    green: Double(buffer[i * 4 + 1]) / alpha,
                    blue: Double(buffer[i * 4 + 2]) / alpha
                ))
            }
            i += 1
        }
        XCTAssertGreaterThan(pixels.count, 1000, "渲染几乎是空的")

        // 云标(蓝)与字标(红)都真的画出来了。
        let blue = pixels.filter { $0.blue > $0.red + 0.12 && $0.blue >= $0.green }
        let red = pixels.filter { $0.red > $0.green + 0.12 && $0.red > $0.blue + 0.12 }
        XCTAssertGreaterThan(blue.count, 5000, "云标(蓝色)像素太少")
        XCTAssertGreaterThan(red.count, 500, "字标(红色)像素太少")

        // 云标渐变方向:官方 `gB` 从 #45D9FE(浅)到 #06A6FE(深)。
        // 官方端点 x2=115.2 超出画布宽 114,换算后会落到图像外 —— 只取方向向量,不取端点本身。
        let start = CGPoint(
            x: 24.6 / BaiduPanGeometry.canvasWidth * size,
            y: 12.0 / BaiduPanGeometry.canvasHeight * height
        )
        let end = CGPoint(
            x: 115.2 / BaiduPanGeometry.canvasWidth * size,
            y: 56.4 / BaiduPanGeometry.canvasHeight * height
        )
        let direction = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let squared = direction.x * direction.x + direction.y * direction.y

        // 亮度沿渐变方向应递减 → 亮度与投影 t 的相关系数为负。
        var sumT = 0.0, sumBrightness = 0.0, sumTB = 0.0, sumT2 = 0.0, sumB2 = 0.0
        for p in blue {
            let dx = p.x - start.x
            let dy = p.y - start.y
            let t = (dx * direction.x + dy * direction.y) / squared
            let brightness = (p.red + p.green + p.blue) / 3
            sumT += t
            sumBrightness += brightness
            sumTB += t * brightness
            sumT2 += t * t
            sumB2 += brightness * brightness
        }
        let count = Double(blue.count)
        let meanT = sumT / count
        let meanBrightness = sumBrightness / count
        let covariance = sumTB / count - meanT * meanBrightness
        let correlation = covariance
            / ((sumT2 / count - meanT * meanT).squareRoot() * (sumB2 / count - meanBrightness * meanBrightness).squareRoot())
        XCTAssertLessThan(correlation, -0.5, "云标渐变方向与官方端点不符(亮度应沿渐变方向递减)")
    }

    /// 整幅栅格化成 RGBA 字节缓冲区。缓冲区在函数内拷贝出来再返回,避免上下文返回后缓冲区被释放。
    private func rasterize(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private struct Pixel {
        let x: CGFloat
        let y: CGFloat
        let red: Double
        let green: Double
        let blue: Double
    }
}
