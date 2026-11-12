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
//
// v0.2.2 悬停改版（Carry 定案）：悬停不再只是横向变宽，而是长成一张垂落卡片——
// 第一排仍是刘海两侧的新建 / 打开（位置由几何推导：按钮正落在刘海两侧外 clearance
// 处，与 buttonRects 的全局矩形一致，不靠布局碰巧），下方加最近便签列表：置顶优先、
// 最近修改补位（与边缘条同一套展示规则），最多 5 条，锁定便签不出现（与边缘条一致）。
// 比例：卡宽取刘海宽的 2 倍；顶部两肩贴合圆角、底部大圆角沿用刘海自身的半径比例，
// 让卡片读起来仍是「刘海长大了」。完全等比只适用于无内容的点击态——装下 5 条便签
// 需要约 250pt 高，等比放大到这个高度宽度会超过 1300pt，不成立；NotchNook、
// Boring Notch 等同类产品的展开面板同样是「顶部贴合刘海 + 圆角成比例 + 身体按内容长高」。
//
// v0.2.3 行操作与详情（Carry 验收 0.2.2 后定案）：每行悬停浮现复制 / 删除两个按钮
// （编辑不设按钮——点行本身就是打开这条）；点行在面板内切到详情页（正文全显、
// 清单可打勾、底部复制 / 在墙中打开 / 删除），深度编辑经 AppContext 旗子跳墙内
// 现成的 NoteDetailSheet。顺带修 0.2.2 两处：行背景未拉满卡宽、清单行首标记未剥净。



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

    // v0.2.2 卡片布局常量
    static let cardBottomRadius: CGFloat = 18   // 垂落卡片的下圆角（刘海半径比例的平移）
    static let shoulderRadius: CGFloat = 10     // 卡片顶部两肩的贴合圆角
    static let rowH: CGFloat = 38               // 最近便签单行高度
    static let maxListNotes = 5                 // 刘海列表最多显示条数
    static let detailHeight: CGFloat = 400      // 详情页展开高度（内容在内部滚动）

    /// 展开卡片宽度：刘海宽的 2 倍（比例锚点），下限 360，上限屏幕宽 − 24
    func cardWidth(screenWidth: CGFloat) -> CGFloat {
        min(max(width * 2, 360), max(360, screenWidth - 24))
    }

    /// 最近便签区高度：0 条时整区不存在（面板回到只有按钮带的形态）
    static func notesSectionHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return 8 + CGFloat(count) * rowH + CGFloat(count - 1) * 2 + 10
    }

    /// 展开总高度 = 刘海高（按钮带）+ 便签区
    func expandedHeight(noteCount: Int) -> CGFloat {
        height + Self.notesSectionHeight(count: noteCount)
    }

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

// MARK: - 最近便签（刘海列表）

/// 刘海列表的选签规则，与边缘条同一套展示逻辑（池子定义同 Store.edgeNotes）：
/// 未删除、未锁定；置顶（isPinned）排前面，组内按最近修改倒序，合起来取前 limit 条。
enum NotchNotes {
    static func top(_ notes: [Note], limit: Int = NotchGeometry.maxListNotes) -> [Note] {
        let pool = notes.filter { $0.deletedAt == nil && !$0.isLocked }
        let pinned = pool.filter { $0.isPinned }.sorted { $0.updatedAt > $1.updatedAt }
        let rest = pool.filter { !$0.isPinned }.sorted { $0.updatedAt > $1.updatedAt }
        return Array((pinned + rest).prefix(limit))
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
    @Published var notchHeight: CGFloat = 32
    @Published var cardWidth: CGFloat = 370
    @Published var notes: [Note] = []
    var onNewNote: (() -> Void)?
    var onOpenWall: (() -> Void)?
    var onOpenNote: ((Note) -> Void)?
    @Published var detailNote: Note? = nil
    var onCloseDetail: (() -> Void)?
    var onCopyNote: ((Note) -> NoteCopy.Result)?
    var onDeleteNote: ((Note) -> Void)?
    var onTogglePinNote: ((Note) -> Void)?
    var onToggleCheck: ((Note, Int) -> Void)?
    var onOpenInWall: ((Note) -> Void)?
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
    private weak var store: AppStore?
    private(set) var isExpanded = false

    func install(store: AppStore) {
        guard panel == nil,
              let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let g = NotchMetrics.geometry(for: s) else { return }
        screen = s
        geometry = g
        self.store = store
        model.notchWidth = g.width
        model.notchHeight = g.height
        model.cardWidth = g.cardWidth(screenWidth: s.frame.width)

        model.onNewNote = { [weak self] in
            self?.collapseNow()
            CaptureController.shared.show()
        }
        model.onOpenWall = { [weak self] in
            self?.collapseNow()
            AppDelegate.bringWallToFront()
        }
        model.onOpenNote = { [weak self] note in
            guard let self else { return }
            // 用 store 里的最新副本（列表只是快照，可能已旧）
            self.model.detailNote = self.store?.notes.first(where: { $0.id == note.id }) ?? note
            self.apply(true)
        }
        model.onCloseDetail = { [weak self] in
            guard let self else { return }
            self.model.detailNote = nil
            self.apply(true)
        }
        model.onCopyNote = { note in NoteCopy.copy(note) }
        model.onDeleteNote = { [weak self] note in
            guard let self else { return }
            self.store?.delete(note.id)
            if self.model.detailNote?.id == note.id { self.model.detailNote = nil }
            self.refreshNotes()
            if self.isExpanded { self.apply(true) }
        }
        model.onTogglePinNote = { [weak self] note in
            self?.store?.togglePin(note.id)
            self?.refreshNotes()
        }
        model.onToggleCheck = { [weak self] note, itemID in
            guard let self else { return }
            self.store?.toggleCheck(noteID: note.id, itemID: itemID)
            // 详情页拿的是副本：勾选后把最新状态同步回去（高度不变，不必重排 frame）
            if let fresh = self.store?.notes.first(where: { $0.id == note.id }),
               self.model.detailNote != fresh {
                self.model.detailNote = fresh
            }
            self.refreshNotes()
        }
        model.onOpenInWall = { [weak self] note in
            // 与菜单栏「设置…」同一套旗子 + 通知机制：窗口在就直接弹，
            // 窗口是刚重建的就靠 WallView 的 onAppear 消费旗子
            AppContext.shared.pendingDetailNoteID = note.id
            NotificationCenter.default.post(name: .noteWallOpenDetail, object: nil)
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
        refreshNotes()
        if !isExpanded { apply(true) }
    }

    /// 每次展开前现算列表：面板高度由条数决定，必须在改 frame 之前拿到
    private func refreshNotes() {
        model.notes = NotchNotes.top(store?.notes ?? [])
    }

    func hoverExit() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply(false) }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func collapseNow() { apply(false) }

    // MARK: 布局

    /// 展开：以刘海中心为锚长成垂落卡片（宽 = 刘海 2 倍，高 = 刘海高 + 便签区）；
    /// 收起：回到与刘海严格同宽同高。顶端始终贴住屏幕顶边。
    private func frame(expanded: Bool) -> NSRect {
        guard let s = screen, let g = geometry else { return .zero }
        let w = expanded ? g.cardWidth(screenWidth: s.frame.width) : g.collapsedWidth
        let h: CGFloat
        if !expanded { h = g.height }
        else if model.detailNote != nil { h = NotchGeometry.detailHeight }
        else { h = g.expandedHeight(noteCount: model.notes.count) }
        return NSRect(x: g.centerX - w / 2,
                      y: s.frame.maxY - h,
                      width: w, height: h)
    }

    private func apply(_ expanded: Bool) {
        isExpanded = expanded
        if !expanded { model.detailNote = nil }
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

struct NotchListView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(spacing: 0) {
            // 按钮带：高度严格等于刘海高。左右留白由几何算出，按钮正落在刘海
            // 两侧外 clearance 处（与 buttonRects 的全局推导一致），不多不少。
            HStack(spacing: 0) {
                notchButton("plus", label: "新建", action: model.onNewNote)
                Spacer(minLength: model.notchWidth + 2 * NotchGeometry.clearance)
                notchButton("rectangle.stack", label: "打开", action: model.onOpenWall)
            }
            .padding(.horizontal, wingPadding)
            .frame(height: model.notchHeight)

            // 最近便签：置顶优先 + 最近修改补位（规则见 NotchNotes）
            if !model.notes.isEmpty {
                VStack(spacing: 2) {
                    ForEach(model.notes) { note in
                        NotchNoteRow(note: note, model: model)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .opacity(model.isExpanded ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // 只有展开时才画黑：收起态窗口就落在物理刘海范围内，
            // 那里的黑是硬件，我们再画一层就是给刘海描了道直角边。
            NotchCardShape()
                .fill(Color.black)
                .opacity(model.isExpanded ? 1 : 0)
        }
        .allowsHitTesting(model.isExpanded)
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: model.isExpanded)
    }

    /// 两翼布局（刘海 + 净距 + 入口 + 边距）之外的富余卡宽，平分到左右作留白
    private var wingPadding: CGFloat {
        let wings = model.notchWidth + 2 * (NotchGeometry.clearance
            + NotchGeometry.buttonW + NotchGeometry.edgeGap)
        return max(NotchGeometry.edgeGap, (model.cardWidth - wings) / 2 + NotchGeometry.edgeGap)
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

// MARK: - 刘海内容（列表 / 详情切换）

/// 托管与像素自检的入口保持这个名字：展开时按 model.detailNote 在列表与详情间切换，
/// 收起时两边都不画（零像素不变——背景只在展开时出现）。
struct NotchContentView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        Group {
            if let detail = model.detailNote {
                NotchNoteDetailView(note: detail, model: model)
            } else {
                NotchListView(model: model)
            }
        }
        .background {
            NotchCardShape()
                .fill(Color.black)
                .opacity(model.isExpanded ? 1 : 0)
        }
        .allowsHitTesting(model.isExpanded)
    }
}

// MARK: - 垂落卡片轮廓

/// 顶部两肩用贴合圆角（控制点压在角上、曲线向内收），像从屏幕顶边垂下来；
/// 底部两角用大圆角收尾，半径取自刘海自身的半径比例。
struct NotchCardShape: Shape {
    var shoulder: CGFloat = NotchGeometry.shoulderRadius
    var bottom: CGFloat = NotchGeometry.cardBottomRadius

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: shoulder, y: 0))
        p.addLine(to: CGPoint(x: w - shoulder, y: 0))
        p.addQuadCurve(to: CGPoint(x: w, y: shoulder), control: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: w, y: h - bottom))
        p.addQuadCurve(to: CGPoint(x: w - bottom, y: h), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: bottom, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - bottom), control: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: shoulder))
        p.addQuadCurve(to: CGPoint(x: shoulder, y: 0), control: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - 最近便签行

struct NotchNoteRow: View {
    let note: Note
    var model: NotchModel
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 9) {
            thumb
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5))
                    }
                    Text(subtitle)
                        .lineLimit(1)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer(minLength: 4)
            // 悬停才浮现的操作：复制 + 删除。编辑不设按钮——点行本身就是打开这条。
            if hovering {
                HStack(spacing: 2) {
                    iconButton(copied ? "checkmark" : "doc.on.doc", help: "复制便签") { copyTapped() }
                    iconButton("trash", help: "删除便签") { model.onDeleteNote?(note) }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: NotchGeometry.rowH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.13 : 0.05))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.onOpenNote?(note) }
        .onHover { hovering = $0 }
        .handCursor()
        .contextMenu {
            Button("复制便签") { _ = model.onCopyNote?(note) }
            Button(note.isPinned ? "取消置顶" : "置顶") { model.onTogglePinNote?(note) }
            Divider()
            Button("删除便签", role: .destructive) { model.onDeleteNote?(note) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func copyTapped() {
        guard let r = model.onCopyNote?(note), r != .nothing else { return }
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    /// 左侧 24pt 方片：有图用缩略图，没图用纸色（靠颜色认便签是产品的心智）
    private var thumb: some View {
        Group {
            if let img = note.image, let ns = ImageStore.load(img.thumbName, thumb: true) {
                Image(nsImage: ns)
                    .resizable()
                    .scaledToFill()
            } else {
                note.paper.paper
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 一行预览：正文第一非空行（清单剥掉项目符号与勾选框）→ 图片 / 空白兜底
    private var title: String {
        for line in note.text.components(separatedBy: "\n") {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            for bullet in ["- ", "* ", "+ "] where t.hasPrefix(bullet) {
                t = String(t.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            for mark in ["[ ] ", "[x] ", "[X] ", "[✓] ", "✓ ", "☑ ", "☐ ", "· "] where t.hasPrefix(mark) {
                t = String(t.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            if !t.isEmpty { return t }
        }
        if let first = Checklist.parse(note.text).first { return first.text }
        return note.image != nil ? "图片便签" : "空白便签"
    }

    private var subtitle: String {
        var parts: [String] = []
        if note.isChecklist {
            let p = note.checklistProgress
            parts.append("清单 \(p.done)/\(p.total)")
        }
        if !note.tag.isEmpty { parts.append(note.tag) }
        parts.append(Self.timeFormatter.localizedString(for: note.updatedAt, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - 刘海内详情页

/// 点列表行后在面板内打开的单条详情：看全 + 勾清单 + 复制是这个场景的高频动作；
/// 深度编辑（换纸色 / 改标签 / 贴图）不在这里做，经「在便签墙中打开」跳墙内详情页。
struct NotchNoteDetailView: View {
    let note: Note
    var model: NotchModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.onCloseDetail?() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
                }
                .buttonStyle(.plain).handCursor()
                Spacer(minLength: 0)
                Circle().fill(note.paper.paper).frame(width: 9, height: 9)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let img = note.image, let ns = ImageStore.load(img.fileName, thumb: false) {
                        Image(nsImage: ns)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    if note.isChecklist {
                        ForEach(Checklist.parse(note.text)) { item in
                            checkRow(item)
                        }
                    } else if !note.text.isEmpty {
                        Text(note.text)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)

            HStack(spacing: 8) {
                actionButton(copied ? "checkmark" : "doc.on.doc",
                             label: copied ? "已复制" : "复制") { copyTapped() }
                actionButton("rectangle.stack", label: "在便签墙打开") { model.onOpenInWall?(note) }
                Spacer(minLength: 0)
                actionButton("trash", label: "删除") { model.onDeleteNote?(note) }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func checkRow(_ item: Checklist.Item) -> some View {
        Button { model.onToggleCheck?(note, item.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(item.done ? Color.green : Color.white.opacity(0.4))
                Text(item.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.white.opacity(item.done ? 0.45 : 0.92))
                    .strikethrough(item.done, color: Color.white.opacity(0.4))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }

    private func actionButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.10))
            )
        }
        .buttonStyle(.plain).handCursor()
    }

    private func copyTapped() {
        guard let r = model.onCopyNote?(note), r != .nothing else { return }
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    private var meta: String {
        var parts: [String] = []
        if note.isPinned { parts.append("已置顶") }
        if !note.tag.isEmpty { parts.append(note.tag) }
        parts.append(Self.timeFormatter.localizedString(for: note.updatedAt, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
