import SwiftUI
import AppKit
import Combine

// MARK: - 设置模型

/// 停靠在哪一侧。左右都要支持：Dock 一般在右（或下），有人惯用左手边。
enum EdgeSide: String, Codable, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? "左侧" : "右侧" }
}

/// 边缘条里放什么。两种模式互斥可切换（D1）：
/// 钉住的永远在、最近编辑的自动补——「钉住优先混合」会让用户搞不懂为什么有的签消失了。
enum EdgeMode: String, Codable, CaseIterable, Identifiable {
    case recent, pinned
    var id: String { rawValue }
    var title: String { self == .recent ? "最近编辑" : "手动钉住" }
    var hint: String {
        switch self {
        case .recent: return "自动跟着你最近动过的便签走"
        case .pinned: return "只显示你从卡片「⋯」菜单里钉上来的便签"
        }
    }
}

// MARK: - 三态

enum EdgeDeckPhase: Equatable {
    case rest           // 细条
    case fan            // 悬停扇开
    case pull(UUID)     // 抽出某张便签

    var isPull: Bool {
        if case .pull = self { return true }
        return false
    }
    var pulledID: UUID? {
        if case let .pull(id) = self { return id }
        return nil
    }
}

// MARK: - 纯几何（不碰窗口，供断言）

/// 三态的全部尺寸与定位都从这里出，窗口控制器只做应用。
/// 这样「贴边零缝隙」「矮屏自动减签」「阴影不被窗边硬切」这些硬约束可以在没有屏幕的 CI 里直接断言。
enum EdgeDeckGeom {
    static let restWidth: CGFloat = 12
    /// 所有形态都向屏幕外多伸这么多。旋转 3° 的纸签四角会内缩约 2.9pt，
    /// 不留这点余量，某些角度下贴边侧会露出发丝缝。
    static let overshoot: CGFloat = 4
    static let tabWidth: CGFloat = 32
    static let tabHeight: CGFloat = 116
    /// 相邻签的纵向步进：每张签完整露出 4 个汉字
    static let tabStep: CGFloat = 68
    static let noteWidth: CGFloat = 330
    static let noteMinHeight: CGFloat = 248
    static let noteMaxHeight: CGFloat = 420
    /// 抽出态底部两颗圆钮
    static let actionSize: CGFloat = 26
    static let actionGap: CGFloat = 8
    /// 签列与按钮之间留的空隙
    static let actionTop: CGFloat = 12

    /// 自绘阴影的最大扩散距离。
    ///
    /// **不要按 `radius` 一倍算。** SwiftUI / CoreGraphics 的 shadow blur 是高斯，
    /// `radius` 只是名义模糊半径，可见尾迹要拖到约 **2×radius** 才衰减到看不见。
    /// 上一版按 `radius + offset` 留衬边，结果边界处还剩一层淡影，
    /// 被窗口一刀切出直边——就是用户两次拍到的「半透明边框 / 半透明阴影」。
    /// 这里统一按 `2×radius + |offset| + 2` 预留。
    static let noteShadowRadius: CGFloat = 10
    static let noteShadowDX: CGFloat = 4
    static let tabShadowRadius: CGFloat = 6
    static let tabShadowDX: CGFloat = 3
    static var noteShadowBleed: CGFloat { noteShadowRadius * 2 + noteShadowDX + 2 }  // 26
    static var tabShadowBleed: CGFloat { tabShadowRadius * 2 + tabShadowDX + 3 }     // 18

    /// 窗口四周（除贴边侧）要留的透明衬边，供自绘阴影自然衰减到 0。
    /// 贴边侧只留 `overshoot`，所以「零缝隙」不受影响。
    static func bleed(for phase: EdgeDeckPhase) -> CGFloat {
        switch phase {
        case .rest: return 0
        case .fan:  return tabShadowBleed
        case .pull: return noteShadowBleed
        }
    }

    static func stackHeight(count: Int) -> CGFloat {
        count <= 0 ? 0 : tabHeight + CGFloat(count - 1) * tabStep
    }

    /// 抽出态：签列 + 底部两颗钮
    static var actionBlockHeight: CGFloat {
        actionTop + actionSize * 2 + actionGap
    }

    /// 给定屏幕可用高度能放几张签。宁可少放，也不让签出屏。
    static func tabCapacity(visibleHeight: CGFloat, requested: Int) -> Int {
        let maxH = visibleHeight * 0.66
        var n = max(1, requested)
        while n > 1 && stackHeight(count: n) > maxH { n -= 1 }
        return n
    }

    /// 签列容量：**扇开与抽出共用同一套算法**，因为两种形态底下都挂着两颗圆钮，
    /// 按钮占掉的高度必须先扣掉，否则最后一屏的签会被按钮顶出可视区。
    static func stackCapacity(visibleHeight: CGFloat, requested: Int) -> Int {
        tabCapacity(visibleHeight: visibleHeight * 0.72 - actionBlockHeight,
                    requested: requested)
    }

    static func restHeight(dashes: Int) -> CGFloat {
        min(240, 22 + CGFloat(max(1, dashes)) * 19)
    }

    /// 抽出面板高度跟随内容行数：短便签不该拖出一大块空纸
    static func noteHeight(text: String) -> CGFloat {
        let lines = max(1, text.components(separatedBy: "\n").count)
        return min(noteMaxHeight, max(noteMinHeight, 118 + CGFloat(lines) * 22))
    }

    /// 窗口 frame：**内容**贴死屏幕边缘，overshoot 伸到屏幕外，
    /// 其余三边留 `bleed` 衬边给自绘阴影。纵向以屏幕中线居中，触顶/触底时内收 8pt。
    static func frame(side: EdgeSide, visible vf: CGRect, visibleSize: CGSize,
                      bleed: CGFloat = 0) -> CGRect {
        let w = visibleSize.width + bleed + overshoot
        // 上下各留一条，否则面板顶部/底部的阴影同样会被窗口切平
        let h = min(visibleSize.height + bleed * 2, vf.height * 0.92)
        let y = min(max(vf.midY - h / 2, vf.minY + 8), vf.maxY - h - 8)
        let x = side == .right ? vf.maxX - visibleSize.width - bleed : vf.minX - overshoot
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 内容（真正看得见的那块）的贴边侧在屏幕坐标里的位置，用来断言「零缝隙」。
    /// overshoot 在屏幕外、bleed 在屏幕内侧，两者都不参与这条边。
    static func contentEdge(side: EdgeSide, frame f: CGRect, bleed: CGFloat) -> CGFloat {
        side == .right ? f.maxX - overshoot : f.minX + overshoot
    }
}

// MARK: - 交互状态

@MainActor
final class EdgeDeckModel: ObservableObject {
    @Published var phase: EdgeDeckPhase = .rest
    /// 抽出面板的草稿。直接改 store 会让「最近编辑」在打字过程中重排，先把草稿留在面板里。
    @Published var draft: String = ""
    @Published var flashSaved: Bool = false
    /// 抽出期间冻结的签列顺序。
    ///
    /// 「最近编辑」是按 `updatedAt` 排的，而编辑本身就会刷新 `updatedAt`——
    /// 不冻结的话，用户按下回车的瞬间，手里这张纸会从第 3 位跳到第 1 位，
    /// 面板跟着上移，像闪了一下。顺序只在**收起之后**重排。
    @Published var frozenOrder: [UUID]? = nil

    /// 按冻结顺序重排（冻结时新增/消失的便签按原逻辑丢弃或忽略）
    func ordered(_ notes: [Note]) -> [Note] {
        guard let frozen = frozenOrder else { return notes }
        let map = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return frozen.compactMap { map[$0] }
    }
}

// MARK: - 面板

final class EdgePanel: NSPanel {
    /// 只有抽出态才允许成为 key：细条和纸签都不该抢键盘
    var allowKey = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 40, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        // 不带 .transient：边缘条是常驻的，App 退到后台它也不能消失
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false              // 透明窗口的系统阴影是方的，会出卖圆角
        hidesOnDeactivate = false
        isMovableByWindowBackground = false   // 钉死在边缘，不可拖走
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

// MARK: - 控制器

@MainActor
final class EdgeDeckController {
    static let shared = EdgeDeckController()

    let model = EdgeDeckModel()
    private var panel: EdgePanel?
    private weak var store: AppStore?
    private var cancellables: Set<AnyCancellable> = []
    private var collapseWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?
    private var outsideMonitor: Any?
    private var escMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?

    func attach(store: AppStore) {
        guard self.store == nil else { return }
        self.store = store

        store.$edgeEnabled
            .sink { [weak self] on in on ? self?.show() : self?.teardown() }
            .store(in: &cancellables)
        store.$edgeSide
            .dropFirst()
            .sink { [weak self] _ in self?.reposition(animated: false) }
            .store(in: &cancellables)
        // 便签集合变化影响「要不要显示」：最近模式下一条都没有时整条隐藏，
        // 比显示一根空胶囊诚实——没有内容的东西不该占屏幕。
        store.$notes
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)
        store.$edgeMode
            .dropFirst()
            .sink { [weak self] _ in self?.updateVisibility(); self?.reposition(animated: false) }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition(animated: false) }
        }
        // 墙窗口被拖到另一块屏，条要跟着过去
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition(animated: false) }
        }

        if store.edgeEnabled { show() }
    }

    // MARK: 显示 / 隐藏

    func show() {
        guard let store, store.edgeEnabled else { return }
        ensurePanel()
        updateVisibility()
        reposition(animated: false)
    }

    func teardown() {
        collapseWork?.cancel()
        flushSave()
        stopMonitors()
        model.phase = .rest
        model.frozenOrder = nil
        panel?.orderOut(nil)
    }

    private func updateVisibility() {
        guard let panel, let store else { return }
        // 最近模式下没有可显示的便签 → 整条消失；钉住模式留着（空签负责引导）
        let visible = store.edgeEnabled && (store.edgeMode == .pinned || !store.edgeNotes.isEmpty)
        if visible { panel.orderFront(nil) } else { panel.orderOut(nil) }
        if visible { reposition(animated: false) }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = EdgePanel()
        let view = EdgeDeckView(
            store: store ?? AppContext.shared.store,
            model: model,
            onHover: { [weak self] inside in self?.hoverChanged(inside) },
            onPick: { [weak self] id in self?.pull(id) },
            onEdit: { [weak self] text in self?.editChanged(text) },
            onDismiss: { [weak self] in self?.collapse() },
            onContextAction: { [weak self] action in self?.contextAction(action) }
        )
        let host = NSHostingView(rootView: view)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
    }

    // MARK: 几何

    /// 条停在哪块屏：跟随便签墙窗口所在屏；窗口不在时退回主屏。
    /// 不用「鼠标所在屏」——鼠标随手一划就换屏，条会跟着乱跳；
    /// 用户对「我的窗口在哪块屏」是有稳定预期的。
    private func currentScreen() -> NSScreen? {
        if let win = AppContext.shared.wallWindow, win.isVisible {
            let center = NSPoint(x: win.frame.midX, y: win.frame.midY)
            if let s = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) {
                return s
            }
        }
        // 没有墙窗口时退回系统主屏（screens.first），不用 NSScreen.main：
        // 后者跟着键盘焦点/鼠标跑，在扩展屏上会飘到另一块屏去，条也跟着跳。
        return NSScreen.screens.first ?? NSScreen.main
    }

    private func visibleSize(store: AppStore) -> CGSize {
        let vf = currentScreen()?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        switch model.phase {
        case .rest:
            return CGSize(width: EdgeDeckGeom.restWidth,
                          height: EdgeDeckGeom.restHeight(dashes: max(1, store.edgeNotes.count)))
        case .fan:
            let requested = store.edgeMode == .pinned ? max(1, store.edgeNotes.count) : store.edgeNotes.count
            let n = EdgeDeckGeom.stackCapacity(visibleHeight: vf.height, requested: max(1, requested))
            return CGSize(width: EdgeDeckGeom.tabWidth,
                          height: EdgeDeckGeom.stackHeight(count: n) + EdgeDeckGeom.actionBlockHeight)
        case .pull:
            // 抽出态 = 完整便签 + 旁边仍在的签列（不再是「只剩一张纸」）
            let n = EdgeDeckGeom.stackCapacity(visibleHeight: vf.height,
                                               requested: max(1, store.edgeNotes.count))
            let column = EdgeDeckGeom.stackHeight(count: n) + EdgeDeckGeom.actionBlockHeight
            // 面板跟着它原来那张签下移；窗口要装得下「偏移 + 面板」。
            // 这里必须用冻结顺序：编辑会刷新 updatedAt，实时排序下 idx 会从 2 变 0，
            // 面板和窗口高度当场跳一下。
            let idx = min(model.ordered(store.edgeNotes)
                            .firstIndex(where: { $0.id == model.phase.pulledID }) ?? 0,
                          max(0, n - 1))
            let panelBottom = CGFloat(idx) * EdgeDeckGeom.tabStep
                + EdgeDeckGeom.noteHeight(text: model.draft)
            return CGSize(width: EdgeDeckGeom.noteWidth + EdgeDeckGeom.tabWidth,
                          height: max(column, panelBottom))
        }
    }

    func reposition(animated: Bool) {
        guard let panel, let store, let screen = currentScreen() else { return }
        let f = EdgeDeckGeom.frame(side: store.edgeSide,
                                   visible: screen.visibleFrame,
                                   visibleSize: visibleSize(store: store),
                                   bleed: EdgeDeckGeom.bleed(for: model.phase))
        guard f != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(f, display: true)
            }
        } else {
            panel.setFrame(f, display: true)
        }
    }

    // MARK: 状态机

    /// 视图层 onHover 的唯一入口。
    func hoverChanged(_ inside: Bool) {
        collapseWork?.cancel()
        collapseWork = nil
        if inside {
            if model.phase == .rest { model.phase = .fan; reposition(animated: true) }
            return
        }
        switch model.phase {
        case .rest:
            break
        case .fan:
            // 320ms 防抖：指针在签与屏幕边之间来回扫时不该闪烁（Noty 同款节奏）
            scheduleCollapse(after: 0.32)
        case .pull:
            // 正在编辑（面板是 key）时不因为鼠标离开就收——打字的时候鼠标经常在别处
            if panel?.isKeyWindow == true { return }
            scheduleCollapse(after: 0.6)
        }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func pull(_ id: UUID) {
        guard let store,
              let note = store.notes.first(where: { $0.id == id }),
              !note.isLocked, note.deletedAt == nil else { return }
        // 已经抽着这张：不重来（会让 TextEditor 失焦重绘）
        if model.phase.pulledID == id { return }
        // 从一张换到另一张：先把上一张的草稿写回去，别丢字
        if model.phase.isPull { flushSave() }
        collapseWork?.cancel()
        // 第一次抽开时把这一列的顺序钉住：编辑会刷新 updatedAt，
        // 不钉住的话手里这张会边打字边往上跳
        if model.frozenOrder == nil {
            model.frozenOrder = store.edgeNotes.map(\.id)
        }
        model.draft = note.text
        model.flashSaved = false
        model.phase = .pull(id)
        // v0.9.15：边缘窗口不再注册手型光标（floating 面板 + 窗口动画 + 视图树重建
        // 会和系统光标管理反复打架，修复多轮仍偶发闪烁），这里保持系统默认光标。
        reposition(animated: true)
        panel?.allowKey = true
        // nonactivatingPanel 成为 key 不激活 App：借走键盘，不抢焦点
        panel?.makeKey()
        // TextEditor 是这时才建出来的；系统若设了「总是显示滚动条」，
        // 纸面上会多一根直角白条（深色纸上更刺眼）。等它建好再压成 overlay。
        if let content = panel?.contentView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                ScrollChrome.soften(content)
            }
        }
        startMonitors()
    }

    /// 收起回细条。所有离开路径（移出 / Esc / 点别处 / 关设置）都汇到这里。
    func collapse() {
        collapseWork?.cancel()
        collapseWork = nil
        flushSave()
        stopMonitors()
        let wasKey = panel?.isKeyWindow == true
        panel?.allowKey = false
        model.phase = .rest
        // 编辑结束才允许重排：「最近编辑」的顺序在这一刻才刷新，
        // 用户已经把手里的纸放回去了，跳位不会被看见。
        model.frozenOrder = nil
        if wasKey, let panel {
            // NSPanel 没有公开的「放弃 key」API。orderOut 会连带放弃 key，
            // 键盘焦点回到之前正在用的窗口；立刻 orderFront 把细条摆回去。
            panel.orderOut(nil)
            panel.orderFront(nil)
        }
        reposition(animated: true)
    }

    func editChanged(_ text: String) {
        model.draft = text
        // 记「停手」不记「击键」：250ms 防抖
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 写回前的最后一道闸：便签可能在这几秒内被锁定/删除，绝不能把明文写进密文便签。
    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        guard case let .pull(id) = model.phase, let store else { return }
        guard let note = store.notes.first(where: { $0.id == id }),
              !note.isLocked, note.deletedAt == nil else {
            NSLog("NoteWall: 边缘面板写回时发现便签已锁定/删除，放弃草稿")
            collapse()
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
        // 行数变了面板高度跟着变
        reposition(animated: true)
    }

    // MARK: 监听（仅抽出态）

    private func startMonitors() {
        stopMonitors()
        // 点到面板外 = 写回收起。全局监视器拿不到事件本身，只收通知，够用了。
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            MainActor.assumeIsolated { self?.collapse() }
            return nil
        }
    }

    private func stopMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        outsideMonitor = nil
        escMonitor = nil
    }

    // MARK: 右键菜单

    private func contextAction(_ action: EdgeDeckContextAction) {
        guard let store else { return }
        switch action {
        case .toggleMode:
            store.edgeMode = store.edgeMode == .recent ? .pinned : .recent
        case .toggleSide:
            store.edgeSide = store.edgeSide == .right ? .left : .right
        case .openWall:
            flushSave()
            collapse()
            AppDelegate.bringWallToFront()
        case .newNote:
            flushSave()
            collapse()
            // 走全局捕获面板：和 ⌥Space 同一条路，用户不用学第二套新建流程
            CaptureController.shared.show()
        case .hide:
            store.edgeEnabled = false
            ToastCenter.shared.show("屏幕边缘条已隐藏，可在设置里重新打开")
        }
    }
}

/// 右键菜单 / 底部圆钮的动作集合，视图与控制器之间的窄接口
enum EdgeDeckContextAction {
    case toggleMode, toggleSide, openWall, newNote, hide
}

// MARK: - 视图

struct EdgeDeckView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var model: EdgeDeckModel
    var onHover: (Bool) -> Void = { _ in }
    var onPick: (UUID) -> Void = { _ in }
    var onEdit: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onContextAction: (EdgeDeckContextAction) -> Void = { _ in }

    private var side: EdgeSide { store.edgeSide }
    private var bleed: CGFloat { EdgeDeckGeom.bleed(for: model.phase) }

    /// 和控制器用同一块屏：跟着便签墙窗口走，而不是 NSScreen.main（多屏下会算错张数）
    private var referenceVisibleHeight: CGFloat {
        (AppContext.shared.wallWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
    }

    private var notes: [Note] {
        let cap = EdgeDeckGeom.stackCapacity(visibleHeight: referenceVisibleHeight,
                                             requested: store.edgeNotes.count)
        // 抽出期间按冻结顺序排：否则边打字边重排，整列跟着跳
        return Array(model.ordered(store.edgeNotes).prefix(cap))
    }

    var body: some View {
        // 上下也各留一条衬边：面板顶部/底部、纸签的第一张与最后一张都会投影，
        // 只留左右的话，垂直方向的影子同样被窗口切成直线。
        VStack(spacing: 0) {
            Color.clear.frame(height: bleed)
            HStack(spacing: 0) {
                if side == .left {
                    // 贴边侧：overshoot 落到屏幕外；内侧：给自绘阴影留的衬边
                    Color.clear.frame(width: EdgeDeckGeom.overshoot)
                    content
                    innerPadColumn
                } else {
                    innerPadColumn
                    content
                    Color.clear.frame(width: EdgeDeckGeom.overshoot)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Color.clear.frame(height: bleed)
        }
        .contentShape(Rectangle())
        .onHover { onHover($0) }
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: model.phase)
    }

    /// 衬边除了给阴影留地方，也顺便当「点空白收起」的落点：
    /// 抽出态里点窗口内的空白处 = 点外面，不该毫无反应。
    ///
    /// 只有抽出态才算「可点」：扇开态的这块只是透明衬边，点了什么也不会发生，
    /// 给它挂手型等于骗人（原型里 `.edge-host{cursor:default}` 也是这个意思）。
    private var innerPadColumn: some View {
        Color.clear
            .frame(width: bleed)
            .contentShape(Rectangle())
            .onTapGesture { if model.phase.isPull { onDismiss() } }
    }

    /// 右键菜单只挂在细条与纸签上。挂在 0×0 的隐藏视图上等于永远点不到；
    /// 挂在抽出面板上会盖掉 TextEditor 自己的「拷贝/粘贴」菜单。
    @ViewBuilder
    private func withEdgeMenu(_ v: some View) -> some View {
        if RenderFlags.snapshot {
            v
        } else {
            v.contextMenu { menuItems }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(store.edgeMode == .recent ? "改为只显示钉住的便签" : "改为显示最近编辑") {
            onContextAction(.toggleMode)
        }
        Button(side == .right ? "移到屏幕左侧" : "移到屏幕右侧") {
            onContextAction(.toggleSide)
        }
        Divider()
        Button("新建便签") { onContextAction(.newNote) }
        Button("打开随手贴") { onContextAction(.openWall) }
        Button("隐藏边缘条") { onContextAction(.hide) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .rest:
            withEdgeMenu(pill)
                .frame(maxHeight: .infinity)
                .transition(.opacity)
        case .fan:
            // 扇开态就带上底部两颗钮：它们是常驻入口，不该等到「点开一张便签」才出现
            withEdgeMenu(tabColumn(pulled: nil))
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
        case .pull(let id):
            withdrawn(id)
                .transition(.opacity)
        }
    }

    // MARK: ① 细条

    private var pill: some View {
        VStack(spacing: 5) {
            ForEach(Array(notes.prefix(10).enumerated()), id: \.element.id) { _, n in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(n.paper.paper)
                    .frame(width: 4, height: 14)
            }
        }
        .padding(.vertical, 10)
        .frame(width: EdgeDeckGeom.restWidth)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: side == .right ? 8 : 0,
                bottomLeadingRadius: side == .right ? 8 : 0,
                bottomTrailingRadius: side == .right ? 0 : 8,
                topTrailingRadius: side == .right ? 0 : 8,
                style: .continuous)
                .fill(Color.dyn(0x1C1C20, 0x141418, lightAlpha: 0.62, darkAlpha: 0.72))
        )
    }

    // MARK: ② 扇开的纸签

    /// `pulled`：抽出态里那张已经展开的签——它留在签列原位（纸没被「拿走」），
    /// 只把自己扶正并打一道墨色标记，免得用户以为它凭空消失了。
    private func tabsStack(pulled: UUID?) -> some View {
        ZStack(alignment: side == .right ? .topTrailing : .topLeading) {
            if notes.isEmpty {
                emptyHintTab
            } else {
                ForEach(Array(notes.enumerated()), id: \.element.id) { idx, n in
                    tab(n, index: idx, pulled: n.id == pulled)
                }
            }
        }
        // ZStack 不把 offset 算进固有高度：不显式撑开的话，整叠签会被当成
        // 一张签那么高（112pt）居中，后面的签直接画到窗口外面去
        .frame(width: EdgeDeckGeom.tabWidth,
               height: EdgeDeckGeom.stackHeight(count: max(1, notes.count)),
               alignment: side == .right ? .topTrailing : .topLeading)
        // v0.9.15：这一列不再挂手型垫片（边缘窗口保持系统默认光标）。
        // 投影只在这一层做一次，**不能**放到每张签上：
        // 每张签各投一次时，相邻签的阴影像 5 层 30% 黑叠在一起，
        // 在窗口内的衬边上连成一条均匀的灰带（看着就像「透明边框」又回来了）。
        // 整个 ZStack 一次离屏渲染再投影，重叠的签被当成一个轮廓，只落一层。
        .shadow(color: .black.opacity(0.34), radius: EdgeDeckGeom.tabShadowRadius,
                x: side == .right ? -EdgeDeckGeom.tabShadowDX : EdgeDeckGeom.tabShadowDX,
                y: 4)
    }

    /// 钉住模式的空态：留一张「空签」做引导，而不是让整条消失（藏着会被当成 bug）
    private var emptyHintTab: some View {
        VStack(spacing: 1.5) {
            verticalChars("钉一张到边缘", ink: Paper.cream.ink.opacity(0.6))
        }
        .padding(.vertical, 10)
        .frame(width: EdgeDeckGeom.tabWidth, height: EdgeDeckGeom.tabHeight)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: side == .right ? 7 : 0,
                bottomLeadingRadius: side == .right ? 7 : 0,
                bottomTrailingRadius: side == .right ? 0 : 7,
                topTrailingRadius: side == .right ? 0 : 7,
                style: .continuous)
                .fill(Paper.cream.paper.opacity(0.92))
        )
    }

    private func tab(_ note: Note, index: Int, pulled: Bool = false) -> some View {
        let leans: [Double] = [3, -2.2, 2.4, -3]
        // 正被抽出的那张扶正：歪着像「没选中」，而且它的内容此刻就摊在旁边
        let lean = pulled ? 0 : leans[index % 4] * (side == .right ? 1 : -1)
        return Button { onPick(note.id) } label: {
            VStack(spacing: 1) {
                verticalChars(String(note.edgeTitle.prefix(4)), ink: note.paper.ink, size: 10.5)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(width: EdgeDeckGeom.tabWidth, height: EdgeDeckGeom.tabHeight)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: side == .right ? 7 : 0,
                    bottomLeadingRadius: side == .right ? 7 : 0,
                    bottomTrailingRadius: side == .right ? 0 : 7,
                    topTrailingRadius: side == .right ? 0 : 7,
                    style: .continuous)
                    .fill(note.paper.paper)
            )
            .overlay(alignment: side == .right ? .leading : .trailing) {
                if pulled {
                    Capsule()
                        .fill(note.paper.ink.opacity(0.30))
                        .frame(width: 3)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
        // 手型不挂在单张签上（见 tabsStack 的说明：旋转 + 偏移过的子视图量不准），
        // 整列由一个垫片负责
        // 旋转轴钉在贴屏幕的那条边上：内缘伸错，贴边侧保持一条直线
        .rotationEffect(.degrees(lean), anchor: side == .right ? .trailing : .leading)
        .offset(y: CGFloat(index) * EdgeDeckGeom.tabStep)
        .zIndex(pulled ? 99 : Double(index))
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(x: side == .right ? 18 : -18)),
            removal: .opacity))
        .animation(.spring(response: 0.34, dampingFraction: 0.72).delay(Double(index) * 0.045),
                   value: model.phase)
    }

    // MARK: ③ 抽出的便签 = 完整面板 + 旁边仍在的签列

    /// 抽出态不再是「只剩一张纸」：面板摊开的同时，签列仍然贴在屏幕边缘，
    /// 下面挂着两颗圆钮（打开便签墙 / 新建）。换一张只要点签列里的另一张即可。
    ///
    /// 面板的纵向位置跟着它原来那张签走（第 N 张就下移 N 个步进）——
    /// 这样「这张纸是从这一列里抽出来的」在几何上就说得通，不会凭空浮在别处。
    private func withdrawn(_ id: UUID) -> some View {
        let note = store.notes.first(where: { $0.id == id })
        let paper = note?.paper ?? .cream
        let idx = notes.firstIndex(where: { $0.id == id }) ?? 0
        return HStack(alignment: .top, spacing: 0) {
            if side == .left { tabColumn(pulled: id) }
            noteBody(note: note, paper: paper)
                .frame(width: EdgeDeckGeom.noteWidth,
                       height: EdgeDeckGeom.noteHeight(text: model.draft))
                .offset(y: CGFloat(idx) * EdgeDeckGeom.tabStep)
            if side == .right { tabColumn(pulled: id) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func tabColumn(pulled: UUID?) -> some View {
        VStack(spacing: 0) {
            tabsStack(pulled: pulled)
            actionButtons.padding(.top, EdgeDeckGeom.actionTop)
        }
        .frame(width: EdgeDeckGeom.tabWidth, alignment: .top)
    }

    /// 竞品同一位置的两颗钮。图标用系统符号，语义直白：
    /// 展开箭头 = 回到完整便签墙，加号 = 新建（走全局捕获面板，不另造一套流程）。
    private var actionButtons: some View {
        // 这里的高度必须与 EdgeDeckGeom.actionBlockHeight 严格一致：
        // 常量少算 1pt，SwiftUI 就会把窗口撑大 1pt，几何断言立刻抓到。
        VStack(spacing: EdgeDeckGeom.actionGap) {
            edgeAction("macwindow", label: "打开随手贴") {
                onContextAction(.openWall)
            }
            edgeAction("plus", label: "新建便签") {
                onContextAction(.newNote)
            }
        }
    }

    private func edgeAction(_ symbol: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.dyn(0x3A3A3E, 0xE9E9ED))
                .frame(width: EdgeDeckGeom.actionSize, height: EdgeDeckGeom.actionSize)
                .background {
                    Circle()
                        .fill(Color.dyn(0xFFFFFF, 0x25252A, lightAlpha: 0.80, darkAlpha: 0.68))
                        .overlay {
                            Circle().strokeBorder(
                                Color.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.12),
                                lineWidth: 1)
                        }
                }
                .shadow(color: .black.opacity(0.16), radius: 4,
                        x: side == .right ? -1 : 1, y: 2)
        }
        .buttonStyle(.plain)
        .help(label)
    }

    /// 一键复制整张便签：文字用当前草稿（可能还没写回 store），图片用原图。
    /// 边缘面板此前没有任何复制入口，想拷走一条码只能全选再 ⌘C，图片更没路。
    private func copyCurrent(_ note: Note) {
        let r = NoteCopy.copy(note, text: model.draft)
        ToastCenter.shared.show(r.toast)
    }

    private func noteBody(note: Note?, paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let note, !note.tag.isEmpty {
                    Text(note.tag)
                        .font(.ui(10.5, .medium))
                        .foregroundStyle(paper.ink.opacity(0.55))
                }
                Spacer()
                if let note {
                    Text(TimeLabel.card(note.updatedAt))
                        .font(.ui(10.5))
                        .foregroundStyle(paper.ink.opacity(0.38))
                }
                if let note {
                    Button { copyCurrent(note) } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(paper.ink.opacity(0.45))
                            .frame(width: 19, height: 19)
                            .background(Circle().fill(paper.ink.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("复制便签（文字 + 图片）")
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(paper.ink.opacity(0.45))
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(paper.ink.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            if RenderFlags.snapshot {
                Text(model.draft)
                    .font(.ui(14.5))
                    .foregroundStyle(paper.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                // 和主界面一样用自托管文本框：抽出面板每次 onEdit 都会写回 store，
                // 用 SwiftUI TextEditor 的话，中文输入法组合期间这次发布就会把拼音抹掉。
                PlainTextEditor(text: $model.draft, fontSize: 14.5, ink: paper.ink,
                                focusOnAppear: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: model.draft) { _, newValue in onEdit(newValue) }
            }

            HStack {
                Text("Esc 收起")
                    .font(.ui(10))
                    .foregroundStyle(paper.ink.opacity(0.30))
                Spacer()
                Text("已保存")
                    .font(.ui(10.5, .medium))
                    .foregroundStyle(paper.ink.opacity(0.55))
                    .opacity(model.flashSaved ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: model.flashSaved)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // 抽出后这张纸不再贴屏幕边（签列在它外侧），所以四角都是圆角：
            // 贴边侧留平角会露出「被切断」的直角，正是上一版透明边框的观感来源之一
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(paper.paper)
        )
        // 抽出面板的影子可以厚一点：它是三态里唯一「浮起来」的东西。
        // 半径按 EdgeDeckGeom 里的常量走，衬边是它的两倍，影子在窗口内自然衰减到 0。
        .shadow(color: .black.opacity(0.34), radius: EdgeDeckGeom.noteShadowRadius,
                x: side == .right ? -EdgeDeckGeom.noteShadowDX : EdgeDeckGeom.noteShadowDX,
                y: 4)
    }

    /// 中文竖排：逐个字符堆叠。SwiftUI 没有 writing-mode，
    /// 旋转 90° 会把汉字躺倒——堆叠才是「竖排」，旋转只是「横放」。
    private func verticalChars(_ s: String, ink: Color, size: CGFloat = 11) -> some View {
        VStack(spacing: 1) {
            ForEach(Array(s.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(ink)
            }
        }
    }
}

// MARK: - Note 标题

extension Note {
    /// 边缘纸签上的标题：第一行非空文字；纯图片便签给固定名
    var edgeTitle: String {
        let line = text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let line {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return image != nil ? "图片便签" : "空便签"
    }
}
