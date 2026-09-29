// render-icon.swift
//
// LumaPlayer App 图标的唯一源文件:用 CoreGraphics 直接绘制,输出 AppIcon.appiconset
// 所需的 10 张 PNG。本机没有 SVG 渲染工具,用脚本绘制可复现且不引入依赖。
//
// 用法(仓库根执行):
//   swift Tools/app-icon/render-icon.swift LumaPlayer/Resources/Assets.xcassets/AppIcon.appiconset
//
// 放在 Tools/ 而不是 LumaPlayer/ 下:后者是同步文件夹,放进去会被编进 App。
//
// 几何按 macOS 图标网格:1024 画布,主体 824×824 圆角矩形居中(四周留 100 给阴影),
// 圆角半径约 185。主体不贴合这个形状时,macOS 26 起会把图标塞进灰色底板里。

import AppKit
import CoreGraphics
import Foundation

let canvas: CGFloat = 1024
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185.4

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    guard let g = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: colors as CFArray,
        locations: locations
    ) else { fatalError("无法创建渐变") }
    return g
}

/// 圆角播放三角形:以 (cx, cy) 为视觉中心,高 h。
func playTriangle(cx: CGFloat, cy: CGFloat, h: CGFloat, radius: CGFloat) -> CGPath {
    let w = h * 0.866
    // 三角形重心在底边 1/3 处,向右偏移让视觉居中
    let left = cx - w / 3
    let right = cx + w * 2 / 3
    let a = CGPoint(x: left, y: cy + h / 2)
    let b = CGPoint(x: right, y: cy)
    let c = CGPoint(x: left, y: cy - h / 2)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2))
    path.addArc(tangent1End: a, tangent2End: b, radius: radius)
    path.addArc(tangent1End: b, tangent2End: c, radius: radius)
    path.addArc(tangent1End: c, tangent2End: a, radius: radius)
    path.closeSubpath()
    return path
}

func drawIcon(in ctx: CGContext) {
    let body = CGPath(
        roundedRect: bodyRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
    )
    let center = CGPoint(x: bodyRect.midX, y: bodyRect.midY)

    // 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0x14163A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()

    // 背景:深夜蓝 → 靛紫(CoreGraphics 坐标 y 向上,start 在顶部)
    ctx.drawLinearGradient(
        gradient([rgb(0x2A2F7A), rgb(0x161A4A), rgb(0x0B0D26)], [0, 0.55, 1]),
        start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
        end: CGPoint(x: bodyRect.maxX, y: bodyRect.minY),
        options: []
    )

    // 中央辉光(Luma = 亮度)
    ctx.drawRadialGradient(
        gradient([rgb(0x8FB4FF, 0.55), rgb(0x6A5CFF, 0.18), rgb(0x6A5CFF, 0)], [0, 0.45, 1]),
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: 400,
        options: []
    )

    // 光环
    let ringRadius: CGFloat = 292
    ctx.addEllipse(in: CGRect(
        x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2
    ))
    ctx.setLineWidth(22)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0xFFE3A8, 0.95), rgb(0xFF9AD5, 0.7), rgb(0x7FA8FF, 0.25)], [0, 0.5, 1]),
        start: CGPoint(x: center.x - ringRadius, y: center.y + ringRadius),
        end: CGPoint(x: center.x + ringRadius, y: center.y - ringRadius),
        options: []
    )
    ctx.restoreGState()

    // 播放键
    let play = playTriangle(cx: center.x + 8, cy: center.y, h: 330, radius: 44)
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.setShadow(offset: .zero, blur: 60, color: rgb(0xA9C4FF, 0.9))
    ctx.addPath(play)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(play)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0xFFFFFF), rgb(0xE4ECFF)], [0, 1]),
        start: CGPoint(x: center.x, y: center.y + 165),
        end: CGPoint(x: center.x, y: center.y - 165),
        options: []
    )
    ctx.restoreGState()

    // 顶部细高光描边,模拟玻璃边缘
    ctx.saveGState()
    ctx.addPath(CGPath(
        roundedRect: bodyRect.insetBy(dx: 2, dy: 2),
        cornerWidth: cornerRadius - 2, cornerHeight: cornerRadius - 2, transform: nil
    ))
    ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0)], [0, 1]),
        start: CGPoint(x: center.x, y: bodyRect.maxY),
        end: CGPoint(x: center.x, y: bodyRect.midY),
        options: []
    )
    ctx.restoreGState()
}

func renderPNG(pixels: Int, to url: URL) throws {
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    ctx.interpolationQuality = .high
    let scale = CGFloat(pixels) / canvas
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(in: ctx)
    guard let image = ctx.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("用法: swift render-icon.swift <AppIcon.appiconset 目录>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try renderPNG(pixels: size * scale, to: outDir.appendingPathComponent(name))
        images.append([
            "filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)",
        ])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("已生成 \(images.count) 张图标到 \(outDir.path)")
