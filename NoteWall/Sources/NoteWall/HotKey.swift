import Foundation
import Carbon.HIToolbox
import AppKit

// MARK: - 模型

/// 一个具体的组合键。存档里存的就是这两个数（虚拟键码 + Carbon 修饰键掩码），
/// 显示文案是算出来的——存字符串会在用户换了键盘布局后对不上。
struct HotkeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    var display: String { KeySymbols.display(keyCode: keyCode, carbonModifiers: carbonModifiers) }


    static let altSpace = HotkeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
    static let cmdShiftSpace = HotkeyCombo(keyCode: UInt32(kVK_Space),
                                           carbonModifiers: UInt32(cmdKey | shiftKey))
}

extension HotkeyCombo {
    /// 从真实按键事件生成组合键。录键控件只碰这一个入口，
    /// 修饰键 → Carbon 掩码的换算也就只有一处需要维护。
    /// 写在 extension 里：在 struct 体内加自定义 init 会吃掉合成的 memberwise init，
    /// 那样 `HotkeyCombo(keyCode:carbonModifiers:)` 的调用会全部编译不过。
    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode),
                  carbonModifiers: event.modifierFlags.carbonMask)
    }
}

/// 两个可自定义的全局快捷键位
enum HotkeySlot: String, Codable, CaseIterable {
    case newNote
    case openWall

    var title: String { self == .newNote ? "新建便签" : "打开便签墙" }
}

/// 完整的快捷键配置（两个位）
struct HotkeyConfig: Codable, Equatable {
    var newNote: HotkeyCombo
    var openWall: HotkeyCombo

    static let standard = HotkeyConfig(newNote: .altSpace, openWall: .cmdShiftSpace)

    func combo(for slot: HotkeySlot) -> HotkeyCombo {
        slot == .newNote ? newNote : openWall
    }

    mutating func set(_ slot: HotkeySlot, _ combo: HotkeyCombo) {
        if slot == .newNote { newNote = combo } else { openWall = combo }
    }

    /// 与另一位是否撞车
    func clashes(_ combo: HotkeyCombo, in slot: HotkeySlot) -> Bool {
        combo == (slot == .newNote ? openWall : newNote)
    }
}

// MARK: - 按键显示

/// 虚拟键码 + Carbon 修饰键 → 用户能读的文案。顺序固定为 ⌃ ⌥ ⇧ ⌘，
/// 这是 macOS 全系统的惯例（系统设置的快捷键列表也是这个顺序）。
enum KeySymbols {
    static func display(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var parts = modifiers(carbonModifiers)
        parts.append(keyName(keyCode))
        return parts.joined(separator: " ")
    }

    /// 只显示修饰键部分（录制时按住 ⌥ 还没敲主键，给个「⌥ …」的实时预览）
    static func modifierPreview(carbonModifiers: UInt32) -> String? {
        let m = modifiers(carbonModifiers)
        return m.isEmpty ? nil : m.joined(separator: " ") + " …"
    }

    /// F1–F19 的键码不是递增的（kVK_F1=122、kVK_F12=111），
    /// 拿它们做 Range 会直接触发「lowerBound <= upperBound」的致命错误，
    /// 所以用显式表，别用区间。
    private static let functionKeys: [Int: String] = {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
                     kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                     kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        var m: [Int: String] = [:]
        for (i, code) in codes.enumerated() { m[code] = "F\(i + 1)" }
        return m
    }()

    private static func modifiers(_ mask: UInt32) -> [String] {
        var parts: [String] = []
        if mask & UInt32(controlKey) != 0 { parts.append("⌃") }
        if mask & UInt32(optionKey) != 0 { parts.append("⌥") }
        if mask & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if mask & UInt32(cmdKey) != 0 { parts.append("⌘") }
        return parts
    }

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeys[Int(keyCode)] != nil
    }

    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: break
        }
        if let f = functionKeys[Int(keyCode)] {
            return f
        }
        if (kVK_ANSI_Keypad0...kVK_ANSI_Keypad9).contains(Int(keyCode)) {
            return "小键盘 \(Int(keyCode) - kVK_ANSI_Keypad0)"
        }
        // 先按当前键盘布局翻译（非 ANSI 布局也能显示用户实际敲的字符），
        // 拿不到再退回 ANSI 表：虚拟键码本身就是按 ANSI 布局编号的
        if let c = layoutChar(keyCode) { return c.uppercased() }
        return "Key\(keyCode)"
    }

    /// 用 UCKeyTranslate 拿这个键在当前布局下不按修饰键时的字符。
    /// 注意新版 SDK 导入的参数顺序和 Apple 文档不一致：`deadKeyState` 在第 7 位、
    /// 缓冲区最大长度（按值传）在第 8 位——传错会把死键状态当成 4，
    /// 实测每个字母都会翻出「⌥ + 字母」的变音符（A → ä）。
    private static func layoutChar(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let header = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let kbType = UInt32(LMGetKbdType())
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0
        let status = UCKeyTranslate(header, UInt16(keyCode), UInt16(kUCKeyActionDown), 0, kbType,
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &dead, 4, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: Int(length))
    }
}

// MARK: - 校验与引导

/// 快捷键的合法性规则与冲突引导。两层是分开的：
/// `problem` 是硬性拦截（录了也不让存），`advisory` 只是提醒（可以存，但要知道代价）。
enum HotkeyRules {
    /// 硬性规则。返回 nil = 可以用；返回文字 = 拦截原因（直接展示给用户）。
    static func problem(_ combo: HotkeyCombo) -> String? {
        let hasRealModifier = combo.carbonModifiers
            & UInt32(cmdKey | optionKey | controlKey) != 0
        let bareFunctionKey = KeySymbols.isFunctionKey(combo.keyCode)
        if !hasRealModifier && !bareFunctionKey {
            return "至少要带一个 ⌘ / ⌥ / ⌃ 修饰键——只用 ⇧ 会和输入大写字母撞车，裸字母更不行"
        }
        return nil
    }

    /// 软性引导。全局快捷键会把这组键从**所有 App** 手里抢走，有些组合抢了会很难受：
    /// 这里列出常见的坑，设置界面在选了这些组合时主动说明。
    static func advisory(_ combo: HotkeyCombo) -> String? {
        let m = combo.carbonModifiers
        let onlyOption = m == UInt32(optionKey)
        let onlyCommand = m == UInt32(cmdKey)
        let commandShift = m == UInt32(cmdKey | shiftKey)

        if combo.keyCode == UInt32(kVK_Space) && onlyOption {
            return "⌥ Space 是 Raycast / Alfred 等启动器的默认键，也常被输入法工具占用；如果按了没反应，就是被它们占了"
        }
        if combo.keyCode == UInt32(kVK_Space) && onlyCommand {
            return "⌘ Space 是聚焦搜索（Spotlight）的默认键，选它之前先把 Spotlight 换掉"
        }
        if combo.keyCode == UInt32(kVK_Space) && m == UInt32(controlKey) {
            return "⌃ Space 通常是「切换输入法」，选它之后中文输入法就切不动了"
        }
        if commandShift,
           [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6].contains(Int(combo.keyCode)) {
            return "⌘ ⇧ 3 / 4 / 5 / 6 是系统截屏和录屏，全局注册后截屏会失效"
        }
        if onlyCommand {
            let name = KeySymbols.keyName(combo.keyCode)
            if name.count == 1, name.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return "⌘ + 单个字母会从所有 App 手里抢走这组键（⌘C 拷贝、⌘Q 退出、⌘S 保存都会失灵）"
            }
        }
        return nil
    }
}

// MARK: - 注册中心

/// 全局快捷键。用 Carbon 的 RegisterEventHotKey，而不是 NSEvent 全局监听：
/// 前者不需要「辅助功能」授权，用户装完就能用，也不会在系统设置里留下一个需要手动打开的开关。
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onNewNote: (() -> Void)?
    var onOpenWall: (() -> Void)?

    private struct Registration {
        let combo: HotkeyCombo
        let ref: EventHotKeyRef
    }

    private var registrations: [Registration] = []
    private var handler: EventHandlerRef?
    /// 最近一次完全生效的配置。改键失败时用它回滚。
    private(set) var active: HotkeyConfig = .standard

    private let signature: OSType = 0x4E57544C  // 'NWTL'

    /// 只装事件分发器，不注册任何组合键；组合键由 `apply` 按配置注册
    func install() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            HotKeyCenter.shared.fire(hkID.id)
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// 应用一组配置。
    /// - `strict = true`（用户在设置里改键）：任何一个注册失败就整体回滚到改动前——
    ///   不能出现「换了一半」的状态，那比不换还难排查。
    /// - `strict = false`（启动时）：尽力而为，能注册几个算几个，失败的位返回给调用方去提示。
    /// 返回 nil = 全部成功；否则是注册失败的那个位。
    @discardableResult
    func apply(_ config: HotkeyConfig, strict: Bool = true) -> HotkeySlot? {
        let previous = active
        unregisterAll()
        let okNew = register(config.newNote, id: 1) { [weak self] in self?.onNewNote?() }
        let okWall = register(config.openWall, id: 2) { [weak self] in self?.onOpenWall?() }
        if okNew && okWall {
            active = config
            return nil
        }
        let failed: HotkeySlot = okNew ? .openWall : .newNote
        if strict {
            unregisterAll()
            _ = register(previous.newNote, id: 1) { [weak self] in self?.onNewNote?() }
            _ = register(previous.openWall, id: 2) { [weak self] in self?.onOpenWall?() }
        } else {
            active = config
        }
        return failed
    }

    /// 这个组合当前是否真的注册着（供测试断言回滚结果，不猜 Carbon 的行为）
    func isActive(_ combo: HotkeyCombo) -> Bool {
        registrations.contains { $0.combo == combo }
    }

    /// 是否有别的 App 占用了这个组合（注册失败即视为冲突）。
    /// 只在**本进程没有注册任何组合键**时用（--hotkeys 自检）：
    /// 对自己已注册的组合探测，结果取决于 Carbon 对同进程重复注册的态度，不可靠。
    func isAvailable(_ combo: HotkeyCombo) -> Bool {
        if let ref = hold(combo) {
            release(ref)
            return true
        }
        return false
    }

    // 供冲突测试：从外面占住一个组合
    func hold(_ combo: HotkeyCombo) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: 900)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    func release(_ ref: EventHotKeyRef?) {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private func register(_ combo: HotkeyCombo, id: UInt32, action: @escaping () -> Void) -> Bool {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registrations.append(Registration(combo: combo, ref: ref))
            registered[id] = action
            return true
        }
        // 冲突时不要静默失败：这是用户唯一能感知"快捷键没反应"的地方
        NSLog("NoteWall: 快捷键注册失败 id=\(id) status=\(status)")
        return false
    }

    private func unregisterAll() {
        for r in registrations { UnregisterEventHotKey(r.ref) }
        registrations.removeAll()
        registered.removeAll()
    }

    private var registered: [UInt32: () -> Void] = [:]

    fileprivate func fire(_ id: UInt32) {
        registered[id]?()
    }
}

// MARK: - NSEvent 修饰键 → Carbon 掩码

extension NSEvent.ModifierFlags {
    /// 录键控件里从真实按键事件取修饰键，转成 Carbon 注册用的掩码
    var carbonMask: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) { mask |= UInt32(cmdKey) }
        if contains(.option) { mask |= UInt32(optionKey) }
        if contains(.shift) { mask |= UInt32(shiftKey) }
        if contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}
