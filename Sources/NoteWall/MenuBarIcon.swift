import AppKit

/// 菜单栏图标：与 App 图标同构的「白纸实心 + 内部镂空」版（方案甲）。
///
/// 关系跟系统其它菜单栏图标一致：**形状是实心的，细节是挖空的**。
/// （之前做反了——形状是透明轮廓、线条是白的，所以在菜单栏里像一层薄薄的线框。）
///
/// 几何照搬 `tools/icongen.swift`（1024 画布）：
///   前纸 680 / +3.5°、左纸 505 / 12° / x−148、右纸 505 / −11° / x+148，
///   两张侧纸一起上提（−150 / −138），比 App 图标提得多一点，
///   否则被前纸盖住、18pt 上看不见「三张」。
///
/// 三层关系靠 `.destinationOut` 擦出一条透明缝做出遮挡：
///   画左纸 → 沿右纸擦缝 → 画右纸 → 沿前纸擦缝 → 画前纸 → 挖掉纸面内容。
///
/// 为什么是模板图（`isTemplate = true`）：菜单栏图标都是单色的，系统按明暗自动反色。
///
/// 字形已换代（设计稿 V1：单张便签 + 微笑 + 简化图钉）：`make()` 优先加载包内位图资源
/// （`StickySideMenuBar.png` / `@2x`），资源缺失时回退到本文件的代码绘制（三纸字形）。
/// 位图里只有 alpha 起作用，所以深色栏是白纸、浅色栏是黑纸。
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    // MARK: 几何（1024 空间 → 18pt）

    /// 每 pt 对应的 1024 空间单位
    private static let unit: CGFloat = 1024.0 / 18.0

    struct Card {
        var side: CGFloat      // 18pt 单位
        var rot: CGFloat       // AppKit 角度（逆时针为正）
        var dx: CGFloat
        var dy: CGFloat
        var corner: CGFloat
    }

    static func card(side: CGFloat, rot: CGFloat, x: CGFloat, y: CGFloat,
                     cornerRatio: CGFloat) -> Card {
        let s = side / unit
        return Card(side: s, rot: rot,
                    dx: x / unit, dy: -y / unit,      // icongen 的 y 向下，这里翻成向上
                    corner: s * cornerRatio)
    }

    /// 前纸：680 / +3.5°
    static let frontCard = card(side: 680, rot: 3.5, x: 0, y: 0, cornerRatio: 0.068)
    /// 左：600 / +9°，x −130、上提 150
    static let leftCard = card(side: 600, rot: 9, x: -130, y: -150, cornerRatio: 0.085)
    /// 右：600 / −9°，x +130、上提 150（与左镜像，两侧露出的宽度才对得上）
    static let rightCard = card(side: 600, rot: -9, x: 130, y: -150, cornerRatio: 0.085)

    /// 纸间透明缝（pt）。3.5° 斜边会被抗锯齿吃掉一点，0.9 是放大核对过的最小可读值。
    private static let gap: CGFloat = 0.85

    /// 构图整体上移一点，让三张纸在 18×18 里居中（前纸本身压得偏下）
    private static let dyShift: CGFloat = -0.6

    /// 纸面内容比例（相对前纸宽度），与 App 图标同一套
    private struct Content {
        var lens: [CGFloat] = [0.46, 0.44, 0.34, 0.26]
        var barH: CGFloat = 0.055
        var gap: CGFloat = 0.072
        var box: CGFloat = 0.125
        var pad: CGFloat = 0.135
    }
    private static let content = Content()

    // MARK: - 输出

    /// 优先用设计稿位图（V1 字形）；资源不在包里时（裸跑测试等）回退代码绘制，任何环境都有图标
    static func make() -> NSImage {
        if let image = resourceImage() { return image }
        let image = NSImage(size: size)
        for scale in [CGFloat(1), 2, 3] {
            if let rep = bitmap(scale: scale) {
                rep.size = size
                image.addRepresentation(rep)
            }
        }
        image.isTemplate = true
        image.accessibilityDescription = "随手贴"
        return image
    }

    /// 设计稿模板图：18pt 的 1x / 2x 两档位图，Bundle 里齐全才用
    /// 位图一律走 Data + NSBitmapImageRep(data:)：contentsOf: 便捷初始化在 CI 的 SDK 上不存在（0.2.6 首构建实锤）。
    private static func resourceImage() -> NSImage? {
        guard let p1 = Bundle.main.path(forResource: "StickySideMenuBar", ofType: "png"),
              let p2 = Bundle.main.path(forResource: "StickySideMenuBar@2x", ofType: "png"),
              let d1 = try? Data(contentsOf: URL(fileURLWithPath: p1)),
              let d2 = try? Data(contentsOf: URL(fileURLWithPath: p2)),
              let rep1 = NSBitmapImageRep(data: d1),
              let rep2 = NSBitmapImageRep(data: d2) else { return nil }
        rep1.size = size
        rep2.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep1)
        image.addRepresentation(rep2)
        image.isTemplate = true
        image.accessibilityDescription = "随手贴"
        return image
    }

    static func bitmap(scale: CGFloat) -> NSBitmapImageRep? {
        bitmap(scale: scale) { _ in drawGlyph(scale: scale) }
    }

    /// 测试用：在同样的上下文设置下画任意内容
    static func bitmap(scale: CGFloat, drawing: (CGContext) -> Void) -> NSBitmapImageRep? {
        let px = Int((size.width * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        drawing(NSGraphicsContext.current!.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - 形状

    private static func notePath(_ c: Card) -> NSBezierPath {
        let s = c.side, r = max(0.35, c.corner)
        let x0 = -s / 2, x1 = s / 2, y0 = -s / 2, y1 = s / 2
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x0 + r, y: y1))
        p.line(to: NSPoint(x: x1 - r, y: y1))
        p.appendArc(withCenter: NSPoint(x: x1 - r, y: y1 - r), radius: r,
                    startAngle: 90, endAngle: 0, clockwise: true)
        p.line(to: NSPoint(x: x1, y: y0 + r))
        p.appendArc(withCenter: NSPoint(x: x1 - r, y: y0 + r), radius: r,
                    startAngle: 0, endAngle: -90, clockwise: true)
        p.line(to: NSPoint(x: x0 + r, y: y0))
        p.appendArc(withCenter: NSPoint(x: x0 + r, y: y0 + r), radius: r,
                    startAngle: 270, endAngle: 180, clockwise: true)
        p.line(to: NSPoint(x: x0, y: y1 - r))
        p.appendArc(withCenter: NSPoint(x: x0 + r, y: y1 - r), radius: r,
                    startAngle: 180, endAngle: 90, clockwise: true)
        p.close()
        p.transform(using: AffineTransform(rotationByDegrees: c.rot))
        p.transform(using: AffineTransform(translationByX: c.dx, byY: c.dy))
        return p
    }

    /// 纸面内容（勾选框 + 勾 + 四条横线），坐标已随前纸旋转平移。
    /// 排版跟 App 图标一致：**从顶边往下排**，内边距 0.135w，下方留白约 35%
    /// （App 图标里也是上紧下松，不是垂直居中）。
    private static func contentShapes(bold: CGFloat, on card: Card = frontCard) -> (stroked: [NSBezierPath], filled: [NSBezierPath]) {
        let c = card
        let w = c.side
        let pad = w * content.pad
        let box = w * content.box
        let barH = w * content.barH * bold
        let rowGap = w * content.gap * bold

        let left = -w / 2 + pad
        let top = w / 2 - pad

        var stroked: [NSBezierPath] = []
        var filled: [NSBezierPath] = []

        let cb = NSBezierPath(roundedRect: NSRect(x: left, y: top - box, width: box, height: box),
                              xRadius: box * 0.28, yRadius: box * 0.28)
        cb.lineWidth = max(box * 0.12, 0.45) * bold
        stroked.append(cb)

        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: left + box * 0.27, y: top - box * 0.53))
        tick.line(to: NSPoint(x: left + box * 0.44, y: top - box * 0.70))
        tick.line(to: NSPoint(x: left + box * 0.74, y: top - box * 0.33))
        tick.lineWidth = max(box * 0.12, 0.45) * bold
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        stroked.append(tick)

        // 第一行：跟勾选框同一行，在它右边
        filled.append(NSBezierPath(roundedRect: NSRect(x: left + box + w * 0.055,
                                                       y: top - box / 2 - barH / 2,
                                                       width: w * content.lens[0], height: barH),
                                   xRadius: barH / 2, yRadius: barH / 2))
        // 后面三行，从左边缘起
        var y = top - box - rowGap * 0.9 - barH
        for len in content.lens.dropFirst() {
            filled.append(NSBezierPath(roundedRect: NSRect(x: left, y: y, width: w * len, height: barH),
                                       xRadius: barH / 2, yRadius: barH / 2))
            y -= (barH + rowGap)
        }

        let r = AffineTransform(rotationByDegrees: c.rot)
        let t = AffineTransform(translationByX: c.dx, byY: c.dy)
        for p in stroked { p.transform(using: r); p.transform(using: t) }
        for p in filled { p.transform(using: r); p.transform(using: t) }
        return (stroked, filled)
    }

    // MARK: - 绘制

    private static func fill(_ path: NSBezierPath, color: NSColor) {
        color.setFill()
        path.fill()
    }

    /// 沿路径擦一圈，宽度 = 2×gap（一半在里、一半在外），留下 gap 宽的透明缝
    private static func eraseOutline(_ path: NSBezierPath, width: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setStroke()
        path.lineWidth = width
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func eraseFill(_ path: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func eraseStroke(_ path: NSBezierPath, width: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setStroke()
        path.lineWidth = width
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 在 18×18 坐标系里绘制（原点左下）。
    /// `scale` 只用来做 1x 下的「hinting」：18px 时 0.9pt 的缝和 1px 的横线会糊成灰，
    /// 加粗一档才立得住。
    static func drawGlyph(scale: CGFloat = 2) {
        // 1x 只有 18 颗像素：横线不加粗就被抗锯齿抹平；缝加太粗又会把两侧的纸吃光，
        // 1.2 / 1.5 是逐组渲染对比出来的一组：纸形完整、四行线还分得开。
        if scale < 1.5 {
            drawGlyph(gapHint: 1.2, contentHint: 1.5)
        } else {
            drawGlyph(gapHint: 1, contentHint: 1)
        }
    }

    /// 测试用：单独指定两个 hint，方便在 18px 下挑参数
    static func drawGlyph(gapHint: CGFloat, contentHint: CGFloat) {
        drawGlyph(left: leftCard, right: rightCard, front: frontCard,
                  gap: gap * gapHint, contentHint: contentHint)
    }

    /// 诊断用：任意三张纸 + 任意缝宽
    static func drawGlyph(left: Card, right: Card, front: Card,
                          gap seam: CGFloat, contentHint: CGFloat) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.translateBy(x: size.width / 2, y: size.height / 2 + dyShift)
        let ink = NSColor.black

        // 三张纸：后画的压住先画的，压之前沿自己的轮廓擦一条缝
        fill(notePath(left), color: ink)
        eraseOutline(notePath(right), width: seam * 2)
        fill(notePath(right), color: ink)
        eraseOutline(notePath(front), width: seam * 2)
        fill(notePath(front), color: ink)

        // 纸面内容全部镂空（跟系统图标一样：细节是孔，不是线）
        let shapes = contentShapes(bold: contentHint, on: front)
        for p in shapes.filled { eraseFill(p) }
        for p in shapes.stroked { eraseStroke(p, width: p.lineWidth) }
    }

    // MARK: - 取证工具（测试用）

    struct Metrics {
        var coverage: Double
        var bbox: CGRect
        var opaqueCorners: Int
    }

    /// 覆盖率 / 墨迹包围盒 / 四角是否不透明
    static func measure(_ rep: NSBitmapImageRep, scale: CGFloat) -> Metrics {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        var ink = 0
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if a > 0.5 {
                    ink += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
            .filter { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.1 }.count
        let box = maxX < 0
            ? .zero
            : CGRect(x: CGFloat(minX) / scale, y: CGFloat(h - 1 - maxY) / scale,
                     width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        return Metrics(coverage: Double(ink) / Double(w * h), bbox: box, opaqueCorners: corners)
    }

    /// 某块区域里有墨的像素数（坐标是设计坐标，原点左下）
    static func ink(in rep: NSBitmapImageRep, rect: NSRect, scale: CGFloat) -> Int {
        var count = 0
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let x1 = min(rep.pixelsWide - 1, Int((rect.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((CGFloat(rep.pixelsHigh) - rect.maxY * scale).rounded(.down)))
        let y1 = min(rep.pixelsHigh - 1, Int((CGFloat(rep.pixelsHigh) - rect.minY * scale).rounded(.up)))
        guard x1 >= x0, y1 >= y0 else { return 0 }
        for y in y0...y1 {
            for x in x0...x1 {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 { count += 1 }
            }
        }
        return count
    }

    /// 某块区域里**透明**的像素数（用来证明纸面是实心的、以及内容确实被挖空了）
    static func holes(in rep: NSBitmapImageRep, rect: NSRect, scale: CGFloat) -> Int {
        var count = 0
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let x1 = min(rep.pixelsWide - 1, Int((rect.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((CGFloat(rep.pixelsHigh) - rect.maxY * scale).rounded(.down)))
        let y1 = min(rep.pixelsHigh - 1, Int((CGFloat(rep.pixelsHigh) - rect.minY * scale).rounded(.up)))
        guard x1 >= x0, y1 >= y0 else { return 0 }
        for y in y0...y1 {
            for x in x0...x1 {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) < 0.25 { count += 1 }
            }
        }
        return count
    }

    /// 区域像素总数（配合 ink / holes 算比例）
    static func area(_ rep: NSBitmapImageRep, rect: NSRect, scale: CGFloat) -> Int {
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let x1 = min(rep.pixelsWide - 1, Int((rect.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((CGFloat(rep.pixelsHigh) - rect.maxY * scale).rounded(.down)))
        let y1 = min(rep.pixelsHigh - 1, Int((CGFloat(rep.pixelsHigh) - rect.minY * scale).rounded(.up)))
        guard x1 >= x0, y1 >= y0 else { return 0 }
        return (x1 - x0 + 1) * (y1 - y0 + 1)
    }

    /// 某个设计坐标点的 alpha
    static func alpha(in rep: NSBitmapImageRep, at p: NSPoint, scale: CGFloat) -> Double {
        let x = Int((p.x * scale).rounded())
        let y = rep.pixelsHigh - 1 - Int((p.y * scale).rounded())
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return 0 }
        return Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
    }
}
