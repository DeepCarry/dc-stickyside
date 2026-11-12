// 菜单栏图标 · 反白实心版设计稿（只出图，不改 App 代码）
//
// 用法:
//   swiftc -O tools/mbicon-preview.swift -o /tmp/mbicon-preview
//   /tmp/mbicon-preview
// 输出:
//   shots/menubar/design-fill-sheet.png  四个候选并排总览
//   shots/menubar/design-fill-real.png   36px / 18px 的像素级放大（4x / 8x）
import AppKit

// MARK: - 基础几何（与 tools/icongen.swift 同一套 1024 画布常量）

let U: CGFloat = 1024.0 / 18.0

struct Card {
    var side: CGFloat, rot: CGFloat, dx: CGFloat, dy: CGFloat, corner: CGFloat
}

func card(_ side: CGFloat, _ rot: CGFloat, _ x: CGFloat, _ y: CGFloat, _ cornerRatio: CGFloat) -> Card {
    let s = side / U
    return Card(side: s, rot: rot, dx: x / U, dy: -y / U, corner: s * cornerRatio)
}

struct Spec {
    var check: Bool
    var tick: Bool
    var lens: [CGFloat]
    var barH: CGFloat     // 相对纸宽
    var gap: CGFloat      // 相对纸宽
    var box: CGFloat      // 相对纸宽
    var pad: CGFloat = 0.135
}

/// 勾选框 + 4 行（与 App 图标同一套比例）
let spec4 = Spec(check: true, tick: true, lens: [0.46, 0.44, 0.34, 0.26], barH: 0.055, gap: 0.072, box: 0.125)
/// 勾选框 + 4 行，比 App 图标那套略收一点间距：18px 下正好填满纸面、不糊
let spec3 = Spec(check: true, tick: true, lens: [0.47, 0.42, 0.36, 0.26], barH: 0.065, gap: 0.072, box: 0.150, pad: 0.140)

// MARK: - 路径

func notePath(_ c: Card, cut: CGFloat = 0) -> NSBezierPath {
    let s = c.side, r = max(0.35, c.corner)
    let x0 = -s / 2, x1 = s / 2, y0 = -s / 2, y1 = s / 2
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x0 + r, y: y1))
    p.line(to: NSPoint(x: x1 - r, y: y1))
    p.appendArc(withCenter: NSPoint(x: x1 - r, y: y1 - r), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
    if cut > 0 {
        p.line(to: NSPoint(x: x1, y: y0 + cut))
        p.line(to: NSPoint(x: x1 - cut, y: y0))
    } else {
        p.line(to: NSPoint(x: x1, y: y0 + r))
        p.appendArc(withCenter: NSPoint(x: x1 - r, y: y0 + r), radius: r, startAngle: 0, endAngle: -90, clockwise: true)
    }
    p.line(to: NSPoint(x: x0 + r, y: y0))
    p.appendArc(withCenter: NSPoint(x: x0 + r, y: y0 + r), radius: r, startAngle: 270, endAngle: 180, clockwise: true)
    p.line(to: NSPoint(x: x0, y: y1 - r))
    p.appendArc(withCenter: NSPoint(x: x0 + r, y: y1 - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
    p.close()
    p.transform(using: AffineTransform(rotationByDegrees: c.rot))
    p.transform(using: AffineTransform(translationByX: c.dx, byY: c.dy))
    return p
}

func contentShapes(_ c: Card, _ sp: Spec, bold: CGFloat) -> (stroked: [NSBezierPath], filled: [NSBezierPath]) {
    let w = c.side
    let pad = w * sp.pad
    let box = w * sp.box
    let barH = w * sp.barH * bold
    let gap = w * sp.gap * bold
    let left0 = -w / 2 + pad
    let top = w / 2 - pad

    var stroked: [NSBezierPath] = []
    var filled: [NSBezierPath] = []

    var y = top
    if sp.check {
        let cb = NSBezierPath(roundedRect: NSRect(x: left0, y: top - box, width: box, height: box),
                              xRadius: box * 0.28, yRadius: box * 0.28)
        cb.lineWidth = max(box * 0.12, 0.45) * bold
        stroked.append(cb)
        if sp.tick {
            let t = NSBezierPath()
            t.move(to: NSPoint(x: left0 + box * 0.24, y: top - box * 0.48))
            t.line(to: NSPoint(x: left0 + box * 0.44, y: top - box * 0.72))
            t.line(to: NSPoint(x: left0 + box * 0.78, y: top - box * 0.30))
            t.lineWidth = max(box * 0.12, 0.45) * bold
            t.lineCapStyle = .round
            t.lineJoinStyle = .round
            stroked.append(t)
        }
        filled.append(NSBezierPath(roundedRect: NSRect(x: left0 + box + w * 0.055,
                                                       y: top - box / 2 - barH / 2,
                                                       width: w * sp.lens[0], height: barH),
                                   xRadius: barH / 2, yRadius: barH / 2))
        y = top - box - gap * 0.9 - barH
    } else {
        filled.append(NSBezierPath(roundedRect: NSRect(x: left0, y: top - barH, width: w * sp.lens[0], height: barH),
                                   xRadius: barH / 2, yRadius: barH / 2))
        y = top - barH - gap
    }
    for len in sp.lens.dropFirst() {
        filled.append(NSBezierPath(roundedRect: NSRect(x: left0, y: y, width: w * len, height: barH),
                                   xRadius: barH / 2, yRadius: barH / 2))
        y -= (barH + gap)
    }

    let r = AffineTransform(rotationByDegrees: c.rot)
    let t = AffineTransform(translationByX: c.dx, byY: c.dy)
    for p in stroked { p.transform(using: r); p.transform(using: t) }
    for p in filled { p.transform(using: r); p.transform(using: t) }
    return (stroked, filled)
}

// MARK: - 候选定义

/// 后层纸的排布方式
enum Stack {
    case none                 // 只有一张
    case behindUp             // 后面一张，正上方露一条边（同角度）
    case fan                  // 与 App 图标同构：三张扇开
}

struct Candidate {
    var title: String
    var note: [String]
    var stack: Stack
    var cut: CGFloat          // 右下切角（1024 单位）
    var gap: CGFloat          // 纸间透明缝（pt）
    var spec: Spec = spec4
    var rot: CGFloat = 0
    var dyShift: CGFloat = 0        // 仅用于把构图摆正（pt）
    var isOutline = false
}

let candidates: [Candidate] = [
    Candidate(title: "甲 · 与 App 图标同构",
              note: ["三张扇开 + −3.5° 倾斜，最贴应用图标；",
                     "代价是小尺寸发糊，后两张只剩噪点"],
              stack: .fan, cut: 0, gap: 0.85, spec: spec4, rot: 3.5, dyShift: -0.6),
    Candidate(title: "乙 · 单张（推荐）",
              note: ["摆正，勾选框 + 4 行，线条加粗一档；",
                     "36px / 18px 下纸形与线条都立得住"],
              stack: .none, cut: 150, gap: 0.9, spec: spec3, rot: 0),
    Candidate(title: "丙 · 后面再露一张",
              note: ["乙的基础上，左上露出 1.4pt 纸边，",
                     "保留“叠”的意思，代价是多一层灰边"],
              stack: .behindUp, cut: 150, gap: 0.9, spec: spec3, rot: 0),
    Candidate(title: "现状 · 线稿",
              note: ["透明底 + 白线，内部全透出背景",
                     "（你说的“跟别人反了”）"],
              stack: .none, cut: 0, gap: 0.9, spec: spec4, isOutline: true)
]

// MARK: - 绘制

func drawCandidate(_ cd: Candidate, scale: CGFloat, color: NSColor) {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: 9, y: 9 + cd.dyShift)
    let hint: CGFloat = scale < 1.5 ? 1.7 : 1.0

    // 与 MenuBarIcon / icongen 同一套：y 为负=向上（card() 内部会翻）
    let front = card(680, cd.rot, 0, 0, 0.068)
    let backUp = card(680, cd.rot, -80, -80, 0.068)     // 丙：左上错位，露一条 L 形纸边
    // 甲：与 MenuBarIcon.swift 出货值一致（缩到 18pt 后把后纸放大到 600、上提 150，
    // 否则 505 在 18pt 上只剩一道发丝，读不出"后面还有纸"）
    let backL = card(600, 9, -130, -150, 0.085)
    let backR = card(600, -9, 130, -150, 0.085)

    if cd.isOutline {
        let cards = [backL, backR, front]
        for (i, c) in cards.enumerated() {
            let p = notePath(c)
            color.withAlphaComponent(i == 2 ? 1 : 0.72).setStroke()
            p.lineWidth = (i == 2 ? 0.62 : 0.48) * hint
            p.stroke()
            if i < cards.count - 1 {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                notePath(cards[i + 1]).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        color.setFill()
        for p in contentShapes(front, cd.spec, bold: 1).filled { p.fill() }
        color.setStroke()
        for p in contentShapes(front, cd.spec, bold: 1).stroked { p.stroke() }
        ctx.restoreGState()
        return
    }

    let gap = cd.gap * hint
    let cut = cd.cut / U

    func fill(_ c: Card, cut: CGFloat = 0) {
        color.setFill()
        notePath(c, cut: cut).fill()
    }
    func knock(_ c: Card) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setStroke()
        let p = notePath(c)
        p.lineWidth = gap * 2
        p.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    func erase(_ p: NSBezierPath, _ width: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setStroke()
        p.lineWidth = width
        p.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    func eraseFill(_ p: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        p.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    switch cd.stack {
    case .none:
        fill(front, cut: cut)
    case .behindUp:
        fill(backUp)
        knock(front); fill(front, cut: cut)
    case .fan:
        fill(backL)
        knock(backR); fill(backR)
        knock(front); fill(front, cut: cut)
    }

    // 纸面内容全部镂空
    let shapes = contentShapes(front, cd.spec, bold: hint)
    for p in shapes.filled { eraseFill(p) }
    for p in shapes.stroked { erase(p, p.lineWidth) }

    ctx.restoreGState()
}

// MARK: - 位图

func bitmap(_ cd: Candidate, px: Int, color: NSColor) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 18
    NSGraphicsContext.current!.cgContext.scaleBy(x: s, y: s)
    drawCandidate(cd, scale: s, color: color)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// 合成带 alpha 的图标：必须走 CGImage。
/// `NSBitmapImageRep.draw(in:)` 会连 alpha 一起整块覆盖，源里透明的地方会把目标写成透明，
/// 结果整片变白 —— 上一版设计稿就是这么翻车的。
func stamp(_ rep: NSBitmapImageRep, in rect: NSRect) {
    guard let cg = rep.cgImage else { return }
    NSGraphicsContext.current!.cgContext.draw(cg, in: rect)
}

func inkRatio(_ cd: Candidate, px: Int) -> Double {
    let r = bitmap(cd, px: px, color: .white)
    var ink = 0
    for y in 0..<px { for x in 0..<px { if (r.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { ink += 1 } } }
    return Double(ink) / Double(px * px)
}

// MARK: - 总览设计稿

let W = 1240, H = 700
let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)

func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: NSColor, bold: Bool = false) {
    let f = bold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size)
    (s as NSString).draw(at: NSPoint(x: x, y: CGFloat(H) - y - size * 1.32),
                         withAttributes: [.font: f, .foregroundColor: c])
}

let ctx = NSGraphicsContext.current!.cgContext
ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor)
ctx.fill(NSRect(x: 0, y: 0, width: W, height: H))

text("便签墙 · 菜单栏图标设计稿 v4（反白实心：纸实心、细节镂空）· 已采用「甲」", 36, 18, 19, .white, bold: true)
text("四个候选都按“实心形状 + 内部镂空”画；最右是现在的线稿，方便对比。",
     36, 46, 12.5, NSColor(white: 0.56, alpha: 1))

var colX: CGFloat = 36
let cw: CGFloat = 288
for cd in candidates {
    text(cd.title, colX, 78, 14.5, cd.isOutline ? NSColor(white: 0.62, alpha: 1) : .white, bold: true)

    // 8x 放大
    ctx.setFillColor(NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1).cgColor)
    ctx.fill(NSRect(x: colX, y: CGFloat(H) - 254, width: 152, height: 152))
    stamp(bitmap(cd, px: 144, color: .white),
          in: NSRect(x: colX + 4, y: CGFloat(H) - 250, width: 144, height: 144))

    // 36px 实际
    text("36px 实际（2x 屏）", colX, 264, 10.5, NSColor(white: 0.48, alpha: 1))
    ctx.setFillColor(NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1).cgColor)
    ctx.fill(NSRect(x: colX, y: CGFloat(H) - 332, width: cw - 40, height: 52))
    for k in 0..<3 {
        stamp(bitmap(cd, px: 36, color: .white),
              in: NSRect(x: colX + 12 + CGFloat(k) * 42, y: CGFloat(H) - 324, width: 36, height: 36))
    }

    // 18px 实际（深 / 浅）
    text("18px 实际（1x 屏）", colX, 338, 10.5, NSColor(white: 0.48, alpha: 1))
    ctx.setFillColor(NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1).cgColor)
    ctx.fill(NSRect(x: colX, y: CGFloat(H) - 394, width: cw - 40, height: 40))
    for k in 0..<4 {
        stamp(bitmap(cd, px: 18, color: .white),
              in: NSRect(x: colX + 20 + CGFloat(k) * 30, y: CGFloat(H) - 385, width: 18, height: 18))
    }
    ctx.setFillColor(NSColor(srgbRed: 0.90, green: 0.90, blue: 0.91, alpha: 1).cgColor)
    ctx.fill(NSRect(x: colX, y: CGFloat(H) - 438, width: cw - 40, height: 40))
    for k in 0..<4 {
        stamp(bitmap(cd, px: 18, color: .black),
              in: NSRect(x: colX + 20 + CGFloat(k) * 30, y: CGFloat(H) - 429, width: 18, height: 18))
    }

    text(cd.note[0], colX, 450, 11.5, NSColor(white: 0.62, alpha: 1))
    text(cd.note[1], colX, 468, 11.5, NSColor(white: 0.62, alpha: 1))
    text(String(format: "覆盖率 %.0f%%", inkRatio(cd, px: 36) * 100), colX, 492, 11,
         NSColor(white: 0.42, alpha: 1))

    colX += 300
}

// 结论区
ctx.setFillColor(NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).cgColor)
ctx.fill(NSRect(x: 36, y: CGFloat(H) - 690, width: CGFloat(W) - 72, height: 170))
text("采用「甲」：三张扇开、前纸 −3.5°，构成与 App 图标同源；落地时后两张从 505 放大到 600、", 52, 544, 12, NSColor(white: 0.78, alpha: 1))
text("上提 150，否则 18pt 上后纸只剩 1px 发丝，被透明缝一切就散成噪点（上面的对比就是证据）。", 52, 566, 12, NSColor(white: 0.78, alpha: 1))
text("代价照实说：18px（1x）下后两张退化成两个纸角、四条字糊成灰带——这是 18 颗像素的物理上限，", 52, 596, 12, NSColor(white: 0.78, alpha: 1))
text("36px（2x，所有 Retina 屏）下三张纸、勾选框、四条线都清楚。", 52, 616, 12, NSColor(white: 0.78, alpha: 1))
text("共同点（对齐系统图标的关系）：白纸实心为底，勾选框 / 四行字 / 纸间缝隙全部镂空透明。", 52, 644, 12, NSColor(white: 0.62, alpha: 1))
text("模板图说明：位图只有 alpha 起作用，系统按菜单栏明暗自动反白，所以深色栏是白纸、浅色栏是黑纸。", 52, 666, 12, NSColor(white: 0.45, alpha: 1))

NSGraphicsContext.restoreGraphicsState()
try! sheet.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "shots/menubar/design-fill-sheet.png"))

// MARK: - 像素级真机对照（36px→4x，18px→8x，最近邻）

let PW = 4 * 176, PH = 2 * 190
let real = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: PW, pixelsHigh: PH,
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                            isPlanar: false, colorSpaceName: .deviceRGB,
                            bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: real)
let rc = NSGraphicsContext.current!.cgContext
rc.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor)
rc.fill(NSRect(x: 0, y: 0, width: PW, height: PH))
rc.interpolationQuality = .none
for (i, cd) in candidates.enumerated() {
    let x = CGFloat(4 + i * 176)
    rc.setFillColor(NSColor(srgbRed: 0.21, green: 0.21, blue: 0.22, alpha: 1).cgColor)
    rc.fill(NSRect(x: x, y: CGFloat(PH) - 182, width: 168, height: 178))
    stamp(bitmap(cd, px: 36, color: .white),
          in: NSRect(x: x + 12, y: CGFloat(PH) - 170, width: 144, height: 144))
    rc.setFillColor(NSColor(srgbRed: 0.21, green: 0.21, blue: 0.22, alpha: 1).cgColor)
    rc.fill(NSRect(x: x, y: 8, width: 168, height: 178))
    stamp(bitmap(cd, px: 18, color: .white),
          in: NSRect(x: x + 12, y: 20, width: 144, height: 144))
}
NSGraphicsContext.restoreGraphicsState()
try! real.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "shots/menubar/design-fill-real.png"))

print("wrote shots/menubar/design-fill-sheet.png \(W)x\(H)")
print("wrote shots/menubar/design-fill-real.png  \(PW)x\(PH)")
