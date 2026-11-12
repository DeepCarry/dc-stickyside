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
    private init() {}
}

extension Notification.Name {
    /// 菜单栏「设置…」→ 墙窗口弹设置 sheet
    static let noteWallOpenSettings = Notification.Name("NoteWall.openSettings")
}

struct NoteWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppContext.shared.store

    var body: some Scene {
        WindowGroup("便签墙", id: "wall") {
            WallView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 480)
                .background(T.bg)
                .background(WindowHooks())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
            AppContext.shared.wallWindow = win
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

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
        if let failed = HotKeyCenter.shared.apply(store.hotkeys, strict: false) {
            let combo = store.hotkeys.combo(for: failed)
            NSLog("NoteWall: \(failed.title) 的快捷键 \(combo.display) 注册失败（被其他应用占用）")
            store.hotkeyMessage = "\(failed.title)的 \(combo.display) 被其他应用占用，这个快捷键暂时不可用，换一组就好"
            ToastCenter.shared.show("「\(failed.title)」的快捷键被其他应用占用，可在设置里更换",
                                    seconds: 6)
        }

        installStatusItem()
        NotchController.shared.install()
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
        if !flag {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Self.bringWallToFront() }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // 关掉墙也要留着菜单栏与快捷键，随时还能记
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 边缘抽出面板里可能还有没写盘的草稿，先落盘
        EdgeDeckController.shared.flushSave()
        // 本次会话解过锁的便签重新封上：明文不留在磁盘上过夜。
        // 注意：被系统强杀 / 崩溃时不会执行，那种情况下明文会留到下次解锁。
        AppContext.shared.store.relockSessionNotes()
    }

    /// 菜单栏常驻入口：既是无刘海设备的降级方案，也是快捷键没记住时的兜底
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 用一张**单色轮廓**模板图，形状跟 Dock 图标同源（一叠便签 + 勾选）：
        // 菜单栏是唯一常驻的品牌露出，形状必须对得上，但又不能彩色——
        // 身边所有菜单栏图标都是单色的，彩色在那排里非常跳。
        // MenuBarIcon.make() 内部已经设了 isTemplate = true，交给系统按明暗自动反色。
        item.button?.image = MenuBarIcon.make()
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
        menu.addItem(withTitle: "打开便签墙", action: #selector(openWall), keyEquivalent: "")
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
        } else {
            AppContext.shared.openWallWindow?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                NSApp.activate(ignoringOtherApps: true)
                AppContext.shared.wallWindow?.makeKeyAndOrderFront(nil)
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
