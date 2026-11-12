import SwiftUI
import AppKit

// MARK: - 刘海入口
//
// 形态（PRD §2.4）：
// - 收起：面板与物理刘海严格同宽同位，**一个像素都不画**（刘海的黑是硬件，不需要补）。
// - 悬停展开：向两侧长出黑色两翼，两个入口贴在刘海两侧外 12pt（新建 / 打开）。
// - 点击展开（阶段③，尚未接线）：等比放大的同一块刘海 —— 宽高比锁定为物理刘海的
//   宽高比，圆角按同一比例放大，看上去是「刘海变大了」而不是「刘海下面鼓了个包」。
//   比例规则见 NotchGeometry.equalRatioPanel(scale:)：只允许等比，不允许自由拉伸。
//
// 刘海边界从 NSScreen.auxiliaryTopLeftArea / auxiliaryTopRightArea 读出（不同机型
// 150~200pt，不许写死常量）。悬停用 NSTrackingArea，不需要辅助功能/屏幕录制权限。

// MARK: - 几何

/// 物理刘海在屏幕坐标系中的水平范围（全局坐标，原点在主屏左下）
struct NotchGeometry {
    var leftX: CGFloat      // 刘海左边界
    var rightX: CGFloat     // 刘海右边界
    var height: CGFloat     // 刘海高度（= 顶部安全区）

    var width: CGFloat { max(0, rightX - leftX) }
    var centerX: CGFloat { (leftX + rightX) / 2 }

    /// 刘海本身的形状比例。它是这块硬件的「身份」，放大时只有保持它才不像另一个东西。
    var aspectRatio: CGFloat { height > 0 ? width / height : 0 }

    // 两翼布局常量
    static let clearance: CGFloat = 12      // 入口距刘海边缘的净距
    static let edgeGap: CGFloat = 10        // 入口距面板左右边缘
    static let buttonW: CGFloat = 68        // 单个入口最小宽度
    static let buttonH: CGFloat = 26

    /// 收起宽度严格等于刘海宽度：每多出 1pt，那 1pt 就压在菜单栏上，
    /// 会把原生圆角刘海显示成直角黑条（v0.2 的真实 bug）。
    var collapsedWidth: CGFloat { width }

    /// 展开宽度 = 刘海 + 两侧（净距 + 入口 + 边距）
    var expandedWidth: CGFloat { width + 2 * (Self.clearance + Self.buttonW + Self.edgeGap) }

    /// 面板局部坐标（左上原点）里刘海所占的水平区间
    func notchSpan(inPanelWidth panelW: CGFloat) -> (minX: CGFloat, maxX: CGFloat) {
        let x = (panelW - width) / 2
        return (x, x + width)
    }

    /// 两个入口的矩形，**x 用屏幕全局坐标**（这样能直接和物理刘海的全局区间比净距，
    /// 不必先把两者换算到同一个坐标系）；y 是面板局部坐标（顶部为 0）。
    /// panelWidth 只用来确认面板宽度与布局一致，横向位置完全由刘海边界推导。
    func buttonRects(panelWidth panelW: CGFloat) -> (left: CGRect, right: CGRect) {
        let y = (height - Self.buttonH) / 2
        let expected = width + 2 * (Self.clearance + Self.buttonW + Self.edgeGap)
        assert(abs(panelW - expected) < 0.5, "面板宽度与两翼布局不一致：\(panelW) vs \(expected)")
        return (CGRect(x: leftX - Self.clearance - Self.buttonW, y: y,
                       width: Self.buttonW, height: Self.buttonH),
                CGRect(x: rightX + Self.clearance, y: y,
                       width: Self.buttonW, height: Self.buttonH))
    }

    /// 点击态候选：等比放大的刘海（PRD §9.1④）。
    /// - 宽 = 刘海宽 × scale，高 = 宽 ÷ 刘海宽高比（即高 = 刘海高 × scale）。
    /// - 圆角同比例放大，所以轮廓是同一形状，只是尺寸变了。
    /// 只允许等比：1.05~1.2× 这种「略宽一点」会读成画歪了。
    func equalRatioPanel(scale: CGFloat) -> (width: CGFloat, height: CGFloat, radius: CGFloat) {
        let w = width * scale
        let h = height * scale
        // 物理刘海下圆角约 9pt（185pt 宽时），比例约 0.28 × 高度
        return (w, h, (h * 0.28).rounded())
    }
}

enum NotchMetrics {
    /// 从系统读取刘海的真实几何；无刘海屏返回 nil
    static func geometry(for screen: NSScreen) -> NotchGeometry? {
        guard screen.safeAreaInsets.top > 0 else { return nil }
        let h = max(screen.safeAreaInsets.top, 26)
        // auxiliaryTopLeftArea / RightArea 是刘海两侧可用的菜单栏区域
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, r.minX > l.maxX {
            return NotchGeometry(leftX: l.maxX, rightX: r.minX, height: h)
        }
        // 兜底：按常见宽度估算
        let w: CGFloat = 185
        return NotchGeometry(leftX: screen.frame.midX - w / 2,
                             rightX: screen.frame.midX + w / 2,
                             height: h)
    }
}

// MARK: - 像素断言（给自检用）

enum NotchPixel {
    /// 统计渲染结果里「可见」的像素数（alpha > 2）。
    /// 用来把「收起态不许画任何东西」变成可执行断言，而不是靠截图肉眼看。
    static func countVisible(_ image: CGImage) -> Int {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return 0 }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress,
                                      width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return -1 }
        var n = 0
        for i in stride(from: 3, to: data.count, by: 4) where data[i] > 2 { n += 1 }
        return n
    }
}

// MARK: - 等比放大候选图（给设计对照，不参与运行）

@MainActor
enum NotchRatioPreview {
    /// 候选放大倍数：1× 是物理刘海本身（基准）
    static let scales: [CGFloat] = [1.0, 1.5, 2.0, 2.5]

    /// 按真实屏幕宽度作画，形状与屏幕的比例才是真的（否则面板会显得夸张地大）
    static func render(geometry g: NotchGeometry, screenWidth: CGFloat, to path: String) -> Bool {
        guard g.width > 0, g.height > 0, screenWidth > 0 else { return false }
        let pad: CGFloat = 30
        let W = screenWidth + pad * 2

        func blockHeight(_ s: CGFloat) -> CGFloat { g.equalRatioPanel(scale: s).height + 40 }
        let headerH: CGFloat = 66
        let H = headerH + scales.reduce(0) { $0 + blockHeight($1) } + 10

        let canvas = NSImage(size: NSSize(width: W, height: H))
        canvas.lockFocus()
        NSColor(srgbRed: 0.984, green: 0.976, blue: 0.965, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()

        let ink = NSColor(srgbRed: 0.15, green: 0.14, blue: 0.13, alpha: 1)
        let sub = NSColor(srgbRed: 0.45, green: 0.43, blue: 0.41, alpha: 1)

        ("点击态：等比放大 —— 宽高比锁死物理刘海，只是尺寸变大" as NSString)
            .draw(at: NSPoint(x: pad, y: H - 32), withAttributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: ink])
        (String(format: "基准 %.0f × %.0f（比例 %.2f : 1）· 圆角按同比例放大 · 灰线为屏幕宽 %.0f",
                g.width, g.height, g.aspectRatio, screenWidth) as NSString)
            .draw(at: NSPoint(x: pad, y: H - 52), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .regular), .foregroundColor: sub])

        /// 顶边贴住屏幕、只有下两角圆的「垂下来」形状
        func hangingShape(width w: CGFloat, height h: CGFloat, radius r: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: h))
            p.line(to: NSPoint(x: 0, y: r))
            p.appendArc(withCenter: NSPoint(x: r, y: r), radius: r, startAngle: 180, endAngle: 270)
            p.line(to: NSPoint(x: w - r, y: 0))
            p.appendArc(withCenter: NSPoint(x: w - r, y: r), radius: r, startAngle: 270, endAngle: 360)
            p.line(to: NSPoint(x: w, y: h))
            p.close()
            return p
        }

        var top = H - headerH
        for s in scales {
            let p = g.equalRatioPanel(scale: s)
            let stripY = top - g.height
            let strip = NSRect(x: pad, y: stripY, width: screenWidth, height: g.height)
            NSGradient(colors: [
                NSColor(srgbRed: 0.945, green: 0.925, blue: 0.898, alpha: 1),
                NSColor(srgbRed: 0.902, green: 0.876, blue: 0.846, alpha: 1)
            ])?.draw(in: strip, angle: -90)

            // 菜单栏项目的占位块：用来判断面板向两侧吃掉多少菜单栏空间
            let itemY = stripY + (g.height - 7) / 2
            func menuItem(_ x: CGFloat, _ w: CGFloat) {
                NSColor(srgbRed: 0.42, green: 0.40, blue: 0.37, alpha: 0.22).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: itemY, width: w, height: 7),
                             xRadius: 3.5, yRadius: 3.5).fill()
            }
            var x = pad + 16
            for w in [26, 34, 20, 30, 22, 28] { menuItem(x, CGFloat(w)); x += CGFloat(w) + 12 }
            x = pad + screenWidth - 16
            for w in [18, 10, 22, 10, 26, 12, 20, 10, 16] { x -= CGFloat(w); menuItem(x, CGFloat(w)); x -= 12 }

            let cx = strip.midX
            let shapeTop = stripY + g.height        // 形状从菜单栏底沿继续向下
            let shape = hangingShape(width: p.width, height: p.height, radius: p.radius)
            shape.transform(using: AffineTransform(translationByX: cx - p.width / 2,
                                                   byY: shapeTop - p.height))
            NSColor.black.setFill()
            shape.fill()

            let ratio = p.width / screenWidth * 100
            let caption = String(format: "%.1f×   %d × %d      占屏宽 %.0f%%",
                                 s, Int(p.width.rounded()), Int(p.height.rounded()), ratio)
            (caption as NSString).draw(at: NSPoint(x: pad, y: shapeTop - p.height - 19),
                                       withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 0.36, green: 0.34, blue: 0.32, alpha: 1)])
            top -= blockHeight(s)
        }

        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? data.write(to: URL(fileURLWithPath: path))
        return true
    }
}

// MARK: - 模型 / 面板 / 控制器

@MainActor
final class NotchModel: ObservableObject {
    @Published var isExpanded = false
    @Published var notchWidth: CGFloat = 185
    var onNewNote: (() -> Void)?
    var onOpenWall: (() -> Void)?
}

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 悬停探测：面板随时重排，用 inVisibleRect 让跟踪区跟随 bounds
final class NotchTrackingContainer: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

@MainActor
final class NotchController {
    static let shared = NotchController()

    private var panel: NotchPanel?
    private var screen: NSScreen?
    private var geometry: NotchGeometry?
    private var collapseWork: DispatchWorkItem?
    private let model = NotchModel()
    private(set) var isExpanded = false

    func install() {
        guard panel == nil,
              let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let g = NotchMetrics.geometry(for: s) else { return }
        screen = s
        geometry = g
        model.notchWidth = g.width

        model.onNewNote = { [weak self] in
            self?.collapseNow()
            CaptureController.shared.show()
        }
        model.onOpenWall = { [weak self] in
            self?.collapseNow()
            AppDelegate.bringWallToFront()
        }

        let container = NotchTrackingContainer()
        container.onEnter = { [weak self] in self?.hoverEnter() }
        container.onExit = { [weak self] in self?.hoverExit() }

        let host = NSHostingView(rootView: NotchContentView(model: model))
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        let p = NotchPanel()
        p.contentView = container
        p.setFrame(frame(expanded: false), display: false)
        panel = p
        p.orderFrontRegardless()
    }

    // MARK: 悬停

    func hoverEnter() {
        collapseWork?.cancel()
        collapseWork = nil
        if !isExpanded { apply(true) }
    }

    func hoverExit() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply(false) }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func collapseNow() { apply(false) }

    // MARK: 布局

    /// 两翼：以刘海中心为锚横向加宽，纵向不动（顶端贴住屏幕顶边）
    private func frame(expanded: Bool) -> NSRect {
        guard let s = screen, let g = geometry else { return .zero }
        let w = expanded ? g.expandedWidth : g.collapsedWidth
        return NSRect(x: g.centerX - w / 2,
                      y: s.frame.maxY - g.height,
                      width: w, height: g.height)
    }

    private func apply(_ expanded: Bool) {
        isExpanded = expanded
        model.isExpanded = expanded
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            p.animator().setFrame(frame(expanded: expanded), display: true)
        }
    }
}

// MARK: - 界面

struct NotchContentView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 0) {
            notchButton("plus", label: "新建", action: model.onNewNote)
            // 中间留出刘海本身的宽度 + 两侧净距：入口被布局顶到刘海之外，
            // 而不是靠坐标碰巧避开（物理刘海宽度随机型变化）。
            Spacer(minLength: model.notchWidth + 2 * NotchGeometry.clearance)
            notchButton("rectangle.stack", label: "打开", action: model.onOpenWall)
        }
        .padding(.horizontal, NotchGeometry.edgeGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // 只有展开时才画黑：收起态窗口就落在物理刘海范围内，
            // 那里的黑是硬件，我们再画一层就是给刘海描了道直角边。
            UnevenRoundedRectangle(bottomLeadingRadius: 14,
                                   bottomTrailingRadius: 14,
                                   style: .continuous)
                .fill(Color.black)
                .opacity(model.isExpanded ? 1 : 0)
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: model.isExpanded)
    }

    private func notchButton(_ symbol: String, label: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .frame(width: NotchGeometry.buttonW, height: NotchGeometry.buttonH)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain).handCursor()
        // 收起态必须零像素：不画黑的同时也不画按钮
        .scaleEffect(model.isExpanded ? 1 : 0.7)
        .opacity(model.isExpanded ? 1 : 0)
        .help(label == "新建" ? "新建便签" : "打开便签墙")
    }
}
