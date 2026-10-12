import SwiftUI
import AppKit

// 视觉令牌，取自 DESIGN.md。
//
// 深浅两套值靠 NSColor 的动态色一次性给全，视图里直接用 Color.hsXxx，
// 不必在每个视图里判断 colorScheme，也不会漏掉某一处。

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

private func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(rgb: isDark ? dark : light)
    })
}

extension Color {
    static let hsCanvas = dyn(0xFAF9F7, 0x17181A)
    static let hsSurface = dyn(0xFFFFFF, 0x1E2022)
    static let hsChrome = dyn(0xF3F1ED, 0x212325)
    static let hsHover = dyn(0xEFEDE8, 0x2A2C2E)
    static let hsLine = dyn(0xE4E1DA, 0x33363A)
    static let hsLineStrong = dyn(0xCFCCC4, 0x45484C)
    static let hsInk = dyn(0x1B1D1C, 0xF0F1EF)
    static let hsInk2 = dyn(0x4A4F4C, 0xC3C6C3)
    static let hsInk3 = dyn(0x636865, 0x8E938F)
    static let hsAccent = dyn(0x1D6B54, 0x4FBF9A)
    static let hsAccentSoft = dyn(0xE3F0EB, 0x1C3A32)
    static let hsWait = dyn(0x8A6A1F, 0xD8AC53)
    static let hsDanger = dyn(0xA93B36, 0xE0776F)
    static let hsOnAccent = dyn(0xFFFFFF, 0x10120F)
    /// 开关滑块：关态底上的那个圆
    static let hsKnob = dyn(0xFFFFFF, 0xF1F2F0)
}

/// 间距按 4 的倍数，圆角四档。
enum HS {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12
    static let s4: CGFloat = 16, s5: CGFloat = 24, s6: CGFloat = 32
    static let rControl: CGFloat = 6, rRow: CGFloat = 10, rPanel: CGFloat = 14
}

extension Font {
    static let hsWindowTitle = Font.system(size: 18, weight: .medium)
    static let hsSectionTitle = Font.system(size: 16, weight: .medium)
    static let hsBody = Font.system(size: 14)
    static let hsBodyStrong = Font.system(size: 14, weight: .medium)
    static let hsCaption = Font.system(size: 12)
    static let hsMono = Font.system(size: 12, design: .monospaced)
}

// MARK: - 母题

/// 母题：一条链路把两边连起来。
/// 几何与 App 图标同源（见 make_icon.swift 的标记常量），viewBox 512 × 222。
struct LinkMark: View {
    var linked: Bool = true
    var color: Color = .hsAccent
    /// 标记宽度，高度按 viewBox 比例推出来
    var width: CGFloat = 22

    private let VBW: CGFloat = 512
    private let VBH: CGFloat = 222

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width / VBW, size.height / VBH)
            let ox = (size.width - VBW * k) / 2
            let oy = (size.height - VBH * k) / 2
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: ox + x * k, y: oy + y * k)
            }
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: pt(x, y).x, y: pt(x, y).y, width: w * k, height: h * k),
                     cornerRadius: r * k)
            }

            // 手机：实心
            ctx.fill(box(0, 0, 108, 212, 26), with: .color(color))

            // 链路：落在共同中线上，通为实心横条、断为虚线
            if linked {
                ctx.fill(box(116, 95, 140, 22, 11), with: .color(color))
            } else {
                var line = Path()
                line.move(to: pt(116, 106))
                line.addLine(to: pt(256, 106))
                ctx.stroke(line, with: .color(color),
                           style: StrokeStyle(lineWidth: 22 * k, lineCap: .butt,
                                              dash: [32 * k, 24 * k]))
            }

            // 显示器：描边
            ctx.stroke(box(275, 33, 226, 146, 11), with: .color(color), lineWidth: 22 * k)

            // 底座：梯形
            var stand = Path()
            stand.move(to: pt(361, 190))
            stand.addLine(to: pt(415, 190))
            stand.addLine(to: pt(438, 222))
            stand.addLine(to: pt(338, 222))
            stand.closeSubpath()
            ctx.fill(stand, with: .color(color))
        }
        .frame(width: width, height: width * VBH / VBW)
        .accessibilityHidden(true)
    }
}

// MARK: - 小组件

/// 状态指示：7px 圆点 + 12px 文字，三态。
struct StateChip: View {
    enum Kind { case on, wait, off }

    let kind: Kind
    let text: String

    private var tint: Color {
        switch kind {
        case .on: return .hsAccent
        case .wait: return .hsWait
        case .off: return .hsInk3
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(kind == .off ? Color.hsLineStrong : tint)
                .frame(width: 7, height: 7)
            Text(text).font(.hsCaption).foregroundStyle(tint)
        }
        .fixedSize()
    }
}

/// 1px 分隔线。层次靠线，列表里按它分段。
struct HairLine: View {
    var body: some View {
        Rectangle().fill(Color.hsLine).frame(height: 1)
    }
}

/// 面板里的一行：左边标签 + 提示，右边一个控件。
struct SettingRow<Accessory: View>: View {
    let title: String
    let hint: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: HS.s3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.hsBodyStrong).foregroundStyle(Color.hsInk)
                Text(hint).font(.hsCaption).foregroundStyle(Color.hsInk3)
            }
            Spacer(minLength: HS.s2)
            accessory
        }
        .padding(.horizontal, HS.s4)
        .padding(.vertical, HS.s3)
    }
}

/// 按钮：主操作着主色，其余描边。两级就够，多了就是装饰。
struct PanelButton: View {
    enum Kind { case primary, plain }

    let title: String
    var kind: Kind = .plain
    var enabled = true
    var fillWidth = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.hsCaption)
                .foregroundStyle(kind == .primary ? Color.hsOnAccent : Color.hsInk)
                .frame(maxWidth: fillWidth ? .infinity : nil)
                .padding(.vertical, 5)
                .padding(.horizontal, fillWidth ? 0 : HS.s3)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .background(
            RoundedRectangle(cornerRadius: HS.rControl)
                .fill(kind == .primary ? Color.hsAccent : Color.hsSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HS.rControl)
                .strokeBorder(kind == .primary ? Color.hsAccent : Color.hsLineStrong, lineWidth: 1)
        )
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}

/// 开关：32 × 20，滑块 16px，位移 180ms 指数缓出。开态底色为主色。
struct HSSwitch: View {
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        Capsule()
            .fill(isOn ? Color.hsAccent : Color.hsLineStrong)
            .frame(width: 32, height: 20)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Color.hsOnAccent : Color.hsKnob)
                    .frame(width: 16, height: 16)
                    .padding(2)
            }
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.18), value: isOn)
            .contentShape(Capsule())
            .onTapGesture { if enabled { isOn.toggle() } }
            .opacity(enabled ? 1 : 0.5)
            .accessibilityElement()
            .accessibilityAddTraits(isOn ? [.isToggle, .isSelected] : .isToggle)
    }
}

/// 按下时压一档亮度，其余交给系统。
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// 可点的列表行：悬停变 hover 底，选中变 accent-soft 底加 2px 主色内阴影。
struct RowSurface: ViewModifier {
    var hovered: Bool
    var selected: Bool

    func body(content: Content) -> some View {
        content
            .background(selected ? Color.hsAccentSoft : (hovered ? Color.hsHover : Color.clear))
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle().fill(Color.hsAccent).frame(width: 2)
                }
            }
    }
}

