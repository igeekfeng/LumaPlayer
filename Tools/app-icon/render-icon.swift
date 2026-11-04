// render-icon.swift —— App 图标的唯一源文件:生成 Icon Composer 文档 AppIcon.icon(icon.json + SVG 图层)。
// 玻璃质感、高光、阴影以及深色 / 清透 / 着色外观都由系统渲染,这里只描述图层几何与颜色;
// ⛔ 不手改 AppIcon.icon 里的文件,也不在 SVG 里画阴影 / 高光(会和系统渲染叠加成脏边)。
//
// 用法(仓库根执行):swift Tools/app-icon/render-icon.swift LumaPlayer/Resources/AppIcon.icon
// 预览(不进仓库):
//   "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
//     LumaPlayer/Resources/AppIcon.icon --export-image --output-file <png> --platform macOS \
//     --rendition Default|Dark|ClearLight|TintedDark --width 512 --height 512 --scale 1
//
// 放 Tools/ 而不是 LumaPlayer/ 下:后者是同步文件夹,放进去会被编进 App。
//
// 构图:玻璃播放键 + 身后飞过的三条弹幕胶囊,夜色底。图层坐标系 1024×1024,y 向下;
// 系统按 macOS 圆角矩形裁切整张画布,主体保持在中央约 800 内,小尺寸(16 / 32)才不糊。

import Foundation

let canvas = 1024

/// 圆角播放三角形的 SVG path,(cx, cy) 为视觉中心(重心),h 为高,r 为圆角半径。
func playTrianglePath(cx: Double, cy: Double, h: Double, r: Double) -> String {
    let w = h * 0.866
    let left = cx - w / 3, right = cx + w * 2 / 3
    let pts = [(left, cy - h / 2), (right, cy), (left, cy + h / 2)]
    func lerp(_ p: (Double, Double), _ q: (Double, Double), _ t: Double) -> (Double, Double) {
        (p.0 + (q.0 - p.0) * t, p.1 + (q.1 - p.1) * t)
    }
    func dist(_ p: (Double, Double), _ q: (Double, Double)) -> Double { hypot(q.0 - p.0, q.1 - p.1) }
    func f(_ v: Double) -> String { String(format: "%.1f", v) }
    // 60° 顶角:切点距顶点 r·√3
    let k = r * 3.0.squareRoot()
    var d = ""
    for i in 0..<3 {
        let p = pts[(i + 2) % 3], q = pts[i], n = pts[(i + 1) % 3]
        let a = lerp(q, p, k / dist(q, p)), b = lerp(q, n, k / dist(q, n))
        d += "\(i == 0 ? "M" : "L")\(f(a.0)) \(f(a.1)) Q\(f(q.0)) \(f(q.1)) \(f(b.0)) \(f(b.1)) "
    }
    return d + "Z"
}

func svg(_ body: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(canvas)\" height=\"\(canvas)\" viewBox=\"0 0 \(canvas) \(canvas)\">\(body)</svg>\n"
}

/// 弹幕胶囊:(左端 x, 中心 y, 宽, 颜色, 不透明度)。最长那条贴着播放键左缘,三条错开像在飞。
let pills: [(x: Int, y: Int, width: Int, color: String, opacity: Double)] = [
    (196, 388, 290, "#FF6F91", 0.95),
    (130, 512, 330, "#FFC56B", 1),
    (236, 636, 230, "#5CE1E6", 0.95),
]
let pillHeight = 56

let playSVG = svg("<path d=\"\(playTrianglePath(cx: 612, cy: 512, h: 420, r: 46))\" fill=\"#FFFFFF\"/>")
let pillsSVG = svg(pills.map {
    "<rect x=\"\($0.x)\" y=\"\($0.y - pillHeight / 2)\" width=\"\($0.width)\" height=\"\(pillHeight)\" "
        + "rx=\"\(pillHeight / 2)\" fill=\"\($0.color)\" fill-opacity=\"\($0.opacity)\"/>"
}.joined())

func p3(_ hex: UInt32) -> String {
    let c = [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF].map { String(format: "%.5f", Double($0) / 255) }
    return "display-p3:\(c[0]),\(c[1]),\(c[2]),1.00000"
}

func group(_ imageName: String, _ name: String) -> [String: Any] {
    [
        "layers": [["image-name": imageName, "name": name, "glass": true]],
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "translucency": ["enabled": true, "value": 0.4],
    ]
}

// groups 顺序即叠放顺序,第一个在最上层
let iconJSON: [String: Any] = [
    "fill": ["linear-gradient": [p3(0x2A2E45), p3(0x0B0C14)]],
    "groups": [group("play.svg", "play"), group("pills.svg", "danmaku")],
    "supported-platforms": ["squares": ["macOS"]],
]

let args = CommandLine.arguments
guard args.count == 2, args[1].hasSuffix(".icon") else {
    FileHandle.standardError.write(Data("用法: swift render-icon.swift <输出路径/AppIcon.icon>\n".utf8))
    exit(2)
}
let fm = FileManager.default
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let assets = outDir.appendingPathComponent("Assets", isDirectory: true)
if fm.fileExists(atPath: outDir.path) { try fm.removeItem(at: outDir) }
try fm.createDirectory(at: assets, withIntermediateDirectories: true)
try Data(playSVG.utf8).write(to: assets.appendingPathComponent("play.svg"))
try Data(pillsSVG.utf8).write(to: assets.appendingPathComponent("pills.svg"))
let json = try JSONSerialization.data(withJSONObject: iconJSON, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("icon.json"))
print("已生成 \(outDir.path)")
