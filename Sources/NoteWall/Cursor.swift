import SwiftUI
import AppKit

// MARK: - 可点击区域的「手型光标」

/// SwiftUI 在 macOS 上默认不给 `Button` / `Menu` / `Picker` / `onTapGesture`
/// 换光标：鼠标移上去还是箭头，看起来不像能点。
///
/// **为什么不用 cursor rect**（上一版的做法，实际不生效）：
/// `addCursorRect` 依赖窗口把 `cursorUpdate` 派发给「光标下的那个视图」，
/// 而 SwiftUI 的按钮在 AppKit 层是私有代理视图，会盖住背景垫片；实测在
/// `Button` 上无论 `background` 还是 `overlay` 都不亮手型，只有在普通
/// `Color` 上管用。`.onHover` / `NSTrackingArea` 同样依赖事件真正派发到窗口，
/// 在测试里也无法稳定复现。
///
/// 现在的做法：**只读真实鼠标位置**（`NSEvent.mouseLocation`），每 40ms 判断
/// 一次「当前点是否落在某个可点击区域内」。不依赖任何事件派发，行为可预测、
/// 可自动化验证。只在「进入 / 离开」的瞬间改光标，不在区域内反复写，避免和
/// 输入框的 I 形光标打架。
///
/// ## 为什么「进入立刻、离开要慢」（v0.9.11 修点击闪烁）
///
/// 点一下纸签，边缘面板同时做三件事：
/// 1. `pull()` 里 `makeKey()` 抢键盘（窗口从非 key 变 key）；
/// 2. 窗口 frame 做 0.24s 的 `animator().setFrame` 动画（fan 窄窗 → pull 宽窗）；
/// 3. SwiftUI 把 `.fan` 的整棵视图树换成 `.pull`，签列垫片**销毁再重建**。
///
/// 这三件事都会让「当前点是否落在垫片上」在几十到几百毫秒里反复真假：
/// 重建的那一帧垫片登记表是空的、窗口动画中 `windowNumber(at:)` 会在我们自己的
/// 两个窗口之间跳。原来的判定是「这一帧没命中就立刻变箭头」，于是光标被来回拨，
/// 人眼看到的就是手型和箭头在打架。
///
/// 对策是给状态机加**迟滞**：
/// - 进入：命中即变，不延迟（要跟手）；
/// - 离开：**鼠标自己动了**、且连续 `leaveTicks` 帧（默认 4 帧 ≈ 160ms）都不命中，
///   才回箭头。手指没动的时候，布局怎么变都不切——这一条是治闪烁的关键：
///   窗口变宽、视图树重建都会让「当前点还在不在垫片上」短暂为假，
///   但用户的手没动，光标就不该动；
/// - 鼠标键按着的时候不拨（点击那一下本来就只有一两百毫秒）；
/// - 布局动画期间由控制器 `hold()` 住（见 `EdgeDeckController.pull`）。
///
/// ## 为什么还不够（v0.9.14 补的第二层）
///
/// 上面那套把「我们自己的状态机」修好了，但用户仍然看到箭头/手型互闪。
/// 根因在**状态机之外**：屏幕上的光标归 WindowServer 管，AppKit 的 cursor rect
/// 会在鼠标移动、窗口变 key、frame 动画重排时把光标洗回箭头；我们进程里的
/// `NSCursor.current` 一直是手型，所以只断言状态机（旧 `--edgeclicktest`）
/// 永远测不到。25Hz 轮询下一帧才补回来，中间那 0~40ms 就是肉眼看到的一次闪。
///
/// 现在改成**事件驱动**：本地/全局事件监视器在每个鼠标事件处理完之后
/// 立刻重申一次手型（同一 runloop turn），不再跟 AppKit 隔着 40ms 互相拨。
/// 同时把「上次命中的矩形」改成**按位置**、不再按「鼠标动没动」来兜：
/// 点击时手会抖 1~2pt，旧实现会因为 `moved` 为真而丢掉这块记忆。
///
/// 逻辑本身抽成纯结构体，好让 `--cursortest` 不依赖真鼠标就能断言
/// 「瞬间未命中不会造成闪烁」。
///
/// ## v0.9.15：边缘悬浮窗口停用手型
///
/// 上面三层把「闪烁」压到了测试全绿，但真机上 floating 面板（nonactivatingPanel、
/// 窗口动画、SwiftUI 视图树重建）仍会和 WindowServer 的光标管理偶发打架。
/// 用户拍板：边缘窗口不再换手型，保持系统默认光标——`EdgeDeck` 已不再注册
/// 垫片。本文件的手型机制只服务主窗口 / 面板 / Sheet / 便签槽等普通窗口，
/// 那些窗口不做 frame 动画，不存在竞争源。
///
/// ## v0.9.16：停用手型后「点一下还是变手」的根因
///
/// v0.9.15 只摘了垫片，却漏了 tick 里的**点击宽限期粗判**：任何真实点击都会
/// 通过 `noteClick` 设 `holdUntil`，而粗判在「hold 期内 + 指针落在 floating
/// 窗口内」时**不看有没有垫片**直接把 hit 判真 → 手型亮起，事件监视器 reassert
/// 又与 AppKit 互拨——用户看到的就是「点一下变手，然后开始闪」。
/// 更隐蔽的是：v0.9.15 的 `--clickfliptest` 全绿是**假绿**——没有垫片注册时
/// 轮询 timer 从不启动，tick 根本不在跑，粗判永远轮不到执行。测试已补上
/// 「活垫片在场」的前提。现在：
/// - 命中只能来自真实垫片或 sticky 记忆，没有第三条凭空判真的路；
/// - EdgePanel 窗口里的垫片一律不命中（防回归闸）。
///
/// ## v0.9.17：手型是从边缘面板「下面」漏上来的
///
/// v0.9.16 之后真机仍复现：悬停边缘面板会亮手型、点击时箭头/手型互闪。
/// 根因不在边缘窗口自己（它确实一张垫片都没注册），而在命中判定只问
/// 「点落在哪个垫片的屏幕矩形里」，不问「那个垫片在不在最上面」：
/// 边缘面板是 floating 层、盖在主窗口之上，只要主窗口有按钮垫片正好位于
/// 面板 footprint 之下（扇开时约 54pt 宽、抽出时约 388pt 宽，太常见了），
/// 指着面板就等于指着那张被盖住的垫片 → hit=true → 手型亮起；点击时
/// `pull()` 改 frame、垫片跟着移位，hit 帧帧翻转，reassert 又与 AppKit
/// 的 cursor rect 互拨——正是用户看到的整套症状。`--clickfliptest` 没测到，
/// 是因为它的对照垫片远离面板、面板底下没有任何垫片。
///
/// 修法（用户拍板：边缘窗口全程默认光标，不再尝试把手型修好）：
/// - tick 开头先判「指针处最上层窗口是不是 EdgePanel」：是 → 手型系统
///   整体退出本帧——清 sticky、状态机复位、光标落回默认（抽出态文本区
///   仍走 I 形，那是编辑器的默认光标，不是手型）；
/// - reassert 同样加这道闸：指针在边缘面板上时不许把手型钉回去；
/// - 命中枚举再补一层遮挡过滤：被 EdgePanel 盖住的垫片不算命中。
/// 三层下去，无论面板底下压着什么垫片，边缘窗口上都没有手型的点亮路径。
struct HandCursorLogic {
    enum Action: Equatable { case none, toHand, toArrow }

    /// 离开去抖帧数（tick 40ms 一次，4 帧 ≈ 160ms）
    var leaveTicks = 4
    private(set) var isHand = false
    private(set) var missStreak = 0
    /// 自上次命中以来，鼠标有没有真的动过。
    /// 注意是「动过一次」而不是「这一帧在动」——移到输入框之后手会停住，
    /// 若要求每帧都在动，离开判定就永远不成立（手型会卡在输入框上）。
    private(set) var movedSinceHit = false
    /// 在这之前即使未命中也保持手型（点击 / 窗口动画）
    private(set) var holdUntil: TimeInterval = 0

    /// - Parameters:
    ///   - hit: 这一帧鼠标点是否落在某个可点击垫片上
    ///   - mouseDown: 鼠标键是否按着
    ///   - moved: 鼠标位置相对上一帧是否真的动了（>2pt）。不动 = 不允许离开。
    mutating func step(hit: Bool, mouseDown: Bool, moved: Bool, now: TimeInterval) -> Action {
        if hit {
            missStreak = 0
            movedSinceHit = false
            guard !isHand else { return .none }
            isHand = true
            return .toHand
        }
        missStreak += 1
        if moved { movedSinceHit = true }
        guard isHand else { return .none }
        // 自上次命中以来手完全没动：视作布局抖动（窗口变宽 / 垫片重建 / 系统重排），
        // 不切。用户如果真的要走开，鼠标一定会动过，下面的判定就会成立。
        if !movedSinceHit { return .none }
        // 按着键（点击中 / 拖拽中）不切：点击本身会触发窗口与视图树变化，
        // 这时拨光标只会让人看到闪。
        if mouseDown { return .none }
        if now < holdUntil { return .none }
        guard missStreak >= leaveTicks else { return .none }
        isHand = false
        return .toArrow
    }

    mutating func hold(until t: TimeInterval) {
        holdUntil = max(holdUntil, t)
    }

    mutating func reset() {
        isHand = false
        missStreak = 0
        movedSinceHit = false
        holdUntil = 0
    }
}

@MainActor
final class HandCursorRegistry {
    static let shared = HandCursorRegistry()

    /// 弱引用：视图销毁后自动出列，不需要手工解绑（解绑也做了，双保险）
    private let views = NSHashTable<NSView>.weakObjects()
    private var timer: Timer?
    /// 当前是否由我们显示手型（状态机，避免每帧无脑 set）
    private var logic = HandCursorLogic()
    var isHand: Bool { logic.isHand }
    /// 诊断用：轮询跑过多少次
    private(set) var ticks = 0
    /// 诊断用：切到手型 / 切回箭头的次数（真机验收「没有反复拨」靠它）
    private(set) var handSwitches = 0
    private(set) var arrowSwitches = 0
    /// 上一帧鼠标位置：用来判断「手到底动没动」
    private var lastPoint = NSPoint(x: -1e6, y: -1e6)
    /// 诊断用：最后一帧的判定条件（测试失败时把这一行打出来就知道卡在哪）
    private(set) var lastTickDebug = ""
    /// 上一次命中时那个垫片的屏幕矩形。布局抖动（窗口变宽、垫片重建）会让
    /// 命中短暂为假，但只要手没动、点还落在这块矩形里，就继续算命中。
    private var lastHitScreenRect: NSRect?
    /// 强制把下一帧当成「动过」（收起面板、切 App 等状态跳变时用）
    private var forceMove = false
    /// 事件监视器：记录点击、并在事件末尾重申（兜底）
    private var eventMonitors: [Any] = []
    /// 主 runloop 观察者：每个事件处理完、runloop 即将休眠时同步补一次光标
    private var runloopObserver: CFRunLoopObserver?
    /// 诊断用：事件驱动重申了多少次 / 监视器收到多少事件
    private(set) var reasserts = 0
    private(set) var monitorEvents = 0

    private init() {
        // App 退到后台时立刻收手：否则光标会卡在手型
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { HandCursorRegistry.shared.releaseHand(force: true) }
        }
        installMouseMonitors()
        installRunLoopObserver()
    }

    /// `.beforeWaiting` 是「这一轮事件已经全部派发完」的同步时点：AppKit 的 cursorUpdate
    /// 处理完了，runloop 还没睡下。在这里补光标，既不会像本地监视器那样被后续派发盖掉，
    /// 也没有 `DispatchQueue.main.async` 那几个毫秒的空档（实测那段空档仍有 9/40 帧是箭头）。
    private func installRunLoopObserver() {
        // 同时监听 .exit：某些帧系统会补派一批延迟事件，runloop 没睡下就又跑了一轮，
        // 只挂 .beforeWaiting 会漏掉这一轮（实测 5 次里偶发 1 帧残留箭头）。
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        runloopObserver = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities, true, 0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reassert(force: false) }
        }
        if let runloopObserver {
            CFRunLoopAddObserver(CFRunLoopGetMain(), runloopObserver, .commonModes)
        }
    }

    /// AppKit 的 cursor rect 会在 mouseMoved / cursorUpdate / 窗口变 key 时把光标设回箭头。
    /// 本地监视器在事件派发**之前**调用，所以这里只排一个 async：等 AppKit 处理完这个事件，
    /// 再由我们补最后一笔。这样每个鼠标事件结束时屏幕上的光标都是手型，
    /// 不会出现「AppKit 设箭头 → 40ms 后轮询才补」那种肉眼可见的空档。
    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .cursorUpdate, .leftMouseDown, .leftMouseUp,
            .leftMouseDragged, .rightMouseDown, .rightMouseUp
        ]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.monitorEvents += 1
                self?.reassert(force: true)      // 派发前先补一笔（此时 AppKit 还没处理 cursor rect）
            }
            let down = event.type == .leftMouseDown || event.type == .rightMouseDown
            let up = event.type == .leftMouseUp || event.type == .rightMouseUp
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if down { self?.noteClick(down: true) }
                    if up { self?.noteClick(down: false) }
                    self?.reassert()
                }
            }
            return event
        } {
            eventMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.monitorEvents += 1 }
            let down = event.type == .leftMouseDown || event.type == .rightMouseDown
            let up = event.type == .leftMouseUp || event.type == .rightMouseUp
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if down { self?.noteClick(down: true) }
                    if up { self?.noteClick(down: false) }
                    self?.reassert()
                }
            }
        } {
            eventMonitors.append(global)
        }
    }

    /// 任何一次真实点击都给光标一个「不许拨回箭头」的宽限期。
    /// 不只 `pull()` 会换视图树：点关闭、点圆钮、点面板空白收起都会。
    /// 旧实现只在 `EdgeDeckController.pull` 里 `hold(0.6)`，其它点击路径完全没保护。
    /// 0.8s / 0.6s 覆盖：0.24s 窗口动画 + 0.3s SwiftUI spring + 视图树重建。
    private func noteClick(down: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        logic.hold(until: now + (down ? 0.8 : 0.6))
    }

    /// v0.9.16：边缘面板（EdgePanel）里的垫片一律不命中——边缘窗口已不再接手型，
    /// 这道闸保证以后谁误把 `.handCursor` 挂回 EdgeDeck 也不会生效。
    /// （上一个 bug 就是「没有任何垫片却被判命中」：点击宽限期粗判凭空把 hit 判真。）
    private func isEdgePanel(_ v: NSView) -> Bool {
        v.window is EdgePanel
    }

    /// v0.9.17：指针处最上层的窗口是不是边缘面板。
    /// tick 与 reassert 共用：只要面板压在最上面，手型系统就整体让位——
    /// 面板底下垫片的「命中」是隔着窗口漏上来的，不作数。
    private func isEdgePanelTopmost(at p: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        guard number > 0 else { return false }
        return NSApp.windows.contains { $0.windowNumber == number && $0 is EdgePanel }
    }

    /// 事件处理完之后重申：状态机还认定在可点区域上，就把光标钉回手型。
    ///
    /// **不要再加几何闸门**：点击时 SwiftUI 会销毁重建垫片，上次命中的矩形在那一两帧里
    /// 会被清掉；实测带闸门时 40 帧里仍有 10 帧停在箭头。状态机本身已经带迟滞，
    /// 就是「当前还该不该是手型」的唯一权威，再判一次只会引入第二个会抖的输入。
    /// - `force`：事件监视器走 true（不管 `NSCursor.current`，无条件补一次，
    ///   兜住「别的进程改了屏幕光标但我们进程里仍记着手型」这种分家状态）；
    ///   runloop 观察者走 false，只在真被改掉时才补，避免每轮 runloop 都发一次 CGS 调用。
    private func reassert(force: Bool = true) {
        guard logic.isHand else { return }
        // v0.9.17：指针在边缘面板上时不许重申手型（与 tick 的同名闸成对）
        if isEdgePanelTopmost(at: NSEvent.mouseLocation) { return }
        if !force, NSCursor.current === NSCursor.pointingHand { return }
        reasserts += 1
        NSCursor.pointingHand.set()
    }

    func register(_ v: NSView) {
        views.add(v)
        startTimer()
    }

    func unregister(_ v: NSView) {
        views.remove(v)
        guard views.allObjects.isEmpty else { return }
        // **不要立刻把光标拨回箭头**：点击纸签时 SwiftUI 会先销毁旧垫片、
        // 再建新垫片，中间隔了不止一帧。这里若马上 release，就是一次肉眼可见的闪烁。
        // 留给 tick 判定（它带 sticky 记忆和 4 帧去抖）：真离开会自己回箭头，
        // 新垫片则把状态接过去。只有长时间（1s）一个垫片都不剩，才认定
        // 「这里已经没有可点区域」，强制收手并停表。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.views.allObjects.isEmpty else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.releaseHand(force: true)
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common：滚动、菜单跟踪期间也继续跑
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 一次判定。
    ///
    /// **不能用 `NSApp.isActive` 当门槛**：屏幕边缘条是 `nonactivatingPanel`，
    /// 悬停它并不会让 App 变成前台，偏偏用户就是「在浏览器里干活，顺手去够边缘条」。
    /// 上一版因此在后台永远是箭头（用户直接拍到的就是这一种）。
    ///
    /// 现在的边界是「鼠标点上最上层的窗口是不是我们自己的」：别的 App 的窗口压在上面时
    /// 不误改光标；判「命中」则遍历本 App 所有可见窗口的垫片，不再要求系统报的那个
    /// `windowNumber` 恰好等于垫片所在窗口——点击纸签时面板会 `makeKey` 并变宽，
    /// 系统报的窗口会在我们自己的两个窗口之间跳，老实现因此每帧都判成「没命中」。
    func tick() {
        ticks += 1
        let p = NSEvent.mouseLocation
        // 6pt 门槛：点击时手会抖 1~2pt，那不算「用户要走开」；
        // 真的从纸签移进输入框或移出面板，位移至少十几 pt。
        let moved = forceMove
            || abs(p.x - lastPoint.x) > 6 || abs(p.y - lastPoint.y) > 6
        forceMove = false
        lastPoint = p

        // v0.9.17：指针在边缘面板上 → 手型系统整体退出这一帧，不走下面的
        // 迟滞判定（迟滞是给主窗口防抖的，在这里只会让手型多赖几帧）。
        // 面板底下压着的主窗口垫片会被无遮挡感知的命中判定算成命中，
        // 手型就是这么漏上来的（见 HandCursorLogic 上方的版本说明）。
        if isEdgePanelTopmost(at: p) {
            lastHitScreenRect = nil
            let wasHand = logic.isHand
            if wasHand {
                logic.reset()
                arrowSwitches += 1
            }
            // 状态机与真实光标分家时（进程内记着箭头、屏幕上却是手型）也一并纠正
            if wasHand || NSCursor.current === NSCursor.pointingHand {
                restoreCursorBelow(p)
            }
            lastTickDebug = "edgeTop=true hand=false p=\(Int(p.x)),\(Int(p.y))"
            return
        }

        // 别的 App 的窗口压在上面：立刻收（不看鼠标动没动，否则切 App 会卡住手型）
        let covered = isCovered(at: p)
        let found = covered ? nil : handView(atAnyScreenPoint: p)
        var hit = found != nil
        if let r = found?.rect {
            lastHitScreenRect = r
        } else if !hit, let r = lastHitScreenRect, r.insetBy(dx: -4, dy: -4).contains(p) {
            // 只按**位置**兜，不再要求「手没动」：点击时那 1~2pt 的抖动会让旧条件失效，
            // 于是垫片在视图树重建的空档里判假，状态机就拨回箭头 —— 这正是用户看到的闪。
            // 只要指针还落在上次命中的那块里，不管动没动，都算还指着它。
            hit = true
        }
        // 记忆只在实际离开这块矩形时清掉，不因为「这一帧动了」就丢
        if !hit, let r = lastHitScreenRect, !r.insetBy(dx: -4, dy: -4).contains(p) {
            lastHitScreenRect = nil
        }
        let down = NSEvent.pressedMouseButtons != 0
        let now = Date.timeIntervalSinceReferenceDate

        // v0.9.16：原来的「点击宽限期粗判」（holdUntil 内指针落在 floating 窗口就算命中）
        // 已删除——边缘窗口 v0.9.15 起不再接手型，而那段粗判会在**没有任何垫片**的情况下
        // 凭空把 hit 判真：点击纸签 → noteClick 给 hold → 粗判命中 → 手型亮起 →
        // 事件监视器 reassert 与 AppKit 互拨，正是用户看到的「点一下就变手然后闪」。
        // 命中只能来自真实垫片或 sticky 记忆，不许再有第三条凭空判真的路。
        lastTickDebug = "hit=\(hit) covered=\(covered) moved=\(moved) down=\(down) "
            + "miss=\(logic.missStreak) hand=\(logic.isHand) "
            + "holdLeft=\(String(format: "%.2f", logic.holdUntil - now)) "
            + "sticky=\(lastHitScreenRect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-") "
            + "p=\(Int(p.x)),\(Int(p.y)) last=\(Int(lastPoint.x)),\(Int(lastPoint.y))"

        switch logic.step(hit: hit, mouseDown: down, moved: moved || covered, now: now) {
        case .toHand:
            handSwitches += 1
            NSCursor.pointingHand.set()
        case .toArrow:
            arrowSwitches += 1
            restoreCursorBelow(p)
        case .none:
            // 不再在这里每 40ms 补一次：那是在跟 AppKit 隔着 40ms 互相拨。
            // 补光标的活交给事件监视器（reassert），跟每个鼠标事件同步发生。
            break
        }
    }

    /// 点击 / 窗口布局动画期间把光标钉住，别让它在这几百毫秒里被反复拨。
    func hold(_ seconds: TimeInterval) {
        logic.hold(until: Date.timeIntervalSinceReferenceDate + seconds)
    }

    /// 下一帧视为「鼠标动过」：收起面板、切屏这类状态跳变后需要重新判一次。
    func recheckNextTick() {
        forceMove = true
    }

    func releaseHand(force: Bool = false) {
        if !force { guard logic.isHand else { return } }
        let wasHand = logic.isHand
        logic.reset()
        forceMove = true
        if wasHand || force {
            if NSCursor.current === NSCursor.pointingHand { NSCursor.arrow.set() }
        }
    }

    // MARK: - 判定

    /// 鼠标点上最上层的窗口是不是我们自己的（是 → 返回它，可能为 nil 表示桌面）
    private func topOwnWindow(at p: NSPoint) -> NSWindow? {
        let number = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        return NSApp.windows.first { $0.windowNumber == number && $0.isVisible }
    }

    /// 鼠标点上最上层是别人的窗口吗。
    ///
    /// **不要用 `$0.isVisible` 参与判断**：窗口 frame 动画（`animator().setFrame`）期间
    /// 这个标志会短暂为 false，于是「我们自己正在变宽的面板」被判成「别人压在上面」，
    /// 而那条分支会立刻把光标拨回箭头——这正是点击闪烁的另一半原因。
    /// 只要 `windowNumber` 属于本 App 的任一窗口，就算没被盖住。
    private func isCovered(at p: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        guard number > 0 else { return false }
        return !NSApp.windows.contains { $0.windowNumber == number }
    }

    /// 任意本 App 可见窗口上的垫片是否命中。别的 App 的窗口压在上面时一律不命中。
    private func handView(atAnyScreenPoint p: NSPoint) -> (view: NSView, rect: NSRect)? {
        for case let v as NSView in views.allObjects {
            guard let win = v.window, win.isVisible, !v.isHiddenOrHasHiddenAncestor else { continue }
            if isEdgePanel(v) { continue }   // 边缘窗口不接手型（v0.9.16 防御闸）
            // v0.9.17：垫片被边缘面板盖住（面板层级更高且覆盖此点）时不算命中
            if NSApp.windows.contains(where: { $0 is EdgePanel && $0.isVisible
                && $0.level.rawValue > win.level.rawValue && $0.frame.contains(p) }) { continue }
            let r = Self.windowRect(of: v)
            guard r.width > 1, r.height > 1 else { continue }
            let screen = win.convertToScreen(r)
            // 迟滞：已经是手型时把判定区外扩 1pt，边界上来回抖不会来回切
            let probe = logic.isHand ? screen.insetBy(dx: -1, dy: -1) : screen
            if probe.contains(p) { return (v, screen) }
        }
        return nil
    }

    /// 光标离开可点击区域后，落在输入框上应保持 I 形，其余回到箭头。
    private func restoreCursorBelow(_ p: NSPoint) {
        if let win = topOwnWindow(at: p), let root = win.contentView {
            var v = root.hitTest(win.convertPoint(fromScreen: p))
            while let cur = v {
                if let tv = cur as? NSTextView, tv.isEditable { NSCursor.iBeam.set(); return }
                if let tf = cur as? NSTextField, tf.isEditable { NSCursor.iBeam.set(); return }
                v = cur.superview
            }
        }
        NSCursor.arrow.set()
    }

    private func handView(at p: NSPoint, in win: NSWindow) -> NSView? {
        for case let v as NSView in views.allObjects {
            guard v.window === win, !v.isHiddenOrHasHiddenAncestor else { continue }
            if isEdgePanel(v) { continue }   // 边缘窗口不接手型（v0.9.16 防御闸）
            let r = Self.windowRect(of: v)
            guard r.width > 1, r.height > 1 else { continue }
            if win.convertToScreen(r).contains(p) { return v }
        }
        return nil
    }

    /// 视图在窗口坐标系里的可见矩形。
    ///
    /// **不能用 `visibleRect`**：SwiftUI 托管视图里它返回的是错的（实测每个垫片都
    /// 报成整个窗口大小，导致光标在输入框上也变手型）。
    ///
    /// 也不能无脑跟每一层祖先求交：SwiftUI 用「布局容器 + layer 位移」实现
    /// `offset` / `rotationEffect`，子视图已经画到别处去了，容器的 bounds 还停在
    /// 原位——按 bounds 求交会把正常显示的子视图判成「不存在」（边缘条第二张往下的
    /// 纸签就是这么丢掉手型的）。只跟**真正裁剪**的祖先（滚动视图、圆角裁剪层）
    /// 以及窗口内容区求交。
    static func windowRect(of v: NSView) -> NSRect {
        var r = v.convert(v.bounds, to: nil)
        if let content = v.window?.contentView {
            r = r.intersection(content.convert(content.bounds, to: nil))
        }
        var parent = v.superview
        while let cur = parent, !r.isEmpty {
            if cur.layer?.masksToBounds == true {
                r = r.intersection(cur.convert(cur.bounds, to: nil))
            }
            parent = cur.superview
        }
        return r
    }

    /// 诊断用：某个屏幕点为什么命中 / 没命中。断言失败时把原因打出来，
    /// 否则「实得箭头」这一句什么线索都没有。
    func debugDescribe(_ p: NSPoint) -> String {
        func owner(_ num: Int) -> String {
            guard num > 0 else { return "nil" }
            guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]],
                  let w = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == num }) else {
                return "#\(num) 查询不到"
            }
            let name = w[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            return "#\(num) \(name) layer=\(layer) bounds=\(w[kCGWindowBounds as String] ?? "?")"
        }
        let h = NSScreen.screens.first?.frame.height ?? 0
        let raw = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        let rawFlipped = NSWindow.windowNumber(at: NSPoint(x: p.x, y: h - p.y),
                                               belowWindowWithWindowNumber: 0)
        let mine = NSApp.windows.filter(\.isVisible).map(\.windowNumber).sorted()
        var lines = ["active=\(NSApp.isActive) ticks=\(ticks) 本 App 可见窗口 \(mine)"]
        lines.append("  未翻转 #\(raw) → \(owner(raw))")
        lines.append("  翻转后 #\(rawFlipped) → \(owner(rawFlipped))")
        if let win = NSApp.windows.first(where: { $0.windowNumber == raw && $0.isVisible }) {
            lines.append("  未翻转命中本 App 窗口 #\(win.windowNumber)，垫片=\(handView(at: p, in: win) != nil)")
        }
        if let win = NSApp.windows.first(where: { $0.windowNumber == rawFlipped && $0.isVisible }) {
            lines.append("  翻转后命中本 App 窗口 #\(win.windowNumber)，垫片=\(handView(at: p, in: win) != nil)")
        }
        return lines.joined(separator: "\n  诊断 ")
    }
}

/// 透明垫片：只用来标记「这块区域可以点」，不参与命中测试，绝不吞点击。
struct HandCursorArea: NSViewRepresentable {
    var active: Bool = true
    func makeNSView(context: Context) -> HandCursorView {
        let v = HandCursorView()
        v.active = active
        return v
    }
    func updateNSView(_ nsView: HandCursorView, context: Context) {
        nsView.active = active
    }
}

final class HandCursorView: NSView {
    /// 有些区域只在特定状态下可点（例如边缘条抽出态的「点空白收起」），
    /// 切换状态时不能改视图树结构（会让 SwiftUI 重建整块子树），只改这个开关。
    var active = true {
        didSet { guard active != oldValue else { return }; syncRegistration() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncRegistration()
    }

    private func syncRegistration() {
        if window != nil && active {
            HandCursorRegistry.shared.register(self)
        } else {
            HandCursorRegistry.shared.unregister(self)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    /// 挂到「可点击」视图上：显示手型光标，不影响点击与键盘焦点。
    /// 输入框（TextField / PlainTextEditor）不要加，那里应该保持 I 形光标。
    func handCursor(active: Bool = true) -> some View {
        background(HandCursorArea(active: active))
    }
}
