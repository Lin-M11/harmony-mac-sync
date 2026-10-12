import Foundation
import CoreGraphics
import ImageIO

// 生成 App 图标：圆角渐变底 + 白色对话气泡 + 三个点
// 用法: ./MakeIcon <输出目录.iconset>

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
}

func makeIcon(_ size: Int) -> CGImage? {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // 圆角底
    let inset = s * 0.05
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = s * 0.225
    let base = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(base)
    ctx.clip()
    if let grad = CGGradient(colorsSpace: cs,
                             colors: [rgb(0.24, 0.71, 0.47), rgb(0.09, 0.42, 0.72)] as CFArray,
                             locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: s),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
    }
    ctx.restoreGState()

    // 白色气泡
    let bw = s * 0.56
    let bh = s * 0.42
    let bx = (s - bw) / 2
    let by = s * 0.30
    let bubble = CGRect(x: bx, y: by, width: bw, height: bh)
    let br = bh * 0.26
    ctx.setFillColor(rgb(1, 1, 1))
    ctx.addPath(CGPath(roundedRect: bubble, cornerWidth: br, cornerHeight: br, transform: nil))
    ctx.fillPath()

    // 气泡尾巴
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: s * 0.36, y: by + bh * 0.14))
    tail.addLine(to: CGPoint(x: s * 0.30, y: s * 0.185))
    tail.addLine(to: CGPoint(x: s * 0.48, y: by + bh * 0.14))
    tail.closeSubpath()
    ctx.addPath(tail)
    ctx.fillPath()

    // 三个点
    let dotR = bh * 0.085
    let cy = by + bh / 2
    let startX = s * 0.5 - bh * 0.30
    ctx.setFillColor(rgb(0.09, 0.42, 0.72))
    for i in 0..<3 {
        let cx = startX + CGFloat(i) * bh * 0.30
        ctx.fillEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
    }

    return ctx.makeImage()
}

func writePNG(_ img: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

var ok = 0
for (name, size) in entries {
    guard let img = makeIcon(size) else {
        print("  ✗ \(name) 渲染失败")
        continue
    }
    if writePNG(img, to: outDir + "/" + name) {
        ok += 1
    } else {
        print("  ✗ \(name) 写入失败")
    }
}
print("已生成 \(ok)/\(entries.count) 张到 \(outDir)")
