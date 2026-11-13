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
//
// v0.2.4 详情纸色化 + 可编辑（Carry 验收 0.2.3 后定案）：详情页就是便签本体，
// 整页铺纸色、文字墨色（列表仍是黑色容器）；详情内可直接编辑——普通便签打开即
// 编辑器，清单默认打勾、经头部「编辑」切原始文本编辑。编辑机制全套复用边缘面板
// 范式：PlainTextEditor（保中文输入法组合）+ 草稿 250ms 防抖写回 + allowKey 临时
// 转 key 面板 + 编辑会话中不悬停收起、点外 / Esc 保存收起。
//
// v0.2.5 多屏修复：auxiliaryTop*Area 返回的是屏幕本地坐标（原点在该屏左下角），
// 此前直接当全局坐标用——单屏时本地恰好等于全局，所以一直没暴露；接上外接屏、
// 内置屏不在全局原点后，面板整体错位一屏（跑到外接屏顶部，真刘海处毫无反应）。
// geometry(for:) 现统一换算为全局坐标；并监听显示配置变化（插拔 / 排列 / 合盖）重定位。





// MARK: - 几何

/// 物理刘海在屏幕坐标系中的水平范围（全局坐标，原点在主屏左下）
struct NotchGeometry {
    var leftX: CGFloat      // 刘海左边界（全局坐标，面板 frame 直接用）
    var rightX: CGFloat     // 刘海右边界（全局坐标）
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
            // auxiliary 区域是屏幕本地坐标，面板 frame 是全局坐标，必须加该屏的全局偏移。
            // 单屏时偏移为 0 所以旧写法看不出问题；多屏时不加就会错位一整屏（0.2.5 实测 bug）。
            let originX = screen.frame.minX
            return NotchGeometry(leftX: originX + l.maxX, rightX: originX + r.minX, height: h)
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
    @Published var draft: String = ""
    @Published var isEditingText = false
    @Published var flashSaved = false
    var onDraftChanged: ((String) -> Void)?
    var onToggleEditing: ((Note) -> Void)?
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
    /// 详情编辑期间临时允许成为 key 窗口（同 EdgePanel.allowKey 的范式）；
    /// 平时恒 false——刘海面板不抢键盘，是收起态零打扰的前提。
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
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
    private var saveWork: DispatchWorkItem?
    private var outsideMonitor: Any?
    private var escMonitor: Any?
    /// 点外关闭的轮询兜底（0.3.1）：全局鼠标监视器在该 App 内疑似不触发，
    /// 这里每 0.1s 查一次「鼠标在面板外 + 刚按下」才收起，不依赖无障碍授权。
    private var outsideClickTimer: Timer?
    private var wasMouseDown = false
    private var isFlushing = false
    private var screenObserver: NSObjectProtocol?
    private let model = NotchModel()
    private weak var store: AppStore?
    private(set) var isExpanded = false

    /// 找当前带刘海的屏幕与其几何。逐屏问 geometry，不能只认第一块屏——
    /// 外接屏没有刘海、也不会有刘海坐标，认错屏面板就长到别的屏上去了。
    private static func resolveNotchScreen() -> (screen: NSScreen, geometry: NotchGeometry)? {
        for s in NSScreen.screens {
            if let g = NotchMetrics.geometry(for: s) { return (s, g) }
        }
        return nil
    }

    func install(store: AppStore) {
        self.store = store
        // 显示配置会变（插拔外接屏 / 改排列 / 合盖再开）：监听一次，变化时重定位；
        // 启动时没有刘海屏（合盖外接）也不放弃，屏出现后由监听补装。
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.screenParametersChanged() }
                }
        }
        installPanelIfPossible()
    }

    private func installPanelIfPossible() {
        guard panel == nil,
              let (s, g) = Self.resolveNotchScreen() else { return }
        screen = s
        geometry = g
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
        model.onDraftChanged = { [weak self] text in self?.editChanged(text) }
        model.onToggleEditing = { [weak self] note in
            guard let self else { return }
            if self.model.isEditingText {
                self.flushSave()
                self.model.isEditingText = false
                self.syncDetail()
            } else {
                // 进文本编辑前把草稿对齐最新正文（期间可能刚打过勾）
                self.model.draft = self.store?.notes.first(where: { $0.id == note.id })?.text ?? note.text
                self.model.isEditingText = true
            }
            self.updateSessionMonitors()
        }
        model.onOpenNote = { [weak self] note in
            guard let self else { return }
            // 用 store 里的最新副本（列表只是快照，可能已旧）
            let fresh = self.store?.notes.first(where: { $0.id == note.id }) ?? note
            self.model.detailNote = fresh
            self.model.draft = fresh.text
            self.model.isEditingText = false
            self.panel?.allowKey = true
            self.apply(true)
            self.updateSessionMonitors()
        }
        model.onCloseDetail = { [weak self] in
            guard let self else { return }
            self.flushSave()
            self.model.detailNote = nil
            self.model.isEditingText = false
            self.panel?.allowKey = false
            self.stopSessionMonitors()
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
            self.syncDetail()
        }
        model.onOpenInWall = { [weak self] note in
            self?.flushSave()
            // 与菜单栏「设置…」同一套旗子 + 通知机制：窗口在就直接弹，
            // 窗口是刚重建的就靠 WallView 的 onAppear 消费旗子
            AppContext.shared.pendingDetailNoteID = note.id
            NotificationCenter.default.post(name: .noteWallOpenDetail, object: nil)
            self?.collapseNow()
            AppDelegate.bringWallToFront()
        }
        model.onDraftChanged = { [weak self] text in self?.editChanged(text) }
        model.onToggleEditing = { [weak self] note in
            guard let self else { return }
            if self.model.isEditingText {
                self.flushSave()
                self.model.isEditingText = false
                self.syncDetail()
            } else {
                // 进文本编辑前把草稿对齐最新正文（期间可能刚打过勾）
                self.model.draft = self.store?.notes.first(where: { $0.id == note.id })?.text ?? note.text
                self.model.isEditingText = true
            }
            self.updateSessionMonitors()
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

    /// 显示配置变化时重定位：刘海屏可能换位、消失（合盖）或出现（开盖 / 插屏）。
    private func screenParametersChanged() {
        if panel == nil {
            installPanelIfPossible()
            return
        }
        guard let (s, g) = Self.resolveNotchScreen() else {
            collapseNow()
            panel?.orderOut(nil)
            screen = nil
            geometry = nil
            return
        }
        screen = s
        geometry = g
        model.notchWidth = g.width
        model.notchHeight = g.height
        model.cardWidth = g.cardWidth(screenWidth: s.frame.width)
        if panel?.isVisible == false { panel?.orderFrontRegardless() }
        apply(isExpanded)
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

    /// 详情页拿的是副本：把 store 里的最新状态同步回去，并刷新列表快照
    private func syncDetail() {
        guard let id = model.detailNote?.id,
              let fresh = store?.notes.first(where: { $0.id == id }) else { return }
        if model.detailNote != fresh { model.detailNote = fresh }
        refreshNotes()
    }

    /// 编辑会话判定：详情打开且正文编辑器在场（普通便签恒在场；清单只在文本编辑时在场）。
    /// 会话中鼠标移开不收起，收起走点外 / Esc / 返回——与边缘抽出面板同一套行为。
    private var editSessionActive: Bool {
        guard let detail = model.detailNote else { return false }
        return model.isEditingText || !detail.isChecklist
    }

    /// 与边缘面板同一套草稿保存：记「停手」不记「击键」，250ms 防抖
    private func editChanged(_ text: String) {
        model.draft = text
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 写回前的最后一道闸（同边缘面板）：便签可能已被锁定 / 删除，绝不能把明文写进密文便签
    private func flushSave() {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        saveWork?.cancel()
        saveWork = nil
        guard let detail = model.detailNote, let store else { return }
        guard let note = store.notes.first(where: { $0.id == detail.id }),
              !note.isLocked, note.deletedAt == nil else {
            NSLog("NoteWall: 刘海详情写回时发现便签已锁定/删除，放弃草稿")
            collapseNow()
            return
        }
        guard model.draft != note.text else { return }
        var updated = note
        updated.text = model.draft
        store.update(updated)
        model.flashSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.model.flashSaved = false
        }
    }

    /// 会话监听（仅编辑会话期间，同边缘面板 startMonitors）：点外 = 写回收起；Esc 分层处理。
    /// 0.3.1：先停再装（同 EdgeDeck），修掉 escMonitor 每次调用都重复装的泄漏；
    /// 回调里先判点击是否在面板内，在内不处理（全局监视器不给坐标，用当时鼠标位置判断）。
    private func updateSessionMonitors() {
        stopSessionMonitors()
        guard editSessionActive else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let frame = self.panel?.frame, frame.contains(NSEvent.mouseLocation) { return }
                self.flushSave()
                self.collapseNow()
            }
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.isEditingText {
                    self.flushSave()
                    self.model.isEditingText = false
                    self.syncDetail()
                    self.updateSessionMonitors()
                } else {
                    self.flushSave()
                    self.collapseNow()
                }
            }
            return nil
        }
    }

    /// 点外关闭的轮询（0.3.1，兜底）：展开即生效，列表页与详情页一致。
    /// 上升沿判断：从面板内开始的拖拽（编辑器里选字后拖出面板），按下时鼠标在内，不误关。
    private func startOutsideClickWatch() {
        stopOutsideClickWatch()
        wasMouseDown = false
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOutsideClick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        outsideClickTimer = timer
    }

    private func stopOutsideClickWatch() {
        outsideClickTimer?.invalidate()
        outsideClickTimer = nil
    }

    private func checkOutsideClick() {
        guard isExpanded, let frame = panel?.frame else { return }
        let down = NSEvent.pressedMouseButtons != 0
        defer { wasMouseDown = down }
        guard down, !wasMouseDown, !frame.contains(NSEvent.mouseLocation) else { return }
        flushSave()
        collapseNow()
    }

    private func stopSessionMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        outsideMonitor = nil
        escMonitor = nil
    }

    func hoverExit() {
        // 编辑会话中鼠标移开不收起（同边缘抽出面板）
        if editSessionActive { return }
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
        if !expanded {
            flushSave()
            model.detailNote = nil
            model.isEditingText = false
            panel?.allowKey = false
            stopSessionMonitors()
            stopOutsideClickWatch()
        } else {
            startOutsideClickWatch()
        }
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
        .help(label == "新建" ? "新建便签" : "打开随手贴")
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
            for mark in ["[] ", "[ ] ", "[x] ", "[X] ", "[✓] ", "✓ ", "☑ ", "☐ ", "· "] where t.hasPrefix(mark) {
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

/// 点列表行后在面板内打开的单条详情。详情页就是便签本体：整页铺纸色、文字墨色，
/// 与便签墙 / 边缘面板里的便签长一个样（列表是黑色容器，详情不是）。
/// 普通便签打开即编辑器；清单默认打勾模式，经头部「编辑」切原始文本编辑。
/// 编辑机制全套复用边缘面板范式（PlainTextEditor + 草稿防抖写回，会话行为在控制器）。
struct NotchNoteDetailView: View {
    let note: Note
    @ObservedObject var model: NotchModel
    @State private var copied = false

    private var ink: Color { note.paper.ink }
    private var inkSoft: Color { note.paper.inkSoft }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            content
            hairline
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { NotchCardShape().fill(note.paper.paper) }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.onCloseDetail?() } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(ink.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(ink.opacity(0.08))
                )
            }
            .buttonStyle(.plain).handCursor()
            Spacer(minLength: 0)
            if model.flashSaved {
                Text("已保存")
                    .font(.system(size: 11))
                    .foregroundStyle(inkSoft)
            }
            if note.isChecklist {
                Button { model.onToggleEditing?(note) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: model.isEditingText ? "checkmark" : "pencil")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(model.isEditingText ? "完成" : "编辑")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(ink.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(ink.opacity(0.08))
                    )
                }
                .buttonStyle(.plain).handCursor()
            }
            Text(meta)
                .font(.system(size: 11))
                .foregroundStyle(inkSoft)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var hairline: some View {
        Rectangle().fill(ink.opacity(0.10)).frame(height: 0.5)
    }

    // MARK: 正文

    @ViewBuilder
    private var content: some View {
        if model.isEditingText || !note.isChecklist {
            editorBody
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    headerImage
                    ForEach(Checklist.parse(note.text)) { item in
                        checkRow(item)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// 文本编辑：自托管编辑器（同边缘面板），正文由它托管、草稿经 onChange 防抖写回；
    /// 用 SwiftUI TextEditor 会在中文输入法组合期间被写回打断拼音。
    private var editorBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerImage
            PlainTextEditor(text: $model.draft, fontSize: 14.5, ink: ink,
                            focusOnAppear: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: model.draft) { _, newValue in
                    model.onDraftChanged?(newValue)
                }
        }
        .padding(.horizontal, 14)
        .padding(.top, note.image == nil ? 12 : 0)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var headerImage: some View {
        if let img = note.image, let ns = ImageStore.load(img.fileName, thumb: false) {
            Image(nsImage: ns)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 170)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(ink.opacity(0.10), lineWidth: 1)
                )
                .padding(.top, 12)
        }
    }

    private func checkRow(_ item: Checklist.Item) -> some View {
        Button { model.onToggleCheck?(note, item.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(item.done ? ink : ink.opacity(0.35))
                Text(item.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(item.done ? inkSoft : ink)
                    .strikethrough(item.done, color: inkSoft)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }

    // MARK: 底部操作条

    private var actionBar: some View {
        HStack(spacing: 8) {
            actionButton(copied ? "checkmark" : "doc.on.doc",
                         label: copied ? "已复制" : "复制") { copyTapped() }
            actionButton("rectangle.stack", label: "在随手贴打开") { model.onOpenInWall?(note) }
            Spacer(minLength: 0)
            actionButton("trash", label: "删除") { model.onDeleteNote?(note) }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private func actionButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(ink.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ink.opacity(0.08))
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
