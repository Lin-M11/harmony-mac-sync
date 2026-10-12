import Foundation
import CoreGraphics
import ImageIO

// 生成 App 图标与菜单栏模板图。
//
// 母题：一条链路把两边连起来。左边手机（实心、内容源），右边显示器带底座（描边、接收端），
// 中间一条横条落在共同中线上。App 图标用深松绿超椭圆底加暖白标记；菜单栏图标只用同一标记，
// 纯黑加透明，由系统按菜单栏明暗反相。
//
// 用法：
//   ./MakeIcon <输出目录.iconset>   生成 App 图标十张
//   ./MakeIcon --menubar [目录]     生成菜单栏模板图，默认写到 ./MenuBarIcons
//   ./MakeIcon --preview <目录>     生成预览图，含明暗菜单栏对照

// MARK: - 颜色

let GREEN = (r: 0.114, g: 0.420, b: 0.329)      // #1D6B54 深松绿
let OFFWHITE = (r: 0.980, g: 0.976, b: 0.969)   // #FAF9F7 暖白

func rgb(_ c: (r: Double, g: Double, b: Double), _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat(c.r), CGFloat(c.g), CGFloat(c.b), CGFloat(a)])!
}

// MARK: - 画布

let CANVAS: CGFloat = 1024      // 图标画布
let TILE: CGFloat = 824         // 内容区，四周留透明边距
let SQUIRCLE_N: CGFloat = 5.0   // 超椭圆指数，接近 Apple 的连续曲率

/// 建一张 y 轴向下的画布，几何常数按视觉直觉写。
func makeContext(_ width: Int, _ height: Int) -> CGContext? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

/// 超椭圆路径。n 越大越接近方形，n=5 接近 Apple 图标的连续曲率。
func squirclePath(center: CGPoint, halfW: CGFloat, halfH: CGFloat,
                  n: CGFloat = SQUIRCLE_N, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let e = 2 / n
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = center.x + halfW * (ct < 0 ? -1 : 1) * pow(abs(ct), e)
        let y = center.y + halfH * (st < 0 ? -1 : 1) * pow(abs(st), e)
        if i == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

/// 带圆角的多边形，用于底座梯形。
func roundedPolygon(_ pts: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    guard pts.count >= 3 else { return path }
    let n = pts.count
    path.move(to: CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2))
    for i in 1...n {
        path.addArc(tangent1End: pts[i % n], tangent2End: pts[(i + 1) % n], radius: radius)
    }
    path.closeSubpath()
    return path
}

// MARK: - 标记几何
// 本地坐标以标记包围盒左上角为原点，y 向下。LINK_Y 是共同中线：手机与显示器屏幕都以它居中。

let PHONE_W: CGFloat = 108
let PHONE_H: CGFloat = 212
let PHONE_R: CGFloat = 26

let GAP: CGFloat = 8            // 链路两端各留一点呼吸

let LINK_W: CGFloat = 140
let LINK_T: CGFloat = 22
let LINK_DASH_ON: CGFloat = 32  // 链路断开时的虚线段
let LINK_DASH_OFF: CGFloat = 24

let MON_W: CGFloat = 248
let MON_H: CGFloat = 168
let MON_R: CGFloat = 22
let MON_STROKE: CGFloat = 22

let STAND_TOP_W: CGFloat = 54
let STAND_BOT_W: CGFloat = 100
let STAND_H: CGFloat = 32
let STAND_R: CGFloat = 11

let LINK_Y: CGFloat = PHONE_H / 2
let LINK_X: CGFloat = PHONE_W + GAP
let MON_X: CGFloat = LINK_X + LINK_W + GAP
let STAND_TOP_Y: CGFloat = LINK_Y + MON_H / 2

let MARK_W: CGFloat = PHONE_W + GAP + LINK_W + GAP + MON_W
let MARK_H: CGFloat = max(PHONE_H, STAND_TOP_Y + STAND_H)

/// 在当前坐标系下画标记，坐标系需已按 MARK_W × MARK_H 摆好。
/// linked 为假时链路画成虚线，表示两边没接上。
func drawMark(_ ctx: CGContext, color: CGColor, linked: Bool = true) {
    ctx.setFillColor(color)
    ctx.setStrokeColor(color)

    // 手机：实心圆角矩形
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: PHONE_W, height: PHONE_H),
                       cornerWidth: PHONE_R, cornerHeight: PHONE_R, transform: nil))
    ctx.fillPath()

    // 链路：落在共同中线上的横条
    if linked {
        ctx.fill(CGRect(x: LINK_X, y: LINK_Y - LINK_T / 2, width: LINK_W, height: LINK_T))
    } else {
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [LINK_DASH_ON, LINK_DASH_OFF])
        ctx.setLineWidth(LINK_T)
        ctx.setLineCap(.butt)
        ctx.move(to: CGPoint(x: LINK_X, y: LINK_Y))
        ctx.addLine(to: CGPoint(x: LINK_X + LINK_W, y: LINK_Y))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 显示器：描边圆角矩形，外沿与 MON_W × MON_H 对齐
    let inset = MON_STROKE / 2
    let screen = CGRect(x: MON_X + inset, y: LINK_Y - MON_H / 2 + inset,
                        width: MON_W - MON_STROKE, height: MON_H - MON_STROKE)
    ctx.setLineWidth(MON_STROKE)
    ctx.addPath(CGPath(roundedRect: screen,
                       cornerWidth: MON_R - inset, cornerHeight: MON_R - inset, transform: nil))
    ctx.strokePath()

    // 底座：上窄下宽的梯形，四角圆角
    let cx = MON_X + MON_W / 2
    let stand = [
        CGPoint(x: cx - STAND_TOP_W / 2, y: STAND_TOP_Y),
        CGPoint(x: cx + STAND_TOP_W / 2, y: STAND_TOP_Y),
        CGPoint(x: cx + STAND_BOT_W / 2, y: STAND_TOP_Y + STAND_H),
        CGPoint(x: cx - STAND_BOT_W / 2, y: STAND_TOP_Y + STAND_H),
    ]
    ctx.addPath(roundedPolygon(stand, radius: STAND_R))
    ctx.fillPath()
}

// MARK: - 出图

/// 把标记按比例摆进一块框，框内居中。
func drawMarkInBox(_ ctx: CGContext, originX: CGFloat, originY: CGFloat,
                   boxW: CGFloat, boxH: CGFloat, color: CGColor, linked: Bool = true) {
    let scale = min(boxW / MARK_W, boxH / MARK_H)
    let mw = MARK_W * scale, mh = MARK_H * scale
    ctx.saveGState()
    ctx.translateBy(x: originX + (boxW - mw) / 2, y: originY + (boxH - mh) / 2)
    ctx.scaleBy(x: scale, y: scale)
    drawMark(ctx, color: color, linked: linked)
    ctx.restoreGState()
}

/// App 图标：深松绿超椭圆底 + 暖白标记。
func drawAppIcon(_ size: Int) -> CGImage? {
    guard let ctx = makeContext(size, size) else { return nil }
    let s = CGFloat(size)
    let tile = TILE / CANVAS * s

    ctx.addPath(squirclePath(center: CGPoint(x: s / 2, y: s / 2),
                             halfW: tile / 2, halfH: tile / 2))
    ctx.setFillColor(rgb(GREEN))
    ctx.fillPath()

    ctx.saveGState()
    let boxW = tile * 0.84, boxH = tile * 0.68
    drawMarkInBox(ctx, originX: (s - boxW) / 2, originY: (s - boxH) / 2,
                  boxW: boxW, boxH: boxH, color: rgb(OFFWHITE))
    ctx.restoreGState()

    return ctx.makeImage()
}

/// 菜单栏模板图：纯黑 + 透明，系统按菜单栏明暗自动反相。
func drawMenuBarIcon(height: Int, linked: Bool = true) -> CGImage? {
    let h = CGFloat(height)
    let markH = h - 2                       // 上下各留 1px，避免贴边被裁
    let width = Int((markH * MARK_W / MARK_H).rounded())
    guard let ctx = makeContext(width, height) else { return nil }
    drawMarkInBox(ctx, originX: 0, originY: 1,
                  boxW: CGFloat(width), boxH: markH, color: rgb((0, 0, 0)), linked: linked)
    return ctx.makeImage()
}

/// 菜单栏对照条：同一张模板图放在浅色底与深色底上的观感。
func drawBarStrip(_ width: Int, _ height: Int, bg: CGColor, ink: CGColor,
                  linked: Bool = true) -> CGImage? {
    guard let ctx = makeContext(width, height) else { return nil }
    ctx.setFillColor(bg)
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    drawMarkInBox(ctx, originX: 12, originY: 4,
                  boxW: CGFloat(width) - 24, boxH: CGFloat(height) - 8, color: ink, linked: linked)
    return ctx.makeImage()
}

/// 小尺寸连排：检查 16px 下是否还认得出。
func drawSmallStrip(_ sizes: [Int], gap: Int = 12) -> CGImage? {
    let h = (sizes.max() ?? 16) + gap * 2
    let w = sizes.reduce(0) { $0 + $1 + gap } + gap
    guard let ctx = makeContext(w, h) else { return nil }
    ctx.setFillColor(rgb((0.94, 0.94, 0.94)))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    var x = CGFloat(gap)
    for s in sizes {
        if let img = drawAppIcon(s) {
            ctx.draw(img, in: CGRect(x: x, y: CGFloat((h - s) / 2), width: CGFloat(s), height: CGFloat(s)))
        }
        x += CGFloat(s + gap)
    }
    return ctx.makeImage()
}

/// 评审图：把各尺寸的 App 图标与两种底、两个状态的菜单栏并排铺开，一张图看完。
func drawReviewSheet() -> CGImage? {
    let w = 960, h = 640
    guard let ctx = makeContext(w, h) else { return nil }
    let cw = CGFloat(w), ch = CGFloat(h)
    ctx.setFillColor(rgb((1, 1, 1)))
    ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))

    // 上半：App 图标各尺寸，底对齐
    let baseline: CGFloat = 320
    var x: CGFloat = 40
    for s in [256, 128, 64, 32, 16] {
        if let img = drawAppIcon(s) {
            ctx.draw(img, in: CGRect(x: x, y: baseline - CGFloat(s), width: CGFloat(s), height: CGFloat(s)))
        }
        x += CGFloat(s) + 24
    }

    // 下半：菜单栏模板图放在浅色底与深色底上的观感，通与断各一对
    let light = rgb((0.95, 0.95, 0.95)), dark = rgb((0.16, 0.16, 0.16))
    let black = rgb((0, 0, 0)), white = rgb((1, 1, 1))
    var y: CGFloat = 352
    for (bg, ink, linked) in [(light, black, true), (dark, white, true),
                              (light, black, false), (dark, white, false)] {
        if let strip = drawBarStrip(w - 80, 52, bg: bg, ink: ink, linked: linked) {
            ctx.draw(strip, in: CGRect(x: 40, y: y, width: cw - 80, height: 52))
        }
        y += 66
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

func ensureDir(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

// MARK: - 入口

let ICONSET: [(String, Int)] = [
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

var args = Array(CommandLine.arguments.dropFirst())
let mode = args.first?.hasPrefix("-") == true ? args.removeFirst() : "iconset"
let outDir = args.first ?? (mode == "--menubar" ? "./MenuBarIcons" : "./AppIcon.iconset")
ensureDir(outDir)

switch mode {
case "--menubar":
    // 菜单栏模板图：1x 高 18px，另出 @2x / @3x。
    // 名字以 Template 结尾，AppKit 取用时自动按模板图处理。
    // 两个状态各一套：链路通、链路断。
    var ok = 0, total = 0
    for (prefix, linked) in [("MenuBarIconTemplate", true), ("MenuBarIconOffTemplate", false)] {
        for (suffix, h) in [(".png", 18), ("@2x.png", 36), ("@3x.png", 54)] {
            let name = prefix + suffix
            total += 1
            guard let img = drawMenuBarIcon(height: h, linked: linked) else {
                print("  ✗ \(name) 渲染失败")
                continue
            }
            if writePNG(img, to: outDir + "/" + name) { ok += 1 } else { print("  ✗ \(name) 写入失败") }
        }
    }
    print("已生成 \(ok)/\(total) 张菜单栏模板图到 \(outDir)")

case "--preview":
    var ok = 0, total = 0
    func out(_ name: String, _ img: CGImage?) {
        total += 1
        guard let img = img else { print("  ✗ \(name) 渲染失败"); return }
        if writePNG(img, to: outDir + "/" + name) { ok += 1 } else { print("  ✗ \(name) 写入失败") }
    }
    for s in [16, 32, 64, 128, 256, 512, 1024] {
        out("app-\(s).png", drawAppIcon(s))
    }
    for h in [18, 36, 54] {
        out("menubar-on-\(h).png", drawMenuBarIcon(height: h, linked: true))
        out("menubar-off-\(h).png", drawMenuBarIcon(height: h, linked: false))
    }
    let light = rgb((0.95, 0.95, 0.95)), dark = rgb((0.16, 0.16, 0.16))
    let black = rgb((0, 0, 0)), white = rgb((1, 1, 1))
    out("bar-light.png", drawBarStrip(600, 48, bg: light, ink: black, linked: true))
    out("bar-dark.png", drawBarStrip(600, 48, bg: dark, ink: white, linked: true))
    out("bar-light-off.png", drawBarStrip(600, 48, bg: light, ink: black, linked: false))
    out("bar-dark-off.png", drawBarStrip(600, 48, bg: dark, ink: white, linked: false))
    out("small-strip.png", drawSmallStrip([16, 32, 48, 64]))
    out("sheet.png", drawReviewSheet())
    print("已生成 \(ok)/\(total) 张预览图到 \(outDir)")

default:
    var ok = 0
    for (name, size) in ICONSET {
        guard let img = drawAppIcon(size) else {
            print("  ✗ \(name) 渲染失败")
            continue
        }
        if writePNG(img, to: outDir + "/" + name) { ok += 1 } else { print("  ✗ \(name) 写入失败") }
    }
    print("已生成 \(ok)/\(ICONSET.count) 张到 \(outDir)")
}
