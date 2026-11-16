import SwiftUI
import AppKit
import ServiceManagement

// MARK: - App

/// 全局单例持有：快捷键与捕获面板要能在没有窗口时访问到同一份数据。
@MainActor
final class AppContext {
    static let shared = AppContext()
    let store = AppStore()
    /// 墙窗口的弱引用。SwiftUI 窗口被关掉后对象释放，此处自动变 nil。
    weak var wallWindow: NSWindow?
    /// 从 SwiftUI 环境取出的 openWindow 动作：墙窗口彻底不存在时用它重建。
    var openWallWindow: (() -> Void)?
    /// 菜单栏点了「设置…」，但墙窗口是刚重建的、还没注册监听时的旗子。
    /// 由 `WallView` 在 `onAppear` 里消费；不清掉会导致下次开窗口又弹一次设置。
    var pendingOpenSettings = false
    /// 刘海里点「在便签墙中打开」时要打开的便签 id；消费方式同 pendingOpenSettings。
    var pendingDetailNoteID: UUID? = nil
    /// 捕获面板 ⌘E 带过来的草稿：正文 / 标签 / 纸色。由 `WallView` 消费
    /// （onAppear 兜底 + noteWallOpenDraft 通知快路），消费完立刻清掉。
    var pendingDraftText: String? = nil
    var pendingDraftTag: String? = nil
    var pendingDraftPaper: Paper? = nil
    private init() {}
}

extension Notification.Name {
    /// 菜单栏「设置…」→ 墙窗口弹设置 sheet
    static let noteWallOpenSettings = Notification.Name("NoteWall.openSettings")
    /// 刘海「在便签墙中打开」→ 墙窗口弹该便签的详情 sheet
    static let noteWallOpenDetail = Notification.Name("NoteWall.openDetail")
    /// 捕获面板 ⌘E → 墙窗口把草稿送进英雄纸
    static let noteWallOpenDraft = Notification.Name("NoteWall.openDraft")
}

struct NoteWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: AppStore

    /// 启动解析（设计 §2.2）：先解析仓库、再建 store。`@StateObject` 的属性
    /// 初始化器在 `init()` 体之前执行，所以必须写显式 `init()`、在里面先解析、
    /// 再给 `_store` 赋值（`self._store = StateObject(wrappedValue:)`）。
    /// 这里是 `VaultManager.currentRoot` 全功能唯一的赋值点，之后只读。
    init() {
        let storedPath = UserDefaults.standard.string(forKey: VaultManager.defaultsKey)
        let fm = FileManager.default
        let storedExists = storedPath.map {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        } ?? false
        let legacyExists = fm.fileExists(atPath: Paths.legacySupport.appendingPathComponent("store.json").path)
        let res = VaultManager.resolve(storedPath: storedPath, storedRootExists: storedExists,
                                       legacyStoreExists: legacyExists)
        VaultManager.launchResolution = res
        switch res {
        case .use(let url):
            VaultManager.currentRoot = url
            if storedPath == nil {  // 认领老目录：顺手把路径写回 UserDefaults
                UserDefaults.standard.set(url.path, forKey: VaultManager.defaultsKey)
            }
            _store = StateObject(wrappedValue: AppContext.shared.store)
        case .needsChoice:
            _store = StateObject(wrappedValue: AppStore(inMemory: true))
        }
    }

    var body: some Scene {
        WindowGroup("随手贴", id: "wall") {
            // 0.3.12 修复：分支只能在 View 层做——if/else 选 Window / WindowGroup
            // 编译不过（CI run 57 实锤）；所以只开一扇 WindowGroup，内容用
            // ViewBuilder 的 if/else 分支。选择器窗口的尺寸在 VaultChooserView
            // 挂载时再调小（见该文件）。
            if VaultManager.launchResolution?.isNeedsChoice == true {
                VaultChooserView()
                    .environmentObject(store)   // 内存 store，只给选择器撑场面
            } else {
                WallView()
                    .environmentObject(store)
                    .frame(minWidth: 720, minHeight: 480)
                    .background(T.bg)
                    .background(WindowHooks())
                    // 折叠按钮放在标题栏左侧：macOS 标准侧边栏图标，Muse/ChatGPT/Obsidian 用的就是它。
                    // 注意：.toolbar 是 View 修饰器，不是 Scene 修饰器——必须挂在窗口根视图上，
                    // 挂在 WindowGroup（Scene）上编译不过（'some Scene' has no member 'toolbar'）。
                    // next 是计算属性不是方法，调用不加括号。
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                store.sidebarMode = store.sidebarMode.next
                            } label: {
                                Image(systemName: "sidebar.left")
                                    .font(.icon(13))
                            }
                            .help("折叠侧边栏 (⌘B)")
                            .keyboardShortcut("b", modifiers: .command)
                        }
                    }
            }
        }
        // v8：系统标题栏（居中显示当前视图名，产品名不在标题栏）。
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 820)
        // `.commands` 挂在唯一的 WindowGroup 上：选择器模式和墙模式共用同一套菜单
        // （读的是当前 store，选择器模式下是内存 store，无副作用）。
        .commands {
            CommandGroup(replacing: .newItem) {}
            // 编辑菜单的撤销/重做（D3）：系统标准项只认 key window 的 undoManager，
            // 焦点不在文本框时它要么灰掉、要么撤销残留的文字历史，与 ⌘Z（自定义栈）行为不一致。
            // 这里换成结构栈的标题，菜单里能看到“将要撤销什么”。
            // 两个 Button 刻意不挂 .keyboardShortcut——⌘Z/⇧⌘Z 的唯一入口仍是
            // WallView.bindKeys 的本地监视器（注释原文：焦点在 TextEditor 里时命令菜单收不到按键）。
            // 菜单项只供鼠标点按与“先看清再撤销”；点击时的路由与 bindKeys 同一个 helper，行为一致。
            // 注意：本组只做 P1-9 的撤销菜单，不加“关于随手贴”（P2-25 进 Carry 本地批 L0，
            // 加了会让 CI 的 --menutest 变红）。
            CommandGroup(replacing: .undoRedo) {
                Button("撤销\(store.undoLabel.map { " \($0)" } ?? "")") { undoFromMenu(isRedo: false) }
                    .disabled(store.undoLabel == nil)
                Button("重做\(store.redoLabel.map { " \($0)" } ?? "")") { undoFromMenu(isRedo: true) }
                    .disabled(store.redoLabel == nil)
            }
            CommandMenu("字体") {
                // 只留一个「放大字体」入口（⌘+）：菜单里出现两次是 bug。
                // macOS 上 ⌘= 同样触发 ⌘+ 的菜单项（AppKit 把 +/= 视作同一快捷键），
                // 所以别名按钮不需要；若真机上 ⌘= 无效，再把双入口加回来。
                Button("放大字体") { store.bumpFontScale(by: 0.05) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("缩小字体") { store.bumpFontScale(by: -0.05) }
                    .keyboardShortcut("-", modifiers: .command)
                Divider()
                Button("恢复标准大小") { store.fontScale = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
                Text("当前 \(Int((store.fontScale * 100).rounded()))%")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 编辑菜单点按的撤销/重做（D3）：与 bindKeys 同一个 helper。
    /// .passThrough（焦点在 NSTextView 里）时直接调该编辑器的 undoManager；
    /// .done 时同款 Toast；.empty 时不做事（按钮已 disabled，防御而已）。
    private func undoFromMenu(isRedo: Bool) {
        switch isRedo ? store.redoRespectingFocus() : store.undoRespectingFocus() {
        case .passThrough:
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                if isRedo { tv.undoManager?.redo() } else { tv.undoManager?.undo() }
            }
        case .done(let title):
            ToastCenter.shared.show(isRedo ? "已重做\(title)" : "已撤销\(title)",
                                    actionTitle: isRedo ? nil : "重做") { _ = store.redo() }
        case .empty:
            break
        }
    }
}

/// 挂在墙窗口视图层级里：拿到真正的 NSWindow 引用与 openWindow 动作。
/// 之前 `bringWallToFront` 在 NSApp.windows 里盲选，会选中 SwiftUI 的
/// 离屏辅助窗口（30pt 高、不在屏上的幽灵窗口），这就是点菜单栏/Dock 打不开窗口的原因。
private struct WindowHooks: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        WindowAccessor { win in
            // 0.3.14：赋值加守卫——回调是 DispatchQueue.main.async 派发的，被关掉
            // 那扇窗的待执行回调随后跑起来时 [weak v] 已空，onChange(nil) 会把
            // wallWindow 无条件写成 nil，下一次 bringWallToFront 见引用为空就
            // openWindow 再建一扇窗；且“非 nil 但已关闭”的窗（仍有强引用留住）也要
            // 拦住。已关闭的窗会立即从 NSApp.windows 移除。不要用 isVisible 判断
            // （最小化/隐藏的墙窗 isVisible 为 false，会误拦正常赋值）。
            if let win = win, NSApp.windows.contains(where: { $0 === win }) {
                AppContext.shared.wallWindow = win
            }
            // 0.3.10：墙窗口永不进选项卡。WindowGroup 默认 tabbingMode = .automatic，
            // 系统（⇧⌘T / + 号 / “合并全部窗口” / 偏好“始终用选项卡”）随时能把
            // 第二扇墙并成选项卡条，一旦出现就赖在顶部不走。直接在窗口上禁掉，
            // 选项卡条、+ 号与相关菜单项对这扇窗一律失效。
            win?.tabbingMode = .disallowed
        }
        .frame(width: 0, height: 0)
        .onAppear {
            AppContext.shared.openWallWindow = { openWindow(id: "wall") }
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in onChange(v?.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in onChange(nsView?.window) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    /// 闲置活动监视器（D5）：不保留会被释放，监视器静默失效。
    private var activityMonitor: Any? = nil
    /// 回收站每小时清理计时器（P2-17）：不保留会被释放。
    private var trashPurgeTimer: Timer? = nil

    /// 单实例守卫（0.3.13）：启动时如果已有更早启动的同 bundle 实例在跑，请它退出。
    /// 切换仓库的 relaunch（open -n + 旧进程退出）一旦旧进程没能及时退出，就会留下
    /// 两个进程、两扇窗、两个 Dock 图标；新实例启动时清掉老的，保证同一时间只有
    /// 一个实例在跑。只清比自己早启动的：两个人同时点两下，后启动的那个活下来。
    /// launchDate 拿不到时保守不动手。注意 store 已在 NoteWallApp.init() 里建好，
    /// 守卫的活是单实例存活、不是读顺序保证（设计 §6 Q1）。
    private func terminateEarlierInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let myLaunch = NSRunningApplication.current.launchDate else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            guard app.processIdentifier != me,
                  let otherLaunch = app.launchDate,
                  otherLaunch < myLaunch else { continue }
            NSLog("StickySide: 已有旧实例 (pid %d) 在跑，请它退出", app.processIdentifier)
            app.terminate()
        }
    }

    /// 选项卡组解散（0.3.14 立项、0.3.17 改成常驻守卫）：0.3.10 只禁了以后分组，
    /// 没拆已有的组——组随 Saved State 每次启动原样恢复回来。0.3.14 只在启动 +0.5s
    /// 跑一次，没兜住（组晚于 +0.5s 成型、或之后又冒出第二扇窗，就再也没人拆）。
    /// 0.3.17 起它是常驻守卫：启动 +0.5s、bringWallToFront 内 3 处、App 切回前台
    /// （applicationDidBecomeActive），共 5 处调用点，组里只留当前这扇窗，其余关掉；
    /// 组只剩一扇，选项卡条自己就没了。
    /// 关而不是移出（moveTabToNewWindow 只会把组拆成两扇独立窗）；另一扇只是
    /// 同一份 store 的重复视图，关掉只丢它自己的界面状态，数据不丢。
    /// 关完立刻把 wallWindow 重新指回目标窗：拆组前它可能正指着被关的那扇，
    /// 弱引用随释放变 nil，不补这一行，下一次 bringWallToFront 会误建第二扇窗。
    /// 每次调用都是幂等的：组里 ≤1 扇直接 return。
    private static func dissolveTabGroupIfNeeded() {
        guard let keep = NSApp.keyWindow ?? AppContext.shared.wallWindow else {
            NSLog("StickySide: 拆选项卡组时没找到可见窗口，跳过")
            return
        }
        // 0.3.17：浮层（捕获/刘海/边缘条含文本编辑器）可成为 keyWindow 但无 tabGroup；
        // keep 无组时改取 wallWindow，避免静默跳过（正看的窗若在组里，tabGroup 非空，不触发）。
        let target = keep.tabGroup == nil ? (AppContext.shared.wallWindow ?? keep) : keep
        guard let group = target.tabGroup, group.windows.count > 1 else { return }
        NSLog("StickySide: 选项卡组里有 \(group.windows.count) 扇窗，只留当前这扇")
        for other in group.windows where other !== target {
            other.close()
        }
        AppContext.shared.wallWindow = target
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // 单实例守卫（0.3.13）：放选择器门之前、两种模式都覆盖；store 已在 init() 里建好，守卫只保单实例存活。
        terminateEarlierInstances()

        // 选项卡组常驻守卫（0.3.17）：启动时跑一次——+0.5s 时恢复分组肯定已成型
        // （恢复的窗口在 applicationDidFinishLaunching 之前就已创建），且在 +0.15s 的
        // bringWallToFront 之后，keyWindow 可靠。放选择器门之前，两种模式都覆盖。
        // 这只是 5 处调用点之一：之后每次 bringWallToFront 与每次 App 切回前台还会再查。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.dissolveTabGroupIfNeeded() }

        // 选择器模式（设计 §2.2.1）：只留上面这一行，其余全部跳过——不建真 store、
        // 不接控制器、不装快捷键、不弹墙窗口。重启后的新进程会正常走一遍。
        if VaultManager.launchResolution?.isNeedsChoice == true { return }

        // 系统若设成「总是显示滚动条」，TextEditor 会在卡片右侧画一根直角深色竖条
        // （在深色便签上非常显眼）。逐个 NSScrollView 改成 overlay：只在滚动时浮出。
        ScrollChrome.startWatching()

        let store = AppContext.shared.store
        CaptureController.shared.attach(store: store)

        // 存档里存的外观。store 载入时已经 apply 过一次，这里再落一次：
        // 那次可能早于 NSApp 完成初始化，窗口还不存在。
        ThemeApplier.apply(store.appearance)

        HotKeyCenter.shared.onNewNote = {
            MainActor.assumeIsolated { CaptureController.shared.show() }
        }
        HotKeyCenter.shared.onOpenWall = {
            MainActor.assumeIsolated { Self.bringWallToFront() }
        }
        HotKeyCenter.shared.install()
        // 启动时按存档里的配置注册；被别的 App 占用（⌥ Space 常被启动器类工具占了）
        // 不能静默吞掉——用户唯一的感知就是「按了没反应」，必须明说并指路
        // 两位都可能被占：逐位报。ToastCenter 一次只显示一条，两位都失败时
        // 合成一条 Toast 念出两个名字，不会被后一条顶掉前一条（P0-7）。
        HotKeyCenter.shared.apply(store.hotkeys, strict: false)
        let failedSlots = HotKeyCenter.shared.failedSlots
        if !failedSlots.isEmpty {
            let names = failedSlots.map { "「\($0.title)」" }.joined()
            let details = failedSlots.map { slot in
                "「\(slot.title)」的 \(store.hotkeys.combo(for: slot).display)"
            }.joined(separator: "、")
            NSLog("NoteWall: 快捷键注册失败（被其他应用占用）：\(details)")
            store.hotkeyMessage = "\(details) 被其他应用占用，这个快捷键暂时不可用，换一组就好"
            ToastCenter.shared.show("\(names) 的快捷键被其他应用占用，可在设置里更换",
                                    seconds: 6)
        }

        installStatusItem()

        // 闲置自动重锁的活动监视器（D5）：只记活动、不拦截输入，原样放行。
        // 本地监视器只收本 App 的事件——闲置 = 没碰过随手贴，在别的 App 里干活不算在用。
        // 不含 .mouseMoved：移动鼠标不算操作，且高频事件没必要进计时器。
        // 与 KeyMonitor 的本地监视器并存：两者都原样放行，安装顺序不影响行为。
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { event in
            AppContext.shared.store.noteUserActivity()
            return event
        }

        // 回收站过期清理（P2-17）：每小时跑一次（过滤全量 notes 一次，成本可忽略）。
        // purgeExpiredTrash 本身只在有过期项时才 saveNow()，无过期时零写盘。
        // Timer 默认 .default mode，菜单/模态期间不触发——对每小时一次的家务活可接受。
        // 启动清理（Store.init 内）保留不动，两者互补。
        trashPurgeTimer = Timer(timeInterval: 3600, repeats: true) { _ in
            let n = AppContext.shared.store.purgeExpiredTrash()
            if n > 0 { NSLog("NoteWall: 回收站过期清理，删除 \(n) 张") }
        }
        RunLoop.main.add(trashPurgeTimer!, forMode: .common)

        NotchController.shared.install(store: store)
        EdgeDeckController.shared.attach(store: store)

        // 首次上线时指一下路：细条存在感极低，不说一声很多人永远发现不了
        if store.edgeEnabled && !store.edgeIntroduced {
            store.edgeIntroduced = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                ToastCenter.shared.show("便签已经停靠在屏幕\(store.edgeSide == .right ? "右" : "左")缘，鼠标移过去看看",
                                        seconds: 6)
            }
        }

        // 首帧落定后把墙窗口置前，避免「启动了但看不见窗口」
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.bringWallToFront() }
    }

    /// Dock 图标被点击：没有可见窗口时把它找回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 选择器模式：选择器窗口就是唯一窗口，Dock 点按只激活 App，不重建墙窗口。
        if VaultManager.launchResolution?.isNeedsChoice == true { return false }
        if !flag {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Self.bringWallToFront() }
        }
        return true
    }

    /// App 切回前台：常驻守卫（0.3.17）——组在运行中出现、用户切回来才看到时，在这里拆掉。
    func applicationDidBecomeActive(_ notification: Notification) {
        Self.dissolveTabGroupIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 选择器模式：关掉选择器窗口即退出 App，不让 App 空挂在 Dock 上没窗口可回。
        if VaultManager.launchResolution?.isNeedsChoice == true { return true }
        return false   // 关掉墙也要留着菜单栏与快捷键，随时还能记
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 选择器模式：直接 return——否则退出时会创建 AppContext.shared.store 并
        // saveNow()，在全新安装的机器上还会往老目录里撒一份种子（设计 §2.2.1）。
        if VaultManager.launchResolution?.isNeedsChoice == true { return }
        // 边缘抽出面板里可能还有没写盘的草稿，先落盘
        EdgeDeckController.shared.flushSave()
        // 本次会话解过锁的便签重新封上：明文不留在磁盘上过夜。
        // 注意：被系统强杀 / 崩溃时不会执行，那种情况下明文会留到下次解锁。
        AppContext.shared.store.relockSessionNotes()
        // 350ms 防抖里的设置改动（外观/字号/快捷键等）也落盘，别丢在退出时（P2-12）。
        AppContext.shared.store.saveNow()
    }

    /// 菜单栏常驻入口：既是无刘海设备的降级方案，也是快捷键没记住时的兜底
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 用一张**单色轮廓**模板图，形状跟 Dock 图标同源（一叠便签 + 勾选）：
        // 菜单栏是唯一常驻的品牌露出，形状必须对得上，但又不能彩色——
        // 身边所有菜单栏图标都是单色的，彩色在那排里非常跳。
        // MenuBarIcon.make() 内部已经设了 isTemplate = true，交给系统按明暗自动反色。
        item.button?.image = MenuBarIcon.statusImage()
        item.menu = Self.makeStatusMenu(target: self)
        statusItem = item
    }

    /// 菜单内容单独抽出来，`--menutest` 才能不启动界面就断言条目与快捷键。
    ///
    /// 分组照 macOS 惯例：动作 / 设置 / 退出。设置单独一组、退出压在最下，
    /// 跟系统 App 的「关于 / 设置… / 退出」同一套读法。
    static func makeStatusMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "新建便签", action: #selector(newNote), keyEquivalent: "")
            .target = target
        menu.addItem(withTitle: "打开随手贴", action: #selector(openWall), keyEquivalent: "")
            .target = target
        menu.addItem(.separator())
        // ⌘, 是 macOS 的「设置」惯例。status menu 里的快捷键只在菜单展开时生效，
        // 但这一行本身就在告诉用户：系统的那个习惯在这里也成立。
        let settings = menu.addItem(withTitle: "设置…", action: #selector(openPreferences), keyEquivalent: ",")
        settings.target = target
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        return menu
    }

    @objc private func newNote() { CaptureController.shared.show() }
    @objc private func openWall() { Self.bringWallToFront() }

    /// 菜单栏里的「设置…」：先把墙窗口带回前台，再让它弹设置 sheet。
    ///
    /// 墙窗口可能已经被关掉（App 仍常驻菜单栏），这时 `bringWallToFront` 会重建它；
    /// 新窗口的 `onAppear` 比这次通知晚，所以真正可靠的是 `pendingOpenSettings` 这个旗子，
    /// 通知只是给「窗口已经开着」的常见情况走的快路。
    @objc func openPreferences() {
        AppContext.shared.pendingOpenSettings = true
        Self.bringWallToFront()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .noteWallOpenSettings, object: nil)
        }
    }

    /// 把墙窗口带回前台。优先用窗口引用；窗口已被销毁时用 openWindow 重建。
    static func bringWallToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = AppContext.shared.wallWindow {
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.makeKeyAndOrderFront(nil)
            Self.dissolveTabGroupIfNeeded()
        } else {
            // 0.3.17：先等一拍再建窗——WindowAccessor 回调是 async 派发的，
            // onAppear 可能已设好 openWallWindow、回调还没跑，wallWindow 仍为空
            // 但窗其实已存在；此时立即 openWindow 必造第二扇窗。
            // +0.3s 后复核：窗已出现则直接置前（不等用户点第二次），
            // 仍为空才是真的没窗，再建。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let win = AppContext.shared.wallWindow {
                    if win.isMiniaturized { win.deminiaturize(nil) }
                    win.makeKeyAndOrderFront(nil)
                    Self.dissolveTabGroupIfNeeded()
                } else {
                    AppContext.shared.openWallWindow?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        NSApp.activate(ignoringOtherApps: true)
                        AppContext.shared.wallWindow?.makeKeyAndOrderFront(nil)
                        Self.dissolveTabGroupIfNeeded()
                    }
                }
            }
        }
    }
}

// MARK: - 开机自启

/// 用 SMAppService 注册登录项（macOS 13+），不需要特权助手，也不落 LaunchAgent plist。
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 返回是否成功；失败时界面必须回滚，不能显示一个假的开状态
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return SMAppService.mainApp.status == (enabled ? .enabled : .notRegistered)
        } catch {
            NSLog("NoteWall: 开机自启设置失败 \(error)")
            return false
        }
    }
}
