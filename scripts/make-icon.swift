// 生成 App 图标 app/AppIcon.icns：深色圆角方块上一条由细变粗的暖色螺旋（海螺）。
// 顺带生成安装器左下角的图标 scripts/installer/background.png。
//
// 用法：swift scripts/make-icon.swift [--preview 预览图.png]
// 改了图形就再跑一次，把新生成的两个文件一起提交；build.sh、package.sh 只拷贝，不会重新生成。
import CoreGraphics
import Foundation
import ImageIO

let root = URL(fileURLWithPath: #filePath).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("app/AppIcon.icns")
let installerBackground = root.appendingPathComponent("scripts/installer/background.png")
let iconset = root.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(colorSpace: srgb, components: [r, g, b, alpha])!
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func channel(_ hex: UInt32, _ shift: UInt32) -> CGFloat { CGFloat((hex >> shift) & 0xFF) / 255 }
    let parts = [16, 8, 0].map { shift in channel(a, UInt32(shift)) * (1 - t) + channel(b, UInt32(shift)) * t }
    return CGColor(colorSpace: srgb, components: parts + [1])!
}

/// 螺旋上的点（中心线），单位长度：最外面的半径是 1
struct SpiralPoint {
    let position: CGPoint
    let radius: CGFloat
    /// 0 是最里面，1 是最外面
    let progress: CGFloat
}

/// 等角螺线 r = e^(growth·(t − 终点))，从里往外逆时针转
func spiral() -> [SpiralPoint] {
    let growth = 0.2
    let turns = 2.3
    let span = turns * 2 * Double.pi
    // 让最粗的尾巴停在右下方
    let endAngle = -0.35 * Double.pi
    let count = 1600
    return (0...count).map { i in
        let t = span * Double(i) / Double(count)
        let r = exp(growth * (t - span))
        let angle = endAngle - span + t
        return SpiralPoint(position: CGPoint(x: r * cos(angle), y: r * sin(angle)), radius: r, progress: CGFloat(i) / CGFloat(count))
    }
}

/// 笔画宽度（单位长度里），随半径变粗
func strokeWidth(_ radius: CGFloat) -> CGFloat { 0.26 * pow(radius, 0.9) }

/// 在 size × size 像素的画布上画图标；图形按 1024 的网格设计
func drawIcon(_ ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    // 小尺寸（菜单、列表里的 16、32 像素）笔画加粗一点，免得糊成一团
    let boost: CGFloat = pixels <= 32 ? 1.35 : (pixels <= 64 ? 1.15 : 1)
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)

    // macOS 图标网格：1024 的画布里 824 的主体，四周留出阴影的位置
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // 阴影的偏移和模糊不受坐标缩放影响，要自己乘
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 22 * scale, color: color(0x000000, alpha: 0.32))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x1B202B))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let background = CGGradient(colorsSpace: srgb, colors: [color(0x323B4F), color(0x151A23)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    ctx.restoreGState()

    // 细细的一圈亮边，深色背景（程序坞、暗色模式）上也看得清轮廓
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.09))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // 螺旋：先算外框，放大到主体中间
    let points = spiral()
    var box = CGRect.null
    for point in points {
        let half = strokeWidth(point.radius) / 2
        box = box.union(CGRect(x: point.position.x - half, y: point.position.y - half, width: half * 2, height: half * 2))
    }
    let target: CGFloat = 540
    let fit = target / max(box.width, box.height)
    let center = CGPoint(x: body.midX, y: body.midY)
    func place(_ p: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (p.x - box.midX) * fit, y: center.y + (p.y - box.midY) * fit)
    }

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 18 * scale, color: color(0x000000, alpha: 0.38))
    // 整条螺旋一起投影，免得每一小段的影子互相叠在笔画上
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setLineCap(.round)
    let minimum = 1.2 / scale
    for index in 1..<points.count {
        let a = points[index - 1]
        let b = points[index]
        ctx.setStrokeColor(mix(0xFFE2BC, 0xF26B43, pow(b.progress, 1.4)))
        ctx.setLineWidth(max(strokeWidth(b.radius) * fit * boost, minimum))
        ctx.move(to: place(a.position))
        ctx.addLine(to: place(b.position))
        ctx.strokePath()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func render(_ pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(ctx, pixels: pixels)
    return ctx.makeImage()!
}

/// dpi 144 表示 2 倍图：系统按一半的尺寸（点）显示
func writePNG(_ image: CGImage, to url: URL, dpi: Int = 72) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else { fatalError("写不了 \(url.path)") }
}

/// 安装器窗口左下角的图标：176×176 点的透明画布（2 倍图），128 点的图标离左边、下边各 24 点
func renderInstallerBackground() -> CGImage {
    let pixels = 352, iconPixels = 256, margin: CGFloat = 48
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: margin, y: margin)
    drawIcon(ctx, pixels: iconPixels)
    return ctx.makeImage()!
}

let fileManager = FileManager.default
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    writePNG(render(pixels), to: iconset.appendingPathComponent("\(name).png"))
}

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--preview"), flag + 1 < arguments.count {
    writePNG(render(1024), to: URL(fileURLWithPath: arguments[flag + 1]))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? fileManager.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil 没有成功") }
writePNG(renderInstallerBackground(), to: installerBackground, dpi: 144)
print("完成：\(output.path)")
print("完成：\(installerBackground.path)")
