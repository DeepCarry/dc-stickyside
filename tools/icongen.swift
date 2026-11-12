// 便签墙 · 应用图标生成器
// SwiftUI 矢量绘制 → ImageRenderer 离屏渲染 → PNG
// 用法: swiftc -O tools/icongen.swift -o /tmp/icongen && /tmp/icongen <变体> <尺寸> <输出.png>
import SwiftUI
import AppKit

// MARK: - 调色板（与 App 内 Paper 色一一对应）

enum P {
    static let yellow: UInt32 = 0xF7E7A6
    static let pink:   UInt32 = 0xF4D2DC
    static let blue:   UInt32 = 0xCFE0F7
    static let mint:   UInt32 = 0xD2EDDC
    static let purple: UInt32 = 0xE2D8F5
    static let cream:  UInt32 = 0xF0E8DA
    static let ink:    UInt32 = 0x2C2718
}

/// 把 hex 与目标色混合：t>0 提亮，t<0 压暗
func mix(_ hex: UInt32, _ t: Double) -> Color {
    let r = Double((hex >> 16) & 0xFF) / 255
    let g = Double((hex >> 8) & 0xFF) / 255
    let b = Double(hex & 0xFF) / 255
    let target = t >= 0 ? 1.0 : 0.0
    let k = abs(t)
    return Color(.sRGB,
                 red: r + (target - r) * k,
                 green: g + (target - g) * k,
                 blue: b + (target - b) * k,
                 opacity: 1)
}

func solid(_ hex: UInt32, _ a: Double = 1) -> Color {
    Color(.sRGB,
          red: Double((hex >> 16) & 0xFF) / 255,
          green: Double((hex >> 8) & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255,
          opacity: a)
}

// MARK: - 便签

struct StickyNote: View {
    var hex: UInt32
    var w: CGFloat
    var h: CGFloat
    var corner: CGFloat = 28
    var rot: Double = 0
    var x: CGFloat = 0
    var y: CGFloat = 0
    /// 折角大小（0 = 不折）
    var fold: CGFloat = 0
    var check: Bool = true
    /// 内容条宽度（相对宽度比例）
    var lines: [CGFloat] = [0.54, 0.49, 0.38]
    var contentScale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // 纸面：同色系三段渐变，只压暗不提亮，保证饱和度不被洗掉
            NoteShape(fold: fold, corner: corner)
                .fill(LinearGradient(colors: [mix(hex, 0.10), solid(hex), mix(hex, -0.055)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))

            NoteContent(w: w, check: check, lines: lines, scale: contentScale)
                .frame(width: w, height: h, alignment: .topLeading)

            if fold > 0 {
                Fold(side: fold, hex: hex)
            }
        }
        .frame(width: w, height: h)
        .rotationEffect(.degrees(rot))
        .offset(x: x, y: y)
    }
}

/// 便签轮廓：右下角可切出折角
struct NoteShape: Shape {
    var fold: CGFloat
    var corner: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = corner
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + c),
                       control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - (fold > 0 ? fold : c)))
        if fold > 0 {
            p.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))
        } else {
            p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY),
                           control: CGPoint(x: r.maxX, y: r.maxY))
        }
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c),
                       control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY),
                       control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// 翘起的折角：沿对角线的三角形，颜色比纸面更亮，边缘带一道高光
struct Fold: View {
    var side: CGFloat
    var hex: UInt32

    var body: some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 0, y: side))      // 左下
                p.addLine(to: CGPoint(x: side, y: 0))   // 右上
                p.addLine(to: CGPoint(x: 0, y: 0))      // 折回来的尖
                p.closeSubpath()
            }
            .fill(LinearGradient(colors: [mix(hex, 0.66), mix(hex, 0.26)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))

            // 折痕：沿斜边的高光线
            Path { p in
                p.move(to: CGPoint(x: 0, y: side))
                p.addLine(to: CGPoint(x: side, y: 0))
            }
            .stroke(Color.white.opacity(0.85), lineWidth: side * 0.022)

            // 折角投影：一道贴在斜边下方的暗边，制造纸厚
            Path { p in
                p.move(to: CGPoint(x: side * 0.06, y: side))
                p.addLine(to: CGPoint(x: side, y: side * 0.06))
            }
            .stroke(inkShadow(hex), lineWidth: side * 0.05)
            .blur(radius: side * 0.02)
            .offset(x: -side * 0.02, y: -side * 0.02)
        }
        .frame(width: side, height: side)
    }

    func inkShadow(_ hex: UInt32) -> Color { mix(hex, -0.55).opacity(0.30) }
}

struct NoteContent: View {
    var w: CGFloat
    var check: Bool
    var lines: [CGFloat]
    var scale: CGFloat

    var body: some View {
        let pad = w * 0.135
        let barH = w * 0.043 * scale
        let gap = w * 0.058 * scale
        let box = w * 0.125 * scale

        Group {
            if lines.isEmpty {
                Color.clear
            } else {
                VStack(alignment: .leading, spacing: gap) {
                    if check {
                        HStack(spacing: w * 0.05) {
                            CheckBox(side: box)
                            Capsule().fill(solid(P.ink, 0.34))
                                .frame(width: w * lines[0], height: barH)
                        }
                        .padding(.bottom, gap * 0.15)
                    } else {
                        Capsule().fill(solid(P.ink, 0.34))
                            .frame(width: w * lines[0], height: barH)
                    }
                    ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, len in
                        Capsule().fill(solid(P.ink, 0.20))
                            .frame(width: w * len, height: barH)
                    }
                }
                .padding(.leading, pad)
                .padding(.top, w * 0.135)
            }
        }
    }
}

struct CheckBox: View {
    var side: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
                .strokeBorder(solid(P.ink, 0.55), lineWidth: side * 0.125)
            Path { p in
                p.move(to: CGPoint(x: side * 0.27, y: side * 0.53))
                p.addLine(to: CGPoint(x: side * 0.44, y: side * 0.70))
                p.addLine(to: CGPoint(x: side * 0.74, y: side * 0.33))
            }
            .stroke(solid(P.ink, 0.78), style: StrokeStyle(lineWidth: side * 0.135,
                                                          lineCap: .round, lineJoin: .round))
        }
        .frame(width: side, height: side)
    }
}

// MARK: - 底板

struct Tile: View {
    var light: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 185, style: .continuous)
            .fill(LinearGradient(
                colors: light
                    ? [solid(0xFFFDF7), solid(0xF8EFE1), solid(0xE9DBC6)]
                    : [solid(0x2E2B33), solid(0x17161B), solid(0x0A090C)],
                startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .fill(RadialGradient(
                        colors: [Color.white.opacity(light ? 0.85 : 0.13), .clear],
                        center: UnitPoint(x: 0.5, y: -0.12),
                        startRadius: 0, endRadius: 720)))
            .overlay(
                RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(LinearGradient(
                        colors: light
                            ? [Color.white.opacity(0.95), Color.black.opacity(0.05)]
                            : [Color.white.opacity(0.18), Color.white.opacity(0.015)],
                        startPoint: .top, endPoint: .bottom), lineWidth: 2.5))
    }
}

// MARK: - 构图

/// 内容占位（相对 1024 画布）。
/// 参考 macOS 上同类图标：正面那张主体要占到 6~7 成宽，两张侧签只在**上角**
/// 露出窄窄一条；整组重心压在下 3/4，上方留白比下方多一点。
/// 之前的问题不是外框空，而是主体只有 46% 宽、靠两侧扇开的签子把轮廓撑到 84%——
/// 量出来的 bbox 不小，看上去却「里面东西小」。
enum IconGeom {
    /// 最后的整体微调（构图常量已经按 1024 画布调好，这里保持 1 / 0）
    static let contentScale: CGFloat = 1.0
    static let contentOffsetY: CGFloat = 0

    static let mainSize: CGFloat = 680       // 主体：66% 宽
    static let sideSize: CGFloat = 505       // 侧签：49% 宽，只在上角露一条
    static let sideDX: CGFloat = 148         // 侧签横向让位（越小越紧凑）
    static let sideDY: CGFloat = 50          // 侧签上提前量
    static let mainY: CGFloat = 100          // 主体下移，把留白挤到上边
}

struct IconView: View {
    var variant: String

    var light: Bool { variant.hasSuffix("L") }
    var single: Bool { variant.hasPrefix("C") }
    var big: Bool { variant.hasPrefix("S") }   // 小尺寸专用：单张、加大、加粗
    /// 调试用：不加底板，只渲染内容（透明底），方便量「内容实际占多大」
    var bare: Bool { variant.contains("X") }

    var body: some View {
        ZStack {
            if !bare { Tile(light: light) }
            Group {
                if single || big { singleNote } else { stack }
            }
            .scaleEffect(IconGeom.contentScale)
            .offset(y: IconGeom.contentOffsetY)
        }
    }

    // 三张扇形叠放
    var stack: some View {
        let m = IconGeom.mainSize
        let s = IconGeom.sideSize
        return ZStack {
            StickyNote(hex: P.mint, w: s, h: s, corner: s * 0.088, rot: -12,
                       x: -IconGeom.sideDX, y: -IconGeom.sideDY,
                       check: false, lines: [])
                .shadow(color: .black.opacity(0.45), radius: 36, y: 18)
            StickyNote(hex: P.purple, w: s, h: s, corner: s * 0.088, rot: 11,
                       x: IconGeom.sideDX, y: -IconGeom.sideDY + 12,
                       check: false, lines: [])
                .shadow(color: .black.opacity(0.45), radius: 36, y: 18)
            StickyNote(hex: P.yellow, w: m, h: m, corner: m * 0.068, rot: -3.5,
                       y: IconGeom.mainY,
                       fold: variant.hasPrefix("N") ? 0 : m * 0.192,
                       check: true, lines: [0.50, 0.44, 0.34, 0.26])
                .shadow(color: .black.opacity(0.50), radius: 44, y: 22)
        }
    }

    // 单张便签（小尺寸 / 备选）
    var singleNote: some View {
        let w = big ? 720.0 : 680.0
        return StickyNote(hex: P.yellow, w: w, h: w, corner: w * 0.07, rot: -5,
                          y: IconGeom.mainY,
                          fold: big ? 0 : w * 0.195, check: true,
                          lines: [0.50, 0.44, 0.30],
                          contentScale: big ? 1.18 : 1.0)
            .shadow(color: .black.opacity(light ? 0.22 : 0.50), radius: 44, y: 22)
    }
}

// MARK: - 渲染

@MainActor
func render(variant: String, size: CGFloat, to path: String) {
    let r = ImageRenderer(content: IconView(variant: variant).frame(width: 1024, height: 1024))
    r.scale = size / 1024.0
    r.isOpaque = false
    guard let cg = r.cgImage else {
        FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try? data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  \(Int(size))px")
}

let a = CommandLine.arguments
guard a.count >= 4 else {
    print("usage: icongen <variant> <size> <out.png>")
    exit(2)
}
let v = a[1], s = CGFloat(Double(a[2]) ?? 1024), o = a[3]

MainActor.assumeIsolated {
    render(variant: v, size: s, to: o)
}
