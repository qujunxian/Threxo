import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 千梭图标：深靛蓝底 + 白色梭子 + 三道经线镂空。
// 全部用参数方程绘制，1024 canvas，主体 824 居中（四周留 100）。

let canvas: CGFloat = 1024
let inset: CGFloat = 100
let body = canvas - inset * 2          // 824
let center = CGPoint(x: canvas / 2, y: canvas / 2)

// MARK: - 路径构造

/// 超椭圆（squircle）。指数 2/n，n=5 时视觉接近 Apple 的连续圆角。
func squirclePath(size: CGFloat, n: CGFloat = 5) -> CGPath {
    let a = size / 2
    let path = CGMutablePath()
    let steps = 1024
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = a * copysign(pow(abs(ct), 2 / n), ct)
        let y = a * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// 梭形：沿角度 `angle` 的纺锤。两端收尖，中段饱满。
/// `halfLength` 沿轴半长，`halfWidth` 垂直半宽。
func shuttlePath(halfLength: CGFloat, halfWidth: CGFloat, angle: CGFloat) -> CGPath {
    var top: [CGPoint] = []
    var bottom: [CGPoint] = []
    let steps = 400
    for i in 0...steps {
        let u = -1 + 2 * CGFloat(i) / CGFloat(steps)   // -1 → 1
        // 1-u^4 让中段保持接近满宽、靠近两端才迅速收尖，
        // 轮廓是「船形梭子」；用 1-u^2 会得到一枚椭圆，不像梭。
        let w = halfWidth * pow(max(0, 1 - pow(u, 4)), 0.5)
        let along = u * halfLength
        let ca = cos(angle), sa = sin(angle)
        // 轴方向 (ca, sa)，法方向 (-sa, ca)
        top.append(CGPoint(x: along * ca - w * -sa, y: along * sa - w * ca))
        bottom.append(CGPoint(x: along * ca + w * -sa, y: along * sa + w * ca))
    }
    let path = CGMutablePath()
    path.move(to: top[0])
    for p in top.dropFirst() { path.addLine(to: p) }
    for p in bottom.reversed() { path.addLine(to: p) }
    path.closeSubpath()
    return path
}

/// 沿某方向的圆头胶囊，用来做经线镂空。
func capsulePath(from a: CGPoint, to b: CGPoint, radius: CGFloat) -> CGPath {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = max(0.0001, sqrt(dx * dx + dy * dy))
    let angle = atan2(dy, dx)
    let path = CGMutablePath()
    path.addArc(center: b, radius: radius, startAngle: angle - .pi / 2,
                endAngle: angle + .pi / 2, clockwise: false)
    path.addArc(center: a, radius: radius, startAngle: angle + .pi / 2,
                endAngle: angle - .pi / 2, clockwise: false)
    path.closeSubpath()
    return path
}

// MARK: - 配色

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let bgTop = rgb(0x1E3055)
let bgBottom = rgb(0x0B1322)
let bodyLight = rgb(0xFFFFFF)
let bodyShade = rgb(0xD9E3F2)

// MARK: - 绘制

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil,
    width: Int(canvas), height: Int(canvas),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// --- 底板 ---
// squirclePath 以原点为中心，这里先挪到画布正中（body/2），再整体平移 inset。
let plate = CGMutablePath()
plate.addPath(squirclePath(size: body),
              transform: CGAffineTransform(translationX: body / 2, y: body / 2))
ctx.saveGState()
ctx.translateBy(x: inset, y: inset)

// 不画底板外投影。macOS 自己在 Dock / 访达里会给图标加落影，
// 我们画的阴影会溢进四周 100px 留白区，系统据此判定成「旧式全出血图标」，
// 反过来再套一层灰白底板，整个图标就废了。
ctx.addPath(plate)
ctx.setFillColor(bgBottom)
ctx.fillPath()

// 底板渐变
ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
let gradient = CGGradient(colorsSpace: cs,
                          colors: [bgTop, bgBottom] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: body),
                       end: CGPoint(x: body, y: 0),
                       options: [])

// 顶部高光，模拟从上方来的光
let glow = CGGradient(colorsSpace: cs,
                      colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: body * 0.5, y: body * 0.92), startRadius: 0,
                       endCenter: CGPoint(x: body * 0.5, y: body * 0.92), endRadius: body * 0.72,
                       options: [])

// --- 梭子 ---
let angle: CGFloat = -38 * .pi / 180
let halfLength = body * 0.365
let halfWidth = body * 0.107

// 梭子身后的青色光晕：呼应「千梭」的丝线意象，也把纯黑白拉开层次。
// 用 screen 混合，只提亮暗部，不会在白底上留下痕迹。
do {
    let halo = CGGradient(
        colorsSpace: cs,
        colors: [rgb(0x5AC8E8, 0.20), rgb(0x5AC8E8, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.setBlendMode(.screen)
    ctx.drawRadialGradient(
        halo,
        startCenter: CGPoint(x: body * 0.5, y: body * 0.5), startRadius: 0,
        endCenter: CGPoint(x: body * 0.62, y: body * 0.38), endRadius: body * 0.62,
        options: []
    )
    ctx.restoreGState()
}

let shuttle = shuttlePath(halfLength: halfLength, halfWidth: halfWidth, angle: angle)
let centered = CGMutablePath()
centered.addPath(shuttle, transform: CGAffineTransform(translationX: body / 2, y: body / 2))

// 经线：三条沿梭子轴向的胶囊，画在梭子上再"挖"出来
let threadRadius = body * 0.018
let normal = CGPoint(x: -sin(angle), y: cos(angle))
let axis = CGPoint(x: cos(angle), y: sin(angle))
let mid = CGPoint(x: body / 2, y: body / 2)

var threads: [CGPath] = []
for o in [-0.52, 0.0, 0.52] as [CGFloat] {
    let off = halfWidth * o
    let len = halfLength * 0.46
    let c = CGPoint(x: mid.x + normal.x * off, y: mid.y + normal.y * off)
    let a = CGPoint(x: c.x - axis.x * len, y: c.y - axis.y * len)
    let b = CGPoint(x: c.x + axis.x * len, y: c.y + axis.y * len)
    threads.append(capsulePath(from: a, to: b, radius: threadRadius))
}

// 梭子本体（带轻微下落阴影，层次感来自这里）
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: rgb(0x000000, 0.30))
ctx.addPath(centered)
ctx.setFillColor(bodyShade)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(centered)
ctx.clip()
let bodyGrad = CGGradient(colorsSpace: cs,
                          colors: [bodyLight, bodyShade] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(bodyGrad,
                       start: CGPoint(x: body * 0.2, y: body * 0.85),
                       end: CGPoint(x: body * 0.8, y: body * 0.15),
                       options: [])
ctx.restoreGState()

// 梭子上方一层薄高光，避免大面积死白
ctx.saveGState()
ctx.addPath(centered)
ctx.clip()
let sheen = CGGradient(colorsSpace: cs,
                       colors: [rgb(0xFFFFFF, 0.0), rgb(0xFFFFFF, 0.55)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen,
                       start: CGPoint(x: body * 0.5, y: body * 0.10),
                       end: CGPoint(x: body * 0.5, y: body * 0.55),
                       options: [])
ctx.restoreGState()

// 经线镂空：clip 到胶囊，重新铺一次底板渐变，视觉上就是"透出背面"
let plateGrad2 = CGGradient(colorsSpace: cs,
                            colors: [bgTop, bgBottom] as CFArray,
                            locations: [0, 1])!
for t in threads {
    ctx.saveGState()
    ctx.addPath(t)
    ctx.clip()
    ctx.drawLinearGradient(plateGrad2,
                           start: CGPoint(x: 0, y: body),
                           end: CGPoint(x: body, y: 0),
                           options: [])
    ctx.restoreGState()
}

ctx.restoreGState()   // 撤销底板 clip
ctx.restoreGState()   // 撤销 translate

// MARK: - 输出

guard let image = ctx.makeImage() else { fatalError("no image") }
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon-1024.png"
guard let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outPath) as CFURL,
    UTType.png.identifier as CFString, 1, nil
) else { fatalError("no dest") }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath) \(image.width)x\(image.height)")
