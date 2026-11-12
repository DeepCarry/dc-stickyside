import SwiftUI
import AppKit

/// 这套工程用经典属性包装器（@StateObject / @ObservedObject），
/// 因此需要手动把 ObservableObject 的字段转成 Binding，而不是用 @Bindable。
extension ObservableObject {
    func bind<T>(_ keyPath: ReferenceWritableKeyPath<Self, T>) -> Binding<T> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0 }
        )
    }
}

/// 离屏渲染时置为 true：AppKit 支撑的控件（TextEditor/TextField/Menu）在 ImageRenderer 里
/// 会画成禁止符，快照时用等价外观的纯 SwiftUI 视图替代。
enum RenderFlags {
    nonisolated(unsafe) static var snapshot = false
}

// MARK: - 窗口探针

/// 从视图树里反查它所在的 NSWindow。
/// 不能直接用 `NSApp.keyWindow`：sheet 是独立窗口，`onAppear` 触发时 key 窗口
/// 往往还指在父窗口上，拿它去处理 sheet 里的滚动条会一个都扫不到。
struct WindowProbe: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { weak var window: NSWindow? }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { [weak v] in
            guard let w = v?.window else { return }
            context.coordinator.window = w
            onWindow(w)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let w = nsView.window, w !== context.coordinator.window else { return }
        context.coordinator.window = w
        onWindow(w)
    }
}

// MARK: - 输入框占位（原生绘制）

/// 占位文案 + 「框里到底有没有字」的探针，合成一个纯 AppKit 视图。
///
/// ⚠️ 这里绝不能用 `@State` / `@Published` 驱动占位显隐。
/// 输入法组合（`setMarkedText`）期间，SwiftUI 侧的 binding 仍是空串；探针一旦
/// 发布「有内容」，SwiftUI 就重算整棵含 `TextEditor` 的视图树：一来 ZStack 的
/// 条件子视图数量变化会改变 TextEditor 的结构身份，二来重算会把空 binding 写回
/// `NSTextView`——用户刚敲的拼音字母当场被抹掉（v0.9 的输入法回归）。
/// 所以占位文案改由 NSView 自己画，探针只改一个 Bool 后 needsDisplay，
/// 全程不经过 SwiftUI，TextEditor 完全不会被打扰。
///
/// 顺带解决另一半需求：组合文本在 `NSTextView.string` 里，靠它判断「已经在打字」，
/// 提示该收就收。`NSText.didChangeNotification` 在 `setMarkedText` 时实测 fired = 0，
/// 所以仍用短轮询，但轮询结果只在 AppKit 内部消费。
struct EditorPlaceholder: NSViewRepresentable {
    let text: String
    let color: Color
    let fontSize: CGFloat

    func makeNSView(context: Context) -> EditorPlaceholderView {
        let v = EditorPlaceholderView()
        v.configure(text: text, color: color, fontSize: fontSize)
        return v
    }

    func updateNSView(_ v: EditorPlaceholderView, context: Context) {
        // 只在标签/纸色真的变了时被 SwiftUI 调用；打字期间一次都不会来
        v.configure(text: text, color: color, fontSize: fontSize)
    }

    static func dismantleNSView(_ v: EditorPlaceholderView, coordinator: ()) {
        v.stop()
    }
}

@MainActor
final class EditorPlaceholderView: NSView {
    /// 与 SwiftUI 一致：左上角为原点，占位才能按 textOrigin 直接定位
    override var isFlipped: Bool { true }
    /// 占位只是画上去的一层，点击、光标、拖拽全部穿透给下面的 TextEditor
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var placeholder = ""
    private var ink = NSColor.placeholderTextColor
    private var font = NSFont.systemFont(ofSize: 15, weight: .regular)
    private weak var textView: NSTextView?
    private var timer: Timer?
    /// 只读给自检用：`--imetest` 会验证组合输入时它确实翻成 true
    private(set) var hasContent = false

    func configure(text: String, color: Color, fontSize: CGFloat) {
        placeholder = text
        ink = NSColor(color)
        font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        needsDisplay = true
        refresh()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !hasContent, !RenderFlags.snapshot else { return }
        let o = EditorMetrics.textOrigin
        (placeholder as NSString).draw(
            at: NSPoint(x: o.width, y: o.height),
            withAttributes: [.font: font, .foregroundColor: ink])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, timer == nil else { return }
        // 60ms：第一个拼音字母要在下一帧前把提示收掉，又不必每敲一下都刷整棵树
        let t = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // .common：滚动、菜单弹出时也继续跑
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        super.viewWillMove(toWindow: newWindow)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        textView = nil
    }

    private func refresh() {
        if textView == nil { textView = Self.findTextView(near: self) }
        guard let tv = textView else { return }
        // hasMarkedText 兜底：个别输入法把组合串放在 marked range 而非 string 里
        let value = !tv.string.isEmpty || tv.hasMarkedText()
        guard value != hasContent else { return }
        hasContent = value
        needsDisplay = true
    }

    /// 从自己所在的父链里就近找 TextEditor 的 NSTextView，找不到再退回整窗扫描。
    /// 只认 NSScrollView 里的可编辑多行视图，搜索框那种单行 field editor 不会误判。
    static func findTextView(near view: NSView) -> NSTextView? {
        var ancestor = view.superview
        while let a = ancestor {
            if let tv = firstTextView(in: a) { return tv }
            ancestor = a.superview
        }
        if let root = view.window?.contentView, let tv = firstTextView(in: root) { return tv }
        return nil
    }

    private static func firstTextView(in root: NSView) -> NSTextView? {
        if let sv = root as? NSScrollView,
           let tv = sv.documentView as? NSTextView, tv.isEditable { return tv }
        for sub in root.subviews {
            if let tv = firstTextView(in: sub) { return tv }
        }
        return nil
    }
}

// MARK: - 自己托管的纯文本编辑器

/// 替代 SwiftUI `TextEditor`。
///
/// SwiftUI 的 `TextEditor` 每次 `updateNSView` 都会做
/// `if tv.string != binding { tv.string = binding }`，**不看 `hasMarkedText()`**。
/// 输入法组合期间 binding 还是空串，于是只要视图树因任何原因重算（占位探针轮询、
/// Toast、store 刷新……），刚敲的拼音字母就被这一行抹掉。`.equatable()` 实测也挡不住。
/// 这里自己托管 NSTextView，只在外层 binding 的值**确实变了**时才写回，
/// 并且组合态一律不写。这是唯一能从源头关掉问题的做法。
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let ink: Color
    var focusOnAppear = false

    func makeCoordinator() -> PlainTextCoordinator {
        PlainTextCoordinator(binding: $text)
    }

    func makeNSView(context: Context) -> PlainTextScrollView {
        let sv = PlainTextScrollView()
        sv.drawsBackground = false
        sv.backgroundColor = .clear
        sv.contentView.drawsBackground = false
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.borderType = .noBorder

        let tv = NSTextView(frame: NSRect(x: 0, y: 0,
                                          width: sv.contentSize.width,
                                          height: sv.contentSize.height))
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: sv.contentSize.width,
                                                  height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.font = .systemFont(ofSize: fontSize, weight: .regular)
        tv.textColor = NSColor(ink)
        tv.string = text
        tv.delegate = context.coordinator

        sv.documentView = tv
        sv.focusOnAppear = focusOnAppear
        context.coordinator.textView = tv
        context.coordinator.lastSynced = text
        return sv
    }

    func updateNSView(_ sv: PlainTextScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        let coord = context.coordinator
        coord.binding = $text

        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        if tv.font != font { tv.font = font }
        let color = NSColor(ink)
        if tv.textColor != color { tv.textColor = color }

        // ① 外层值没变（Toast / store / 主题等引起的重算）→ 一个字都不碰
        // ② 正在输入法组合 → 一个字都不碰
        // ③ 只有外部真的改了正文（清空草稿、解锁载入等）才同步进去
        guard text != coord.lastSynced, !tv.hasMarkedText() else { return }
        coord.lastSynced = text
        if tv.string != text { tv.string = text }
    }

    static func dismantleNSView(_ sv: PlainTextScrollView, coordinator: PlainTextCoordinator) {
        (sv.documentView as? NSTextView)?.delegate = nil
    }
}

final class PlainTextScrollView: NSScrollView {
    var focusOnAppear = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, let tv = documentView as? NSTextView else { return }
        DispatchQueue.main.async { [weak self, weak tv] in
            guard let w = self?.window, let tv else { return }
            w.makeFirstResponder(tv)
        }
    }
}

@MainActor
final class PlainTextCoordinator: NSObject, NSTextViewDelegate {
    var binding: Binding<String>
    var lastSynced: String
    weak var textView: NSTextView?

    init(binding: Binding<String>) {
        self.binding = binding
        self.lastSynced = binding.wrappedValue
        super.init()
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        // 组合态的拼音不进草稿：否则按 ⌘↩ 会把 "ni'hao" 存成便签
        guard !tv.hasMarkedText() else { return }
        let value = tv.string
        lastSynced = value
        if binding.wrappedValue != value { binding.wrappedValue = value }
    }
}

/// 系统「总是显示滚动条」时，TextEditor 会在右侧画一根直角深色竖条。
/// 在深色卡片上这跟设计完全不搭。这里把 App 内所有 NSScrollView 改成 overlay 样式：
/// 静止时不画，滚动/输入时才浮出，滚完淡出。
@MainActor
enum ScrollChrome {
    static func soften(_ view: NSView?) {
        guard let view else { return }
        if let sv = view as? NSScrollView {
            if sv.scrollerStyle != .overlay { sv.scrollerStyle = .overlay }
            if !sv.autohidesScrollers { sv.autohidesScrollers = true }
            // 文本编辑器不要滚动条。它是 NSTextView 套在 NSScrollView 里，
            // 那个 scroller 一闪出来就是一条直角白块，在浅色主题的纸上比正文还显眼；
            // 而且 overlay 样式对它不生效，只能直接关掉。滚轮照样能滚。
            if sv.documentView is NSTextView {
                if sv.hasVerticalScroller { sv.hasVerticalScroller = false }
                // 滚动视图自己不要画底：它那块白色背景会在纸上留一条竖白条
                if sv.drawsBackground { sv.drawsBackground = false }
            }
        }
        for sub in view.subviews { soften(sub) }
    }

    private static var started = false

    /// 扫一遍窗口里的滚动视图。TextEditor 内部的 NSScrollView 是 SwiftUI
    /// 延后建出来的，一次扫不干净，所以按几拍补扫（成本可以忽略）。
    static func scheduleSoften(_ win: NSWindow?) {
        guard let win else { return }

        for delay in [0.05, 0.3, 0.8, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { soften(win.contentView) }
            }
        }
    }

    static func startWatching() {
        guard !started else { return }
        started = true
        // 监听建立时窗口往往已经是 key 了，didBecomeKey 早就发过——
        // 之前只挂通知、不扫现存窗口，结果这段代码一次都没执行过。
        NSApp.windows.forEach(scheduleSoften)

        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { note in
            MainActor.assumeIsolated { scheduleSoften(note.object as? NSWindow) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.windows.forEach(scheduleSoften) }
        }
    }
}


/// NSTextView 自带 textContainerInset.width + lineFragmentPadding（默认 5pt），
/// 裸排的占位文案不做同样内缩时，光标会压在占位字上。
/// 数值不猜：首次拿到真实 NSTextView 时回填（见 CaptureController.focusText），
/// 订阅了本对象的视图会随之刷新。
@MainActor
final class EditorMetrics: ObservableObject {
    static let shared = EditorMetrics()

    /// 文字（含占位）的起点，相对输入框左上角的偏移（`--cursortest` 像素实测）。
    ///
    /// 现在是 0：正文改由 PlainTextEditor 自己托管的 NSTextView 画，
    /// `textContainerInset` 与 `lineFragmentPadding` 都归零，字形就从 (0,0) 起；
    /// 占位也是 AppKit 的 NSString 直接绘制，两者共用同一套字形度量。
    /// 之前用 SwiftUI TextEditor 时是 (-1.5,-0.5)——SwiftUI 会把内容往左上推，
    /// 而占位是 SwiftUI Text，只能靠这个偏移去凑；换成原生编辑器后继续用旧值
    /// 反而会让提示比光标左 1.5pt、上 0.5pt（--cursortest 实测 dx=3px dy=1px@2x）。
    static let textOrigin = CGSize.zero

    @Published var insetH: CGFloat = 3
}

/// 每个需要局部状态的视图各自持有一个，替代不可用的 @State。
final class UIBox<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
