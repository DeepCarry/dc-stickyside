import SwiftUI
import AppKit

// MARK: - 状态

@MainActor
final class CaptureModel: ObservableObject {
    @Published var text: String = ""
    @Published var paper: Paper = .yellow
    @Published var tag: String = "灵感"
    @Published var image: NSImage? = nil
    @Published var pinned: Bool = false
    @Published var hint: String = ""
    @Published var clipboardHasImage: Bool = false
    /// 存到哪面墙。给默认值而不是留空：面板里必须能看见「存到哪儿」，否则用户会以为进了「全部」。
    @Published var wallID: UUID? = nil
    @Published var walls: [Wall] = []

    func reset() {
        text = ""
        image = nil
        hint = ""
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && image == nil
    }

    var wallName: String {
        walls.first { $0.id == wallID }?.name ?? "选择墙"
    }
}

// MARK: - 面板

final class CapturePanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 566, height: 240),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        // 阴影必须关掉：透明内容 + 无边框窗口时，系统按窗口矩形画方形阴影，
        // 四个直角会压在圆角卡片外面（看起来像角缺失）。阴影由 SwiftUI 自绘。
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onKeyDown?(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                    isARepeat: false, keyCode: 53)!)
    }
}

// MARK: - 控制器

@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private var panel: CapturePanel?
    private var monitor: Any?
    let model = CaptureModel()
    private weak var store: AppStore?

    func attach(store: AppStore) {
        self.store = store
    }

    func show() {
        guard let store else { return }
        // 墙列表每次唤起都刷新：面板可能开着的时候在别处新建了墙
        model.walls = store.walls.sorted { $0.sortOrder < $1.sortOrder }
        model.wallID = store.selectedWallID ?? model.walls.first?.id
        model.paper = .yellow
        model.clipboardHasImage = ImageStore.pasteboardHasImage()
        model.hint = model.clipboardHasImage ? "⌘V 粘贴截图" : ""

        if panel == nil { buildPanel() }
        guard let panel else { return }

        // 捕获面板是独立 NSPanel，不在主窗口的 preferredColorScheme 树里，
        // 外观得单独下发，否则主窗口切成浅色、这个浮窗还是深色。
        panel.appearance = store.appearance.nsAppearance

        resize()
        restorePosition()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focusText()
        installMonitor()
    }

    func hide() {
        // 关掉之前记下位置：下次唤起还在原处，不用每次重新找
        if let panel, panel.isVisible, let store {
            store.captureFrame = panel.frame
        }
        panel?.orderOut(nil)
        removeMonitor()
        model.reset()
    }

    private func buildPanel() {
        let p = CapturePanel()
        let view = CaptureView(model: model,
                               onSave: { [weak self] in self?.save() },
                               onClose: { [weak self] in self?.close() },
                               onPaste: { [weak self] in self?.pasteImage() },
                               onImageChange: { [weak self] in self?.adoptDroppedImage() })
        let host = NSHostingView(rootView: view)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.onKeyDown = { [weak self] event in
            guard let self else { return false }
            return self.handleKey(event)
        }
        panel = p
    }

    private func resize() {
        guard let panel else { return }
        let height: CGFloat = model.image == nil ? 236 : 372
        var frame = panel.frame
        frame.size = NSSize(width: 566, height: height)
        panel.setFrame(frame, display: true)
    }

    /// 上次的位置还能用就沿用；否则回到屏幕中央偏上。
    /// 「能用」= 至少有一块屏幕看得见它，避免拔掉外接屏后窗口落在不存在的坐标上。
    private func restorePosition() {
        guard let panel else { return }
        let size = panel.frame.size
        if let saved = store?.captureFrame {
            let rect = NSRect(origin: saved.origin, size: size)
            let onScreen = NSScreen.screens.contains { screen in
                screen.visibleFrame.insetBy(dx: 40, dy: 40).intersects(rect)
            }
            if onScreen {
                panel.setFrame(NSRect(origin: saved.origin, size: size), display: false)
                return
            }
        }
        positionOnScreen()
    }

    private func positionOnScreen() {
        guard let panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        let x = vf.midX - size.width / 2
        // 略高于正中：视线自然落点，且不遮挡正在看的内容
        let y = vf.minY + vf.height * 0.56
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func focusText() {
        guard let panel, let content = panel.contentView else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            ScrollChrome.soften(content)   // 编辑器建好后立刻去掉常驻滚动条
            if let tv = Self.findTextView(in: content) {
                panel.makeFirstResponder(tv)
            }
        }
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // Esc：有内容存草稿，没内容直接关
        if event.keyCode == 53 {
            if model.isEmpty { hide() } else { save() }
            return true
        }
        // ⌘↩ 保存
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            save()
            return true
        }
        // ⌘⇧P 钉住
        if event.modifierFlags.contains([.command, .shift]), event.keyCode == 35 {
            model.pinned.toggle()
            return true
        }
        // ⌘V 粘图
        if event.modifierFlags.contains(.command), event.keyCode == 9,
           ImageStore.pasteboardHasImage() {
            pasteImage()
            return true
        }
        // ⌘E：从「随手记一张」升级成「去墙上整理」
        if event.modifierFlags.contains(.command), event.keyCode == 14 {
            expand()
            return true
        }
        return false
    }

    private func pasteImage() {
        guard let img = ImageStore.imageFromPasteboard() else { return }
        model.image = img
        model.hint = "已粘贴 1 张图片"
        resize()
        restorePosition()
    }

    /// 拖进面板的图片：和粘贴走同一条路，只是来源不同
    private func adoptDroppedImage() {
        model.hint = "已加入 1 张图片"
        resize()
        restorePosition()
    }

    private func expand() {
        hide()
        AppDelegate.bringWallToFront()
    }

    func save() {
        guard let store, !model.isEmpty else { close(); return }
        var noteImage: NoteImage? = nil
        if let img = model.image {
            noteImage = ImageStore.save(img)
        }
        // 选了「待办」：每行自动变成可勾选项
        var text = model.text
        if model.tag == "待办" {
            text = Checklist.asTodoList(text)
        }
        store.add(text: text, paper: model.paper, tag: model.tag,
                  image: noteImage, wallID: model.wallID)
        if model.pinned {
            model.reset()
            model.clipboardHasImage = ImageStore.pasteboardHasImage()
            model.hint = "已保存"
            resize()
            focusText()
        } else {
            // 面板马上就消失，不给一点点反馈会让人怀疑到底存没存上。
            // 停 0.32s 再收：短到不挡事，长到眼睛能捕捉到。
            model.hint = "已保存"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                self?.hide()
            }
        }
    }

    private func close() {
        hide()
    }
}

// MARK: - 界面

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    var onSave: () -> Void
    var onClose: () -> Void
    var onPaste: () -> Void
    var onImageChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            editor
            if let img = model.image { attachment(img) }
            footer
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(T.float)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(T.lineStrong, lineWidth: 1)
                )
                // 阴影必须完全落在下面的 padding 内自然淡出：
                // padding(24) > radius(12) + 位移(5) + 模糊尾部，否则会被窗口边缘硬切，
                // 看起来就是卡片外面多了一圈半透明边框 + 右下角一块深色。
                .shadow(color: Color.dyn(0x000000, 0x000000, lightAlpha: 0.18, darkAlpha: 0.42), radius: 12, y: 5)
        )
        .padding(24)
        .background(dropSurface)
    }

    /// 拖图进来：和 ⌘V 等价，只是省了一次复制粘贴。
    /// 只接文件 URL 与图片数据，不接文本——文本拖进来会变成一条没有内容的空便签。
    /// 离屏渲染时整块 onDrop 会画成黄色占位，所以截图路径不挂它。
    @ViewBuilder
    private var dropSurface: some View {
        if RenderFlags.snapshot {
            EmptyView()
        } else {
            Color.clear.onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                ImageStore.loadImage(from: provider) { img in
                    guard let img else { return }
                    model.image = img
                    onImageChange()
                }
                return true
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Text("新便签")
                .font(.ui(11.5, .medium))
                .foregroundStyle(T.textDim)
            ForEach(["灵感", "想法", "待办", "资料"], id: \.self) { t in
                Button {
                    model.tag = t
                } label: {
                    Text(t)
                        .font(.ui(11))
                        .foregroundStyle(model.tag == t ? T.accent : T.textFaint)
                        .frame(height: 22)
                        .padding(.horizontal, 8)
                        .background(
                            Capsule().fill(model.tag == t ? T.accent.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain).handCursor()
            }
            Spacer()
            if model.pinned {
                Label("已钉住", systemImage: "pin.fill")
                    .font(.ui(10.5))
                    .foregroundStyle(T.accent)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(T.textFaint)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(T.inset))
            }
            .buttonStyle(.plain).handCursor()
        }
        .padding(.bottom, 10)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if RenderFlags.snapshot {
                if model.text.isEmpty {
                    Text(model.tag == "待办"
                         ? "每行一条待办，保存后自动变成可勾选项"
                         : "记下点什么…")
                        .font(.ui(16))
                        .foregroundStyle(T.textFaint)
                        // 与 TextEditor 的文字起点对齐，否则光标压在占位字上
                        .offset(x: EditorMetrics.textOrigin.width, y: EditorMetrics.textOrigin.height)
                }
                Text(model.text)
                    .font(.ui(16))
                    .foregroundStyle(T.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 76, alignment: .topLeading)
            } else {
                EditorPlaceholder(
                    text: model.tag == "待办"
                          ? "每行一条待办，保存后自动变成可勾选项"
                          : "记下点什么…",
                    color: T.textFaint,
                    fontSize: 16)
                    .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76,
                           alignment: .topLeading)
                    .allowsHitTesting(false)
                PlainTextEditor(text: $model.text, fontSize: 16, ink: T.text)
                    .frame(height: 76)
            }
        }
    }

    private func attachment(_ img: NSImage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 136, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    Button {
                        model.image = nil
                        model.hint = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain).handCursor()
                    .padding(5)
                }
            Text("图片会作为这张便签的一部分保存")
                .font(.ui(10.5))
                .foregroundStyle(T.textFaint)
                .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            wallPicker
            paperTrack
            Spacer(minLength: 8)
            if !model.hint.isEmpty {
                Text(model.hint)
                    .font(.ui(10.5))
                    .foregroundStyle(T.textFaint)
            }
            Text("⌘ ↩")
                .font(.ui(10.5))
                .foregroundStyle(T.textFaint)
            Button(action: onSave) {
                Text("保存")
            }
            .buttonStyle(PillButtonStyle(bg: T.accent, fg: T.accentInk, height: 28, hPad: 16)).handCursor()
            .disabled(model.isEmpty)
            .opacity(model.isEmpty ? 0.5 : 1)
        }
        .padding(.top, 14)
    }

    /// 存到哪面墙。只有一面墙时退化成纯标签，避免一个点了没反应的菜单。
    @ViewBuilder
    private var wallPicker: some View {
        if RenderFlags.snapshot || model.walls.count <= 1 {
            wallChip
        } else {
            Menu {
                ForEach(model.walls) { w in
                    Button {
                        model.wallID = w.id
                    } label: {
                        Label(w.name, systemImage: model.wallID == w.id ? "checkmark" : "square.stack")
                    }
                }
            } label: { wallChip }
            .menuStyle(.borderlessButton).handCursor()
            .menuIndicator(.hidden)
            .fixedSize()
            .help("选择存到哪面墙")
        }
    }

    private var wallChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.stack")
                .font(.system(size: 9.5, weight: .medium))
            Text(model.wallName)
                .font(.ui(11))
                .lineLimit(1)
            if model.walls.count > 1 {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
        }
        .foregroundStyle(T.textDim)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.inset)
        )
    }

    private var paperTrack: some View {
        HStack(spacing: 0) {
            ForEach(Paper.allCases) { p in
                Button {
                    model.paper = p
                } label: {
                    PaperSwatch(paper: p, ink: .white, selected: model.paper == p,
                                side: 15, cell: 22, ringOpacity: 0.88)
                }
                .buttonStyle(.plain).handCursor()
                .help(p.title)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}
