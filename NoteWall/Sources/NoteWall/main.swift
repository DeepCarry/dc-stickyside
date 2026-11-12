import AppKit
import SwiftUI
import Carbon.HIToolbox

let args = CommandLine.arguments

// 测试模式支持把输出写进文件：用 `open -n -a 便签墙.app --args --clickfliptest --out /tmp/x`
// 启动时，进程是被 LaunchServices 拉起来的（能正常拿到前台身份，和用户真实使用一致），
// 但拿不到终端 stdout。
if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
    freopen(args[i + 1], "w", stdout)
    setvbuf(stdout, nil, _IOLBF, 0)
}

// 离屏渲染：把真实视图渲成 PNG
if args.contains("--snapshot") {
    MainActor.assumeIsolated { _ = Snapshot.runIfRequested() }
    exit(0)
}

// 菜单栏图标：形状、留白、卷边、勾选挖空（不弹 UI，纯位图断言）
if args.contains("--menubaricon") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "✓ \(name)" : "✗ \(name)\(detail.isEmpty ? "" : "  ← \(detail)")")
            if !ok { failures += 1 }
        }

        let image = MenuBarIcon.make()
        check("画布 18×18", image.size == NSSize(width: 18, height: 18), "\(image.size)")
        // 菜单栏里所有图标都是单色的：必须是模板图，系统按明暗自动反色
        check("是模板图（系统自动反色，单色）", image.isTemplate)
        check("带无障碍描述", image.accessibilityDescription == "便签墙")
        check("备了 1x/2x/3x 三档（外接屏不糊）", image.representations.count >= 3,
              "\(image.representations.count)")

        guard let one = MenuBarIcon.bitmap(scale: 1),
              let two = MenuBarIcon.bitmap(scale: 2),
              let three = MenuBarIcon.bitmap(scale: 3) else {
            print("✗ 栅格化失败"); exit(1)
        }
        let m1 = MenuBarIcon.measure(one, scale: 1)
        let m2 = MenuBarIcon.measure(two, scale: 2)
        let m3 = MenuBarIcon.measure(three, scale: 3)
        func pct(_ d: Double) -> String { String(format: "%.1f%%", d * 100) }
        print("  诊断 1x：覆盖 \(pct(m1.coverage)) bbox \(m1.bbox)")
        print("  诊断 2x：覆盖 \(pct(m2.coverage)) bbox \(m2.bbox)")
        print("  诊断 3x：覆盖 \(pct(m3.coverage)) bbox \(m3.bbox)")
        if args.contains("--iconmap") {
            // 点阵真值：`#` 不透明、`+` 半透、`.` 透明。
            // 行标签是**设计 y**（原点左下），所以最上面一行就是图标的上边。
            for (rep, tag) in [(one, "1x"), (two, "2x")] {
                let w = rep.pixelsWide, h = rep.pixelsHigh
                let s = CGFloat(w) / 18
                print("\n  [\(tag)] " + (0..<w).map { String($0 % 10) }.joined()
                      + "   ← x（像素列，÷\(Int(s)) 即 pt）")
                for dy in stride(from: h - 1, through: 0, by: -1) {
                    var row = ""
                    for x in 0..<w {
                        let a = rep.colorAt(x: x, y: h - 1 - dy)?.alphaComponent ?? 0
                        row += a > 0.5 ? "#" : (a > 0.1 ? "+" : ".")
                    }
                    print(String(format: "%3d  ", dy) + row)
                }
            }
        }

        // 实心版：纸面是填满的，覆盖率必然明显高于线稿；太高说明三张粘成一块、缝被吃掉
        check("1x 覆盖率在 40%~54%（实心纸面，实得 \(pct(m1.coverage))）", (0.40...0.54).contains(m1.coverage))
        check("2x 覆盖率在 42%~56%（实得 \(pct(m2.coverage))）", (0.42...0.56).contains(m2.coverage))

        // 尺寸：三张纸摊开后的包围盒（实测 16×15pt）
        check("内容宽 ≥ 15pt（实得 \(String(format: "%.1f", m2.bbox.width))）", m2.bbox.width >= 15.0)
        check("内容高 ≥ 13.5pt（实得 \(String(format: "%.1f", m2.bbox.height))）", m2.bbox.height >= 13.5)
        // 18pt 画布要留出呼吸：四周各 ≥0.75pt（实测 1.0pt）
        check("四周留白 ≥ 0.75pt（2x bbox \(m2.bbox)）",
              m2.bbox.minX >= 0.75 && m2.bbox.minY >= 0.75 &&
              m2.bbox.maxX <= 17.25 && m2.bbox.maxY <= 17.25)
        check("四角透明（实得 \(m1.opaqueCorners) 个不透明角）", m1.opaqueCorners == 0)

        func ink2(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Int {
            MenuBarIcon.ink(in: two, rect: NSRect(x: x, y: y, width: w, height: h), scale: 2)
        }
        func hole2(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Int {
            MenuBarIcon.holes(in: two, rect: NSRect(x: x, y: y, width: w, height: h), scale: 2)
        }

        // ① 关系要对：形状实心、内容镂空
        let blank = hole2(4.6, 3.4, 4.0, 1.4)         // 第四行字下面那块空白纸面
        let content = hole2(4.0, 5.8, 6.0, 6.8)       // 勾选框 + 四条线所在的整块
        print("  诊断 纸面空白区 \(blank) px（应 0） 内容区镂空 \(content) px（应 >0）")
        check("纸面是实心的（空白处 \(blank) px 透明）", blank == 0)
        check("内容是镂空的（内容区 \(content) px 透明）", content >= 20)

        let checkBox = hole2(4.5, 10.9, 1.5, 1.5)     // 勾选框内部
        print("  诊断 勾选框镂空 \(checkBox) px")
        check("勾选框内部镂空（实得 \(checkBox) px）", checkBox >= 3)

        // ② 三张纸：左右两侧都露出后纸，并且用透明缝与前纸隔开
        let leftBack = ink2(0.9, 4.5, 1.8, 9.5)
        let rightBack = ink2(15.2, 4.5, 1.8, 9.5)
        let leftSeam = hole2(2.85, 5.0, 0.35, 4.0)
        let rightSeam = hole2(14.8, 5.0, 0.35, 4.0)
        print("  诊断 左后纸 \(leftBack) 右后纸 \(rightBack) 左缝 \(leftSeam) 右缝 \(rightSeam)")
        check("左侧露出后纸（实得 \(leftBack) px）", leftBack >= 20)
        check("右侧露出后纸（实得 \(rightBack) px）", rightBack >= 20)
        check("左侧有透明缝（实得 \(leftSeam) px）", leftSeam >= 4)
        check("右侧有透明缝（实得 \(rightSeam) px）", rightSeam >= 4)

        // ③ 顶部：后两张纸的顶边高过前纸，露出"还叠着"的那一截
        let topBack = ink2(5.5, 14.8, 7.0, 0.8)
        print("  诊断 顶部露出的一截 \(topBack) px")
        check("顶部露出后纸的边（实得 \(topBack) px）", topBack >= 10)

        // 存一份实拍用的位图，方便肉眼复核（不进断言）
        let dir = URL(fileURLWithPath: "shots/menubar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (rep, tag) in [(one, "1x"), (two, "2x"), (three, "3x")] {
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("live-\(tag).png"))
            }
        }
        // 放大实拍：3x 位图按最近邻放大 8 倍，深/浅两底各一份（模板图会反色）
        let zoom = 8, cellPx = 54 * zoom
        let ZW = cellPx * 2 + 36, ZH = cellPx + 48
        let zrep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: ZW, pixelsHigh: ZH,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: zrep)
        let zc = NSGraphicsContext.current!.cgContext
        zc.interpolationQuality = .none
        for (i, dark) in [true, false].enumerated() {
            let x = CGFloat(12 + i * (cellPx + 12))
            zc.setFillColor(dark
                ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1).cgColor
                : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1).cgColor)
            zc.fill(NSRect(x: x, y: 12, width: CGFloat(cellPx), height: CGFloat(cellPx)))
            // 白化/黑化：模板图只有 alpha，靠蒙版换色
            let tinted = MenuBarIcon.bitmap(scale: 3) { _ in MenuBarIcon.drawGlyph(scale: 3) }
            if let t = tinted, let cg = t.cgImage {
                let shade = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 54, pixelsHigh: 54,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: shade)
                let sc = NSGraphicsContext.current!.cgContext
                sc.setFillColor((dark ? NSColor.white : NSColor.black).cgColor)
                sc.fill(NSRect(x: 0, y: 0, width: 54, height: 54))
                sc.setBlendMode(.destinationIn)
                sc.draw(cg, in: NSRect(x: 0, y: 0, width: 54, height: 54))
                NSGraphicsContext.restoreGraphicsState()
                if let scg = shade.cgImage {
                    zc.draw(scg, in: NSRect(x: x, y: 12, width: CGFloat(cellPx), height: CGFloat(cellPx)))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = zrep.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent("live-zoom.png"))
        }

        print(failures == 0 ? "menubaricon 全部通过" : "menubaricon \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}

// 诊断：三张纸的叠放几何对照（挑几何用，不进断言）
if args.contains("--mbgeom") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        struct V { var name: String; var s: CGFloat; var dx: CGFloat; var dy: CGFloat
                   var rot: CGFloat; var gap: CGFloat }
        let vs: [V] = [
            V(name: "T1 585/135/170 r9.5", s: 585, dx: 135, dy: 170, rot: 9.5, gap: 0.85),
            V(name: "T2 585/130/175 r10", s: 585, dx: 130, dy: 175, rot: 10, gap: 0.85),
            V(name: "T3 570/140/172 r10", s: 570, dx: 140, dy: 172, rot: 10, gap: 0.85),
            V(name: "T4 600/130/175 r9", s: 600, dx: 130, dy: 175, rot: 9, gap: 0.85),
            V(name: "T5 560/142/175 r10.5", s: 560, dx: 142, dy: 175, rot: 10.5, gap: 0.85),
            V(name: "T6 540/145/178 r11", s: 540, dx: 145, dy: 178, rot: 11, gap: 0.85)
        ]
        let cell = 54 * 6                     // 3x 位图放大 6 倍 = 324
        let colW = cell + 16
        let W = vs.count * colW + 16
        let H = cell + 30 + 160 + 24
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor)
        ctx.fill(NSRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .none

        for (i, v) in vs.enumerated() {
            let x = CGFloat(8 + i * colW)
            let L = MenuBarIcon.card(side: v.s, rot: v.rot, x: -v.dx, y: -v.dy, cornerRatio: 0.088)
            let R = MenuBarIcon.card(side: v.s, rot: -v.rot + 1, x: v.dx, y: -v.dy + 12, cornerRatio: 0.088)
            func render(_ scale: CGFloat, px: Int) -> NSBitmapImageRep? {
                MenuBarIcon.bitmap(scale: scale, drawing: { _ in
                    MenuBarIcon.drawGlyph(left: L, right: R, front: MenuBarIcon.frontCard,
                                          gap: v.gap, contentHint: scale < 1.5 ? 1.5 : 1)
                })
            }
            // 白化（模板图只有 alpha）
            func white(_ rep: NSBitmapImageRep?) -> CGImage? {
                guard let rep, let cg = rep.cgImage else { return nil }
                let n = rep.pixelsWide
                let shade = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: shade)
                let sc = NSGraphicsContext.current!.cgContext
                sc.setFillColor(NSColor.white.cgColor)
                sc.fill(NSRect(x: 0, y: 0, width: n, height: n))
                sc.setBlendMode(.destinationIn)
                sc.draw(cg, in: NSRect(x: 0, y: 0, width: n, height: n))
                NSGraphicsContext.restoreGraphicsState()
                return shade.cgImage
            }
            let big = render(3, px: 54)
            if let m = big.map({ MenuBarIcon.measure($0, scale: 3) }) {
                print(String(format: "%-26@ cover %.1f%%  bbox x %.2f…%.2f  y %.2f…%.2f",
                             v.name as NSString, m.coverage * 100,
                             m.bbox.minX, m.bbox.maxX, m.bbox.minY, m.bbox.maxY))
            }
            ctx.setFillColor(NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).cgColor)
            ctx.fill(NSRect(x: x, y: CGFloat(H) - CGFloat(cell) - 8, width: CGFloat(cell), height: CGFloat(cell)))
            if let cg = white(big) {
                ctx.draw(cg, in: NSRect(x: x, y: CGFloat(H) - CGFloat(cell) - 8,
                                        width: CGFloat(cell), height: CGFloat(cell)))
            }
            // 下面两格：36px 放大 4 倍、18px 放大 8 倍
            let rowY = CGFloat(H) - CGFloat(cell) - 8 - 150
            for (k, (scale, zoom)) in [(CGFloat(2), 4), (1, 8)].enumerated() {
                let px = 36 * zoom / 2
                let gx = x + CGFloat(k) * (CGFloat(px) + 8)
                ctx.setFillColor(NSColor(srgbRed: 0.19, green: 0.19, blue: 0.20, alpha: 1).cgColor)
                ctx.fill(NSRect(x: gx, y: rowY, width: CGFloat(px), height: CGFloat(px)))
                if let cg = white(render(scale, px: 0)) {
                    ctx.draw(cg, in: NSRect(x: gx, y: rowY, width: CGFloat(px), height: CGFloat(px)))
                }
            }
            (v.name as NSString).draw(at: NSPoint(x: x, y: CGFloat(H) - CGFloat(cell) - 26),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                                       .foregroundColor: NSColor(white: 0.62, alpha: 1)])
        }
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "/tmp/mbgeom.png"))
        print("wrote /tmp/mbgeom.png \(W)x\(H)")
        exit(0)
    }
}

// 菜单栏右键菜单：条目、顺序、快捷键、target 是否都绑上了。
// 「加了菜单项但 target 为 nil / 忘了设 action」是这类菜单最常见的静默失败：
// 菜单看着正常，点下去什么都没发生。
if args.contains("--menutest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "✓ \(name)" : "✗ \(name)\(detail.isEmpty ? "" : "  ← \(detail)")")
            if !ok { failures += 1 }
        }

        let delegate = AppDelegate()
        let menu = AppDelegate.makeStatusMenu(target: delegate)

        let titles = menu.items.compactMap { $0.isSeparatorItem ? nil : $0.title }
        check("条目顺序：新建便签 / 打开便签墙 / 设置… / 退出",
              titles == ["新建便签", "打开便签墙", "设置…", "退出"], "\(titles)")

        let seps = menu.items.enumerated().filter { $0.element.isSeparatorItem }.map(\.offset)
        check("两条分隔线，分别在动作之后与设置之后（实得 \(seps)）", seps == [2, 4])

        let actionable = menu.items.filter { !$0.isSeparatorItem }
        check("每项都绑了 target（点下去不会静默失败）",
              actionable.allSatisfy { $0.target != nil },
              actionable.filter { $0.target == nil }.map(\.title).joined(separator: ","))
        check("每项都有 action", actionable.allSatisfy { $0.action != nil })
        check("每项都是 enabled", actionable.allSatisfy(\.isEnabled))

        guard let settings = actionable.first(where: { $0.title == "设置…" }) else {
            print("✗ 找不到「设置…」"); exit(1)
        }
        check("设置项快捷键是 ⌘,（macOS 惯例）", settings.keyEquivalent == ",")
        check("设置项 action 指向 openPreferences",
              settings.action == #selector(AppDelegate.openPreferences))

        guard let quit = actionable.first(where: { $0.title == "退出" }) else {
            print("✗ 找不到「退出」"); exit(1)
        }
        check("退出项快捷键是 ⌘Q", quit.keyEquivalent == "q")

        // 点「设置…」会发生什么：把「待弹设置」的旗子立起来，供 WallView 消费
        AppContext.shared.pendingOpenSettings = false
        delegate.openPreferences()
        check("点「设置…」会立起待弹设置的旗子", AppContext.shared.pendingOpenSettings)
        AppContext.shared.pendingOpenSettings = false

        print(failures == 0 ? "menutest 全部通过" : "menutest \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}

// 把菜单真正弹到屏幕上再截一张：条目顺序、⌘, 有没有显示出来，只有看图才靠谱。
// 不点菜单栏图标（那要辅助功能授权），直接 `popUp` 一份同样内容的菜单。
if args.contains("--menupreview") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        let menu = AppDelegate.makeStatusMenu(target: delegate)
        let i = args.firstIndex(of: "--out")
        let path = (i != nil && i! + 1 < args.count) ? args[i! + 1] : "/tmp/statusmenu.png"

        let shot = Timer(timeInterval: 1.1, repeats: false) { _ in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-x", path]
            try? proc.run()
            proc.waitUntilExit()
            menu.cancelTracking()
        }
        RunLoop.main.add(shot, forMode: .common)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            menu.popUp(positioning: nil, at: NSPoint(x: 980, y: 700), in: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            print("wrote \(path)")
            exit(0)
        }
        NSApp.run()
    }
}

// 自检：快捷键注册 / 冲突 / 回滚（不弹任何 UI）
if args.contains("--hotkeys") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "✓ \(name)" : "✗ \(name)")
            if !ok { failures += 1 }
        }

        let center = HotKeyCenter.shared
        center.install()

        // 基准配置用冷门组合，避免本机真实安装的工具干扰断言
        func combo(_ keyCode: Int, _ mods: UInt32) -> HotkeyCombo {
            HotkeyCombo(keyCode: UInt32(keyCode), carbonModifiers: mods)
        }
        let cold = UInt32(cmdKey | optionKey | controlKey)
        let base = HotkeyConfig(newNote: combo(kVK_F14, cold), openWall: combo(kVK_F15, cold))
        check("基准配置注册成功", center.apply(base) == nil)
        check("两位都处于注册状态", center.isActive(base.newNote) && center.isActive(base.openWall))

        // 冲突回滚：先占住一个组合，再整组换成它——必须失败，且失败后原配置原样生效
        let victim = combo(kVK_F13, cold)
        var probe = base
        probe.openWall = victim
        if let held = center.hold(victim) {
            check("被占用的组合注册失败并指明是哪一位", center.apply(probe) == .openWall)
            check("失败后整组回滚：原来的两位仍然生效",
                  center.isActive(base.newNote) && center.isActive(base.openWall))
            check("失败后整组回滚：被占用的组合没有被注册", !center.isActive(victim))
            center.release(held)
        } else {
            check("占住测试组合（前置）", false)
        }
        check("占用释放后同一配置可以换上", center.apply(probe) == nil)
        check("换上后新组合生效", center.isActive(victim) && center.isActive(base.newNote))

        // 默认组合的现状（只报告，不判失败：被 Raycast 之类占用是正常环境差异）
        for (slot, combo2) in [(HotkeySlot.newNote, HotkeyConfig.standard.newNote),
                               (HotkeySlot.openWall, HotkeyConfig.standard.openWall)] {
            let free = center.isAvailable(combo2)
            print("\(slot.rawValue) \(combo2.display): \(free ? "可用" : "被占用")")
        }

        // 录键控件最易错的一环：NSEvent 的修饰键 → Carbon 掩码
        if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                     modifierFlags: [.command, .shift],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "K", charactersIgnoringModifiers: "k",
                                     isARepeat: false, keyCode: UInt16(kVK_ANSI_K)) {
            let combo = HotkeyCombo(event: ev)
            check("按键事件转组合键（⌘⇧K）", combo.display == "⇧ ⌘ K")
            check("事件里的组合能通过校验", HotkeyRules.problem(combo) == nil)
        } else {
            check("按键事件转组合键（⌘⇧K）", false)
        }
        if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                     modifierFlags: [],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "k", charactersIgnoringModifiers: "k",
                                     isARepeat: false, keyCode: UInt16(kVK_ANSI_K)) {
            check("裸字母事件会被规则拦住", HotkeyRules.problem(HotkeyCombo(event: ev)) != nil)
        } else {
            check("裸字母事件会被规则拦住", false)
        }

        print(failures == 0 ? "全部通过" : "\(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}

// 设计对照：点击态「等比放大」的候选尺寸（只出图，不装面板）
if args.contains("--notchratio") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        guard let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let g = NotchMetrics.geometry(for: s) else {
            print("· 当前屏幕没有刘海，跳过")
            exit(0)
        }
        let png = args.first(where: { $0.hasSuffix(".png") }) ?? "/tmp/notch-ratio.png"
        print(NotchRatioPreview.render(geometry: g, screenWidth: s.frame.width, to: png)
              ? "候选图    \(png)" : "✗ 渲染失败")
        exit(0)
    }
}

// 自检：刘海入口几何（两个入口必须完全落在物理刘海之外）
if args.contains("--notchtest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        guard let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            print("· 当前屏幕没有刘海，跳过检查")
            exit(0)
        }
        guard let g = NotchMetrics.geometry(for: s) else {
            print("✗ 无法读取刘海几何")
            exit(1)
        }

        let rects = g.buttonRects(panelWidth: g.expandedWidth)
        let leftClear = g.leftX - rects.left.maxX
        let rightClear = rects.right.minX - g.rightX

        print("屏幕      \(Int(s.frame.width)) × \(Int(s.frame.height))")
        print("物理刘海  x \(Int(g.leftX)) … \(Int(g.rightX))   宽 \(Int(g.width))  高 \(Int(g.height))")
        print("面板宽度  收起 \(Int(g.collapsedWidth)) / 展开 \(Int(g.expandedWidth))")
        print("左入口    x \(Int(rects.left.minX)) … \(Int(rects.left.maxX))   距刘海 \(Int(leftClear))")
        print("右入口    x \(Int(rects.right.minX)) … \(Int(rects.right.maxX))   距刘海 \(Int(rightClear))")

        // 净距小于 8pt 在视觉上就等于贴着刘海，判失败
        let clearOK = leftClear >= 8 && rightClear >= 8
        print(clearOK ? "✓ 两个入口都完全避开物理刘海" : "✗ 入口会被物理刘海遮挡")

        // 收起态：必须与刘海同宽，且一个像素都不画
        let collapsedX0 = g.centerX - g.collapsedWidth / 2
        let sameWidth = abs(g.collapsedWidth - g.width) < 0.5
        print("收起面板  x \(Int(collapsedX0)) … \(Int(collapsedX0 + g.collapsedWidth))   与刘海同宽 \(sameWidth ? "是" : "否")")

        let collapsedModel = NotchModel()
        collapsedModel.notchWidth = g.width
        collapsedModel.isExpanded = false
        let cr = ImageRenderer(content: NotchContentView(model: collapsedModel)
            .frame(width: g.collapsedWidth, height: g.height))
        cr.scale = 2
        let painted = cr.cgImage.map(NotchPixel.countVisible) ?? 0
        let blankOK = painted == 0
        print(blankOK ? "✓ 收起态零像素（不会在刘海周围留黑）"
                      : "✗ 收起态画了 \(painted) 个像素，会压在菜单栏上")

        let ok = clearOK && sameWidth && blankOK

        // 对照图：收起 / 展开 两种状态叠在模拟菜单栏上
        let png = args.first(where: { $0.hasSuffix(".png") }) ?? "/tmp/notch-preview.png"

        @MainActor
        func renderPanel(expanded: Bool, width: CGFloat) -> CGImage? {            let m = NotchModel()
            m.notchWidth = g.width
            m.isExpanded = expanded
            let r = ImageRenderer(content: NotchContentView(model: m)
                .frame(width: width, height: g.height))
            r.scale = 2
            return r.cgImage
        }
        let collapsedCG = renderPanel(expanded: false, width: g.collapsedWidth)
        let expandedCG = renderPanel(expanded: true, width: g.expandedWidth)

        func notchPath(width: CGFloat, height: CGFloat, radius: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: height))
            p.line(to: NSPoint(x: 0, y: radius))
            p.appendArc(withCenter: NSPoint(x: radius, y: radius),
                        radius: radius, startAngle: 180, endAngle: 270)
            p.line(to: NSPoint(x: width - radius, y: 0))
            // 从当前点 (width-radius, 0) 起弧：270° → 360°，逆时针走到 (width, radius)
            p.appendArc(withCenter: NSPoint(x: width - radius, y: radius),
                        radius: radius, startAngle: 270, endAngle: 360)
            p.line(to: NSPoint(x: width, y: height))
            p.close()
            return p
        }

        let W = g.expandedWidth + 90
        let rowH: CGFloat = 86
        let H = 22 + rowH * 2 + 16
        let canvas = NSImage(size: NSSize(width: W, height: H))
        canvas.lockFocus()
        NSColor(srgbRed: 0.98, green: 0.975, blue: 0.965, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()

        func drawRow(_ index: Int, title: String, cg: CGImage?, panelW: CGFloat) {
            let stripY = H - 22 - CGFloat(index + 1) * rowH + rowH - 32
            let strip = NSRect(x: 18, y: stripY, width: W - 36, height: 32)

            // 菜单元栏：模拟浅色半透明
            let grad = NSGradient(colors: [
                NSColor(srgbRed: 0.945, green: 0.925, blue: 0.898, alpha: 1),
                NSColor(srgbRed: 0.902, green: 0.876, blue: 0.846, alpha: 1)
            ])!
            grad.draw(in: strip, angle: -90)

            // 物理刘海（硬件）：黑色 + 下圆角
            let nx = strip.midX - g.width / 2
            let path = notchPath(width: g.width, height: 32, radius: 9)
            let tf = AffineTransform(translationByX: nx, byY: strip.minY)
            path.transform(using: tf)
            NSColor.black.setFill()
            path.fill()

            // 面板渲染（收起态是真的什么都没有）
            if let cg {
                NSGraphicsContext.current?.imageInterpolation = .high
                NSImage(cgImage: cg, size: NSSize(width: panelW, height: 32))
                    .draw(in: NSRect(x: strip.midX - panelW / 2, y: strip.minY,
                                     width: panelW, height: 32))
            }

            let t = title as NSString
            t.draw(at: NSPoint(x: 18, y: stripY - 26), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 0.30, green: 0.29, blue: 0.28, alpha: 1)])
        }

        drawRow(0, title: "收起（默认）：面板与刘海同宽、不画任何像素 —— 刘海保持原生圆角", cg: collapsedCG, panelW: g.collapsedWidth)
        drawRow(1, title: "展开（鼠标悬停）：向两侧长出黑色两翼，入口贴在刘海两侧外 12pt", cg: expandedCG, panelW: g.expandedWidth)

        canvas.unlockFocus()
        if let tiff = canvas.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: png))
            print("对照图    \(png)")
        }
        exit(ok ? 0 : 1)
    }
}

// 调试：把捕获面板显示几秒，供外部截屏取证（不落任何数据）
// 调试：把捕获面板显示 5 秒，供外部截屏取证（不落任何数据）
if args.contains("--capturetest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        ScrollChrome.startWatching()
        // 必须持有强引用：CaptureController 里是 weak
        let probeStore = AppStore(inMemory: true)
        CaptureController.shared.attach(store: probeStore)
        CaptureController.shared.show()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        // 量「光标 vs 占位文字」的垂直偏差：必须用真实面板（离屏渲染没有插入点）
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.level == .floating }) {
            print("panel isKey=\(w.isKeyWindow) firstResponder=\(type(of: w.firstResponder ?? NSView()))")
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: "shots", isDirectory: true), withIntermediateDirectories: true)
            let sp = Process()
            sp.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            sp.arguments = ["-x", "-l", "\(w.windowNumber)", "shots/capture-cursor.png"]
            try? sp.run()
            sp.waitUntilExit()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(3.0))
        for w in NSApp.windows where w.isVisible {
            print("panel \(Int(w.frame.width))×\(Int(w.frame.height)) at (\(Int(w.frame.minX)), \(Int(w.frame.minY)))")
            var total = 0, notOverlay = 0
            func scan(_ v: NSView?) {
                guard let v else { return }
                if let sv = v as? NSScrollView {
                    total += 1
                    if sv.scrollerStyle != .overlay { notOverlay += 1 }
                }
                for sub in v.subviews { scan(sub) }
            }
            scan(w.contentView)
            print(notOverlay == 0 ? "✓ 滚动条全部 overlay（\(total) 个 NSScrollView）"
                                  : "✗ 有 \(notOverlay)/\(total) 个滚动条仍是常驻样式")
        }
        exit(0)
    }
}

// 边缘条：把三态跑起来做几何断言 + 供外部截屏取证（不注入任何系统事件）
if args.contains("--edgetest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        // 必须与真实 App 一致用 .regular：.accessory 下窗口 isVisible 为 true
        // 但 WindowServer 并不一定真正上屏，截屏与窗口列表都拿不到，断言会变成假阳性
        NSApp.setActivationPolicy(.regular)

        let es = AppStore.demo()
        es.edgeMode = .recent
        EdgeDeckController.shared.attach(store: es)
        let ctl = EdgeDeckController.shared

        func windowFrame() -> CGRect? {
            NSApp.windows.first { $0.isVisible && $0.level == .floating }?.frame
        }
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "✓ \(name)" : "✗ \(name)")
        }
        let vf = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        // 截图取证：自己调 screencapture，时机完全可控（外部 sleep 掐不准）
        let shotDir = URL(fileURLWithPath: "shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        func shot(_ name: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", shotDir.appendingPathComponent("edge-\(name).png").path]
            try? p.run()
            p.waitUntilExit()
        }

        // ① 细条
        ctl.model.phase = .rest
        ctl.reposition(animated: false)
        // 窗口刚上屏时 WindowServer 可能还没把 frame 同步回来：固定等 0.4s 在
        // 连续跑多组测试时会偶发读到旧 frame（假阳性），改成轮询等它稳定。
        var restFrame: CGRect?
        for _ in 0..<12 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            if let f = windowFrame(),
               abs(f.width - (EdgeDeckGeom.restWidth + EdgeDeckGeom.overshoot)) < 0.5 {
                restFrame = f
                break
            }
        }
        if let f = restFrame ?? windowFrame() {
            check("细条宽度 = 12pt + 屏幕外 overshoot",
                  abs(f.width - (EdgeDeckGeom.restWidth + EdgeDeckGeom.overshoot)) < 0.5)
            check("细条右缘越过屏幕边缘 overshoot",
                  abs(f.maxX - (vf.maxX + EdgeDeckGeom.overshoot)) < 0.5)
        } else {
            check("细条面板存在", false)
        }
        shot("rest")

        // ② 扇开（底部带两颗常驻圆钮）
        ctl.model.phase = .fan
        ctl.reposition(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let f = windowFrame() {
            let pad = EdgeDeckGeom.bleed(for: .fan)
            let n = EdgeDeckGeom.stackCapacity(visibleHeight: vf.height, requested: es.edgeNotes.count)
            let expectH = EdgeDeckGeom.stackHeight(count: min(n, es.edgeNotes.count))
                + EdgeDeckGeom.actionBlockHeight + pad * 2
            check("扇开高度 = 签叠 + 按钮区 + 上下衬边",
                  abs(f.height - expectH) < 1)
            check("扇开宽度 = 签宽 + 内侧衬边 + overshoot",
                  abs(f.width - (EdgeDeckGeom.tabWidth + pad + EdgeDeckGeom.overshoot)) < 0.5)
            check("扇开时纸签仍贴屏幕边缘（衬边只在屏幕内侧）",
                  abs(EdgeDeckGeom.contentEdge(side: es.edgeSide, frame: f, bleed: pad) - vf.maxX) < 0.5)
        } else {
            check("扇开面板存在", false)
        }
        shot("fan")

        // ③ 抽出：面板 + 仍在的签列 + 两颗圆钮。停 3s 供人工核对
        if let n = es.edgeNotes.first {
            ctl.pull(n.id)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            if let f = windowFrame() {
                let pad = EdgeDeckGeom.bleed(for: .pull(n.id))
                check("抽出宽度 = 面板 + 签列 + 内侧衬边 + overshoot",
                      abs(f.width - (EdgeDeckGeom.noteWidth + EdgeDeckGeom.tabWidth
                                     + pad + EdgeDeckGeom.overshoot)) < 0.5)
                check("抽出时纸签仍贴屏幕边缘（零缝隙）",
                      abs(EdgeDeckGeom.contentEdge(side: es.edgeSide, frame: f, bleed: pad) - vf.maxX) < 0.5)
                check("抽出高度装得下面板与签列",
                      f.height >= EdgeDeckGeom.noteHeight(text: ctl.model.draft) - 1)
                check("衬边 ≥ 阴影实际扩散（2×半径 + 偏移）",
                      pad >= EdgeDeckGeom.noteShadowBleed)
            } else {
                check("抽出面板存在", false)
            }
            print("pull \(Int(windowFrame()?.width ?? 0))×\(Int(windowFrame()?.height ?? 0))")
            shot("pull")

            // 抽出面板的编辑器同样要过输入法这一关：它每次 onEdit 都会写回 store，
            // 是比主界面更容易触发 SwiftUI 重算的地方
            let edgeWin = NSApp.windows.first { $0.isVisible && $0.level == .floating }
            if let tv = findView(NSTextView.self, in: edgeWin?.contentView) {
                // 抽出的是已有便签，框里本来就有正文；组合串会追加在光标处
                let original = tv.string
                tv.setMarkedText("ni'hao", selectedRange: NSRange(location: 6, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
                RunLoop.main.run(until: Date().addingTimeInterval(0.35))
                check("抽出面板组合输入：拼音没被删",
                      tv.hasMarkedText() && tv.string == original + "ni'hao")
                es.update(n)     // 模拟 onEdit 写回 store 引起的整树重算
                RunLoop.main.run(until: Date().addingTimeInterval(0.35))
                check("抽出面板写回 store 后拼音仍在",
                      tv.hasMarkedText() && tv.string == original + "ni'hao")
                tv.string = n.text
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            } else {
                check("抽出面板找到编辑器", false)
            }

            // 用户报的现象：抽第 3 张、随手按回车，它会跳到第 1 位、面板跟着上移。
            // 这里直接模拟「写回刷新 updatedAt」，窗口 frame 必须一动不动。
            if es.edgeNotes.count >= 3 {
                ctl.collapse()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                let third = es.edgeNotes[2]
                ctl.pull(third.id)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let before = windowFrame()
                es.update(third)          // 只刷新 updatedAt，正文不变
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let after = windowFrame()
                check("编辑写回后面板不跳位（顺序已冻结）",
                      before != nil && after != nil && abs(before!.minY - after!.minY) < 0.5
                      && abs(before!.height - after!.height) < 0.5)
                check("被编辑的那张仍在原序号",
                      ctl.model.ordered(es.edgeNotes).firstIndex(where: { $0.id == third.id }) == 2)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(3.0))
        }
        ctl.collapse()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check("收起后回到细条宽度",
              abs((windowFrame()?.width ?? 0) - (EdgeDeckGeom.restWidth + EdgeDeckGeom.overshoot)) < 0.5)
        exit(0)
    }
}

// 设置页：真实窗口里跑一遍再截图。
// 离屏渲染只能给 Toggle 画替身、把 Menu 降级成静态胶囊，只有真窗口才能看出
// 系统控件有没有在自己的 label 外面多塞一圈 padding。
if args.contains("--settingstest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let store = AppStore.demo()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsSheet.windowWidth, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = "设置"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        if args.contains("dark") { win.appearance = NSAppearance(named: .darkAqua) }
        win.contentView = NSHostingView(
            rootView: SettingsSheet(onClose: {}).environmentObject(store))
        win.center()
        // 命令行二进制没有正常的 App 激活流程：不显式 activate + 抬层级，
        // 窗口会老老实实待在别人后面，截出来的就是误报
        win.level = .floating
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.8))

        let f = win.frame
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: "shots", isDirectory: true), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // 按窗口 ID 截，不用 -R 区域：窗口可能落在扩展屏上，屏幕坐标一算就偏
        p.arguments = ["-x", "-l", "\(win.windowNumber)", "shots/settings-real.png"]
        try? p.run()
        p.waitUntilExit()
        print("settings window \(Int(f.width))×\(Int(f.height)) id \(win.windowNumber)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        exit(0)
    }
}

// MARK: - 输入法组合态回归
//
// v0.9 的回归：占位探针每 120ms 发布一次 @Published，SwiftUI 重算整棵含
// TextEditor 的视图树并把空 binding 写回 NSTextView，用户敲的拼音字母被抹掉。
// 这组断言直接用真实的 NSHostingView + TextEditor 复现「打字中」的场景。

final class IMETestBuf: ObservableObject {
    @Published var text = ""
    /// 模拟无关的 store / Toast 发布，检验视图重算会不会顺带吃掉组合文本
    @Published var noise = 0
}

struct IMETestView: View {
    @ObservedObject var buf: IMETestBuf

    var body: some View {
        ZStack(alignment: .topLeading) {
            EditorPlaceholder(text: "记下点什么…", color: T.textFaint, fontSize: 15)
                .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .topLeading)
                .allowsHitTesting(false)
            PlainTextEditor(text: buf.bind(\.text), fontSize: 15, ink: T.text)
                .frame(height: 76)
            // 让 buf.noise 的变化真的触发整棵树重算（而不是只在对象里改了个值）
            Text("\(buf.noise)").hidden().frame(width: 0, height: 0)
        }
        .frame(width: 420, height: 160, alignment: .topLeading)
        .background(Color.white)
    }
}

func findView<T: NSView>(_ type: T.Type, in root: NSView?) -> T? {
    guard let root else { return nil }
    if let hit = root as? T { return hit }
    for sub in root.subviews {
        if let hit = findView(type, in: sub) { return hit }
    }
    return nil
}

if args.contains("--imetest") || args.contains("--probretest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let buf = IMETestBuf()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "imetest"
        win.contentView = NSHostingView(rootView: IMETestView(buf: buf))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))

        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "✓ \(name)" : "✗ \(name)")
            if !ok { failures += 1 }
        }
        func settle(_ seconds: Double = 0.25) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        let tv = findView(NSTextView.self, in: win.contentView)
        let holder = findView(EditorPlaceholderView.self, in: win.contentView)
        check("找到 TextEditor 的 NSTextView", tv != nil)
        check("找到原生占位的 EditorPlaceholderView", holder != nil)

        if let tv, let holder {
            win.makeFirstResponder(tv)
            settle()
            check("空输入框：占位可见", holder.hasContent == false)
            check("占位不拦鼠标事件", holder.hitTest(.zero) == nil)

            // ① 中文输入法敲第一个字母：setMarkedText，binding 仍是空串
            tv.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
            settle(0.35)
            check("★ 组合输入第 1 个字母没有被删掉（tv.string == \"n\"）", tv.string == "n")
            check("组合输入未上屏：占位已隐藏", holder.hasContent)

            // ② 继续拼：整串拼音都要留住，不能每敲一个就被清一次
            tv.setMarkedText("ni'hao", selectedRange: NSRange(location: 6, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
            settle(0.35)
            check("★ 连续拼音 ni'hao 完整保留", tv.string == "ni'hao")
            check("多字母组合期间占位保持隐藏", holder.hasContent)

            // ③ 打字过程中别处发了 @Published（Toast / store 之类），也不能吃字
            buf.noise += 1
            settle(0.35)
            check("★ 无关 @Published 触发视图重算后，拼音仍在", tv.string == "ni'hao")
            check("组合期间草稿里没有混进拼音", buf.text.isEmpty)

            // ④ 选词上屏：binding 与 text view 同步，占位继续藏
            buf.text = "你好"
            tv.string = "你好"
            settle(0.35)
            check("选词上屏后正文正确", tv.string == "你好")
            check("有正文时占位隐藏", holder.hasContent)

            // ⑤ 清空：占位回来
            buf.text = ""
            tv.string = ""
            settle(0.35)
            check("清空输入框：占位重新出现", holder.hasContent == false)
            check("清空后 tv.string 为空", tv.string.isEmpty)

            // ⑥ 英文直接输入（不用输入法）也不该被占位逻辑干扰；
            //    更关键的是要同步进 binding，否则 ⌘↩ / 保存按钮读到的还是空串
            tv.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
            settle(0.35)
            check("直接键入 hello 完整保留", tv.string == "hello")
            check("★ 键入内容同步进 binding（⌘↩ / 保存按钮才存得上）", buf.text == "hello")

            // ⑦ 只改外层 binding（清空草稿 / 载入别的便签）文本框也要跟着走
            buf.text = ""
            settle(0.35)
            check("★ 外部清空草稿后文本框同步清空", tv.string.isEmpty)
            buf.text = "载入的正文"
            settle(0.35)
            check("★ 外部载入正文后文本框同步显示", tv.string == "载入的正文")
        }
        print(failures == 0 ? "imetest 全部通过" : "imetest \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}

// 真实主界面窗口：占位是否画得出来、输入法组合时是否收起、字有没有被吞
/// `--gridtest` 用：收集 MasonryLayout.placeSubviews 的真实落点
final class LayoutFrameRecorder {
    var frames: [CGRect] = []
}

// 手型光标的迟滞状态机：纯逻辑，不碰真鼠标。
// 用户报的 bug 是「点纸签时光标在箭头和手型之间来回闪」——根因是点击那一下
// 窗口变宽 + 视图树重建，让「是否命中垫片」在几十毫秒里反复真假，而老逻辑
// 一帧没命中就立刻切回箭头。这里把那个场景直接编成序列，断言不会闪。
if args.contains("--handtest") {
    MainActor.assumeIsolated {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "✓ \(name)" : "✗ \(name)")
            if !ok { failures += 1 }
        }
        let t0: TimeInterval = 1000

        // ① 进入要跟手：命中第一帧就变
        var s = HandCursorLogic()
        check("命中第一帧即变手型", s.step(hit: true, mouseDown: false, moved: true, now: t0) == .toHand && s.isHand)
        check("区域内保持，不重复写光标", s.step(hit: true, mouseDown: false, moved: true, now: t0 + 0.04) == .none)

        // ② 单帧、双帧、三帧未命中都不切（垫片重建期间就是这样）
        let singleMiss = s.step(hit: false, mouseDown: false, moved: true, now: t0 + 0.08)
        let twoMiss = s.step(hit: false, mouseDown: false, moved: true, now: t0 + 0.12)
        let threeMiss = s.step(hit: false, mouseDown: false, moved: true, now: t0 + 0.16)
        check("瞬间未命中 1 帧不切箭头（实得 \(singleMiss)）", singleMiss == .none && s.isHand)
        check("连续 2 帧未命中不切", twoMiss == .none && s.isHand)
        check("连续 3 帧未命中不切", threeMiss == .none && s.isHand)

        // ③ 第 4 帧才真的离开
        check("连续 4 帧未命中才回箭头",
              s.step(hit: false, mouseDown: false, moved: true, now: t0 + 0.20) == .toArrow && !s.isHand)

        // ④ 「命中 / 未命中」交替 20 次 —— 就是用户看到的闪烁场景
        var flicker = HandCursorLogic()
        _ = flicker.step(hit: true, mouseDown: false, moved: true, now: t0)
        var arrowCount = 0
        for i in 0..<20 {
            let hit = i % 2 == 0
            if flicker.step(hit: hit, mouseDown: false, moved: true, now: t0 + 0.04 * Double(i + 1)) == .toArrow {
                arrowCount += 1
            }
        }
        check("命中/未命中交替 20 帧，0 次切回箭头（实得 \(arrowCount) 次）", arrowCount == 0 && flicker.isHand)

        // ⑤ 按住鼠标时不切：点击那一下本来就只有一两百毫秒
        var down = HandCursorLogic()
        _ = down.step(hit: true, mouseDown: true, moved: true, now: t0)
        var downArrow = 0
        for i in 0..<10 {
            if down.step(hit: false, mouseDown: true, moved: true, now: t0 + 0.04 * Double(i + 1)) == .toArrow {
                downArrow += 1
            }
        }
        check("鼠标键按住时未命中 10 帧也不切（实得 \(downArrow) 次）", downArrow == 0 && down.isHand)

        // ⑥ 布局动画期间由 hold() 钉住
        var held = HandCursorLogic()
        held.hold(until: t0 + 0.6)
        _ = held.step(hit: true, mouseDown: false, moved: true, now: t0)
        var heldArrow = 0
        for i in 0..<14 {     // 14 × 40ms = 560ms，仍在 hold 窗口内
            if held.step(hit: false, mouseDown: false, moved: true, now: t0 + 0.04 * Double(i + 1)) == .toArrow {
                heldArrow += 1
            }
        }
        check("hold 期间未命中 14 帧不切（实得 \(heldArrow) 次）", heldArrow == 0 && held.isHand)
        check("hold 过期后仍未命中 → 回箭头",
              held.step(hit: false, mouseDown: false, moved: true, now: t0 + 0.62) == .toArrow && !held.isHand)

        // ⑦ 动一下之后停住（移到输入框就是这样）：仍然要能离开
        var movedOnce = HandCursorLogic()
        _ = movedOnce.step(hit: true, mouseDown: false, moved: true, now: t0)
        _ = movedOnce.step(hit: false, mouseDown: false, moved: true, now: t0 + 0.04)   // 移动中
        var stopped = 0
        for i in 0..<3 {   // 停住后再数 3 帧
            if movedOnce.step(hit: false, mouseDown: false, moved: false, now: t0 + 0.08 + 0.04 * Double(i))
                == .toArrow { stopped += 1 }
        }
        check("动过之后手停住，仍能回箭头（实得 \(stopped) 次）", stopped == 1 && !movedOnce.isHand)

        // ⑧ 手没动、只是布局变了（窗口变宽 / 垫片重建）：一直保持手型
        var still = HandCursorLogic()
        _ = still.step(hit: true, mouseDown: false, moved: true, now: t0)
        var stillArrow = 0
        for i in 0..<20 {
            if still.step(hit: false, mouseDown: false, moved: false, now: t0 + 0.04 * Double(i + 1))
                == .toArrow { stillArrow += 1 }
        }
        check("手没动时未命中 20 帧也不切（布局抖动不该拨光标，实得 \(stillArrow) 次）",
              stillArrow == 0 && still.isHand)
        // 手一动，离开判定立刻恢复
        var moved = 0
        for i in 0..<4 {
            if still.step(hit: false, mouseDown: false, moved: true, now: t0 + 1.0 + 0.04 * Double(i))
                == .toArrow { moved += 1 }
        }
        check("手一动，未命中 4 帧就回箭头（实得 \(moved) 次）", moved == 1 && !still.isHand)

        // ⑧ 真的离开（鼠标持续移动着走开）仍要回箭头，别把「稳定」做成「卡住」
        var leave = HandCursorLogic()
        _ = leave.step(hit: true, mouseDown: false, moved: true, now: t0)
        for i in 1...3 { _ = leave.step(hit: false, mouseDown: false, moved: true, now: t0 + 0.04 * Double(i)) }
        check("移开后第 4 帧回箭头",
              leave.step(hit: false, mouseDown: false, moved: true, now: t0 + 0.2) == .toArrow)

        // ⑧ 迟滞窗口长度有上界：不能长到「移开了还赖着手型」
        check("离开去抖 ≤ 200ms（实得 \(HandCursorLogic().leaveTicks * 40)ms）",
              HandCursorLogic().leaveTicks * 40 <= 200)

        print(failures == 0 ? "handtest 全部通过" : "handtest \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}

// 回归（v0.9.15）：边缘悬浮窗口**不再**接手型光标。
// floating 面板（窗口动画 + SwiftUI 视图树重建）和 WindowServer 的光标管理
// 反复打架，补了三层（迟滞状态机 / runloop 观察者 / 事件监视器）仍偶发可见闪烁，
// 用户拍板：边缘窗口保持系统默认光标。这里守住新行为——指着纸签、点击抽出、
// 抽出后停留，全程不得出现手型；谁要是把 `.handCursor` 挂回 EdgeDeck，这项立刻红。
if args.contains("--clickfliptest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "✓ \(name)" : "✗ \(name)\(detail.isEmpty ? "" : "  ← \(detail)")")
            if !ok { failures += 1 }
        }
        func H() -> CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
        func warp(_ p: NSPoint) { CGWarpMouseCursorPosition(CGPoint(x: p.x, y: H() - p.y)) }
        func settle(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
        func cg(_ t: CGEventType, _ p: NSPoint, _ jitter: CGFloat = 0) {
            CGEvent(mouseEventSource: nil, mouseType: t,
                    mouseCursorPosition: CGPoint(x: p.x + jitter, y: H() - p.y),
                    mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        // 这个测试二进制没有跑 NSApp.run()，CGEvent 合成的事件不会自己派发。
        // 手动 postEvent + sendEvent 才能真的走到 addLocalMonitorForEvents 那条路。
        func postLocal(_ t: NSEvent.EventType, _ p: NSPoint) {
            let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: 0, context: nil,
                                       eventNumber: 1, clickCount: t == .leftMouseDown ? 1 : 0,
                                       pressure: t == .leftMouseDown ? 1 : 0)
            if let e { NSApp.postEvent(e, atStart: false) }
        }
        func pump() {
            for _ in 0..<3 {
                if let e = NSApp.nextEvent(matching: [.any], until: Date().addingTimeInterval(0.002),
                                           inMode: .default, dequeue: true) {
                    NSApp.sendEvent(e)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
        }
        guard let originalPoint = Optional(NSEvent.mouseLocation) else { exit(1) }
        CGAssociateMouseAndMouseCursorPosition(1)

        let store = AppStore.demo()
        store.edgeMode = .recent
        let ctl = EdgeDeckController.shared
        ctl.attach(store: store)
        ctl.model.phase = .fan
        ctl.reposition(animated: false)
        settle(1.2)
        guard let panel = NSApp.windows.first(where: { $0.isVisible && $0.level == .floating }) else {
            check("边缘条面板上屏", false); exit(1)
        }
        // 边缘窗口里不该再有任何手型垫片（v0.9.15 起停用）
        func collect(_ v: NSView?, into out: inout [HandCursorView]) {
            guard let v else { return }
            if let h = v as? HandCursorView { out.append(h) }
            for s in v.subviews { collect(s, into: &out) }
        }
        var pads: [HandCursorView] = []
        collect(panel.contentView, into: &pads)
        check("边缘窗口没有注册手型垫片（实得 \(pads.count) 个）", pads.isEmpty)

        func decoyPadVisible(_ w: NSWindow) -> String {
            MainActor.assumeIsolated {
                guard let cv = w.contentView else { return "无 contentView" }
                return "pad windowRect=\(HandCursorRegistry.windowRect(of: cv)) visible=\(w.isVisible)"
            }
        }

        // 活垫片必须在场：注册表为空时轮询 timer 不会启动，tick 不跑，
        // 「点击宽限期凭空命中」这类回归就永远测不到——v0.9.15 的测试就是这么假绿的：
        // 边缘窗口摘了垫片 → timer 停了 → 状态机根本没运行 → 断言 isHand==false 恒成立。
        // 挂一个远离边缘条的活垫片，让状态机真的每 40ms 判定一次，再看它动不动。
        let decoy = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 120, height: 80),
                             styleMask: [.titled], backing: .buffered, defer: false)
        decoy.title = "clickfliptest-decoy"
        decoy.contentView = HandCursorView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        decoy.makeKeyAndOrderFront(nil)
        // 新窗口会被 AppKit 级联挪位（实测 frame.minY 从 60 漂到 122），必须钉回去；
        // 位置不对的话对照点会落到别的 App 的窗口上（covered 判定正确地不命中）。
        decoy.setFrameOrigin(NSPoint(x: 60, y: 60))
        // 协作式激活经常无视第一次 activate，多试几轮；拿不到前台后面 panel.makeKey 也会失败
        for _ in 0..<30 where !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        settle(0.3)
        check("活垫片已让状态机跑起来（ticks > 0）", HandCursorRegistry.shared.ticks > 0)

        // 正向对照：状态机链路必须是活的——指着活垫片真的变手型、移开真的回箭头。
        // 否则后面「边缘窗口不进手型」的断言可能只是「状态机没跑」的假象。
        warp(NSPoint(x: 120, y: 100)); settle(0.4)
        check("对照：指着活垫片会变手型（判定链路活着）", HandCursorRegistry.shared.isHand)
        if !HandCursorRegistry.shared.isHand {
            print("  诊断 对照帧：\(HandCursorRegistry.shared.lastTickDebug)")
            print("  " + HandCursorRegistry.shared.debugDescribe(NSEvent.mouseLocation))
            print("  诊断 decoy frame=\(decoy.frame) pad=\(decoyPadVisible(decoy))")
        }
        let bleed = EdgeDeckGeom.bleed(for: .fan)
        let colX = panel.frame.minX + EdgeDeckGeom.overshoot + bleed
        let tab0 = NSPoint(x: colX + EdgeDeckGeom.tabWidth * 0.42,
                           y: panel.frame.minY + panel.frame.height - bleed - EdgeDeckGeom.tabHeight * 0.62)
        warp(tab0); settle(0.6)
        check("对照：从活垫片移走后回了箭头", !HandCursorRegistry.shared.isHand)
        check("指着纸签：状态机不进手型", !HandCursorRegistry.shared.isHand)
        check("指着纸签：真实光标不是手型", NSCursor.current !== NSCursor.pointingHand)

        guard let first = store.edgeNotes.first else { check("有可抽的便签", false); exit(1) }
        let hand0 = HandCursorRegistry.shared.handSwitches
        let arrow0 = HandCursorRegistry.shared.arrowSwitches
        let reassert0 = HandCursorRegistry.shared.reasserts

        // 真实按下的那一下（CGEvent 动物理光标 + 本地事件走监视器）
        cg(.leftMouseDown, tab0); postLocal(.leftMouseDown, tab0); pump()
        settle(0.02)
        ctl.pull(first.id)

        // 点击 + 窗口动画 + 视图树重建全程，手型一次都不该出现
        var handFrames = 0
        let frames = 40
        for i in 0..<frames {
            let jitter = CGFloat((i % 5) - 2) * 1.2       // ±2.4pt 手抖
            cg(.mouseMoved, tab0, jitter)
            postLocal(.mouseMoved, NSPoint(x: tab0.x + jitter, y: tab0.y))
            pump()
            settle(0.012)
            if HandCursorRegistry.shared.isHand { handFrames += 1 }
            if NSCursor.current === NSCursor.pointingHand { handFrames += 1 }
            if i == frames / 2 {
                cg(.leftMouseUp, tab0); postLocal(.leftMouseUp, tab0); pump()
            }
        }
        let handDelta = HandCursorRegistry.shared.handSwitches - hand0
        let arrowDelta = HandCursorRegistry.shared.arrowSwitches - arrow0
        let reassertDelta = HandCursorRegistry.shared.reasserts - reassert0
        print("  诊断 \(frames) 帧：出现手型 \(handFrames) 帧次，"
              + "handSwitches +\(handDelta)，arrowSwitches +\(arrowDelta)，"
              + "手型重申 +\(reassertDelta)，NSApp.isActive=\(NSApp.isActive)")
        check("点击抽出全程状态机与真实光标都不进手型（实得 \(handFrames) 帧次）", handFrames == 0)
        check("全程没有切过手型（实得 \(handDelta) 次）", handDelta == 0)
        check("全程没有切过箭头（实得 \(arrowDelta) 次）", arrowDelta == 0)
        // reassert 只在 isHand 为真时才计数；它涨了就说明状态机曾经以为是手型
        check("全程没有重申过手型（实得 \(reassertDelta) 次）", reassertDelta == 0)
        check("抽出态建立（面板成为 key）", panel.isKeyWindow)

        // 收尾：收起 + 移开，状态机仍不该沾手型
        ctl.collapse()
        settle(0.4)
        warp(NSPoint(x: 200, y: 200))
        settle(0.5)
        check("移开后仍不是手型", !HandCursorRegistry.shared.isHand)

        decoy.orderOut(nil)
        warp(originalPoint)
        print(failures == 0 ? "clickfliptest 全部通过" : "clickfliptest \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}

// 手型光标：SwiftUI 按钮默认是箭头，统一给可点击区域注册 pointingHand cursor rect。
// 断言覆盖「注册生效 / 点击穿透 / 输入框仍是 I 形 / 各窗口都有覆盖」。
if args.contains("--hovertest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        ScrollChrome.startWatching()

        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "✓ \(name)" : "✗ \(name)")
            if !ok { failures += 1 }
        }
        func collect(_ v: NSView?, into out: inout [HandCursorView]) {
            guard let v else { return }
            if let h = v as? HandCursorView { out.append(h) }
            for s in v.subviews { collect(s, into: &out) }
        }
        func screenHeight() -> CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
        /// CG 全局坐标原点在主屏左上，NSEvent / NSWindow 在左下，必须翻转 Y
        func warp(_ p: NSPoint) {
            CGWarpMouseCursorPosition(CGPoint(x: p.x, y: screenHeight() - p.y))
        }
        func handNow() -> Bool { NSCursor.current === NSCursor.pointingHand }

        let originalPointer = NSEvent.mouseLocation

        let store = AppStore.demo()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                           styleMask: [.titled, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.contentView = NSHostingView(rootView:
            WallView().environmentObject(store).frame(width: 1100, height: 760))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        var steps: [(String, NSPoint, Bool)] = []
        var index = 0

        func finish() {
            warp(originalPointer)
            print(failures == 0 ? "hovertest 全部通过" : "hovertest \(failures) 项失败")
            exit(failures == 0 ? 0 : 1)
        }

        func runNext() {
            guard index < steps.count else { finish(); return }
            let (name, p, expectHand) = steps[index]
            index += 1
            warp(p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let isHand = handNow()
                check("\(name) → \(expectHand ? "手型" : "非手型")", isHand == expectHand)
                if isHand != expectHand {
                    print("  诊断 该帧：\(HandCursorRegistry.shared.lastTickDebug)")
                    print("  " + HandCursorRegistry.shared.debugDescribe(NSEvent.mouseLocation))
                }
                runNext()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            check("测试进程为前台 App", NSApp.isActive)
            check("主窗口拿到 key", win.isKeyWindow)

            var hands: [HandCursorView] = []
            collect(win.contentView, into: &hands)
            check("主界面可点击区域 ≥ 15（实际 \(hands.count)）", hands.count >= 15)
            check("垫片不吞鼠标事件",
                  !hands.isEmpty && hands.allSatisfy {
                      $0.hitTest(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY)) == nil
                  })

            struct Region { let name: String; let rect: NSRect }
            var regions: [Region] = []
            for (i, h) in hands.enumerated() {
                let r = HandCursorRegistry.windowRect(of: h)
                guard r.width > 8, r.height > 8 else { continue }
                let sr = win.convertToScreen(r)
                regions.append(Region(name: "区域#\(i) \(Int(sr.width))×\(Int(sr.height))", rect: sr))
            }
            check("有合理尺寸的可点击区域 ≥ 10（实际 \(regions.count)）", regions.count >= 10)
            for (i, r) in regions.prefix(5).enumerated() {
                print("  诊断 区域#\(i) =\(r.name) \(r.rect)")
            }

            let picks = regions
                .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
                .prefix(5)
            for r in picks {
                steps.append(("悬停 \(r.name)", NSPoint(x: r.rect.midX, y: r.rect.midY), true))
            }

            if let tv = findView(NSTextView.self, in: win.contentView) {
                let sr = win.convertToScreen(tv.convert(tv.bounds, to: nil))
                steps.append(("悬停输入框保持 I 形", NSPoint(x: sr.midX, y: sr.midY), false))
            } else {
                check("找到主界面输入框", false)
            }

            // 找一个不在任何可点击区域内的空白点
            let windowRect = win.convertToScreen(win.contentView!.bounds)
            var blank: NSPoint?
            var y = windowRect.minY + 6
            while y < windowRect.maxY, blank == nil {
                var x = windowRect.minX + 6
                while x < windowRect.maxX {
                    let p = NSPoint(x: x, y: y)
                    if !regions.contains(where: { $0.rect.contains(p) }) { blank = p; break }
                    x += 12
                }
                y += 6
            }
            if let blank {
                steps.append(("悬停窗口空白处", blank, false))
            } else {
                check("找到窗口空白处", false)
            }

            runNext()
        }

        NSApp.run()
    }
}

// 便签墙列数：默认 3 列（两列时卡片被拉到 ~450pt，太宽），
// 窄窗口逐级降级、拉到超宽才允许第 4 列
if args.contains("--gridtest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "✓ \(name)" : "✗ \(name)")
            if !ok { failures += 1 }
        }

        // ① 各档窗口宽度（内容区 = 窗口宽 - 左右各 26pt 内边距）
        let cases: [(String, CGFloat, Int)] = [
            ("极窄 400", 400 - 52, 1),
            ("最小窗口 720", 720 - 52, 2),
            ("当前窗口 960", 960 - 52, 3),
            ("默认窗口 1180", 1180 - 52, 3),
            ("宽窗口 1300", 1300 - 52, 3),
            ("超宽 1400", 1400 - 52, 4),
        ]
        for (name, w, want) in cases {
            let got = MasonryLayout.columnCount(width: w)
            check("\(name)pt → \(want) 列（实得 \(got)）", got == want)
        }
        check("宽度 .infinity 不崩溃且兜底 1 列",
              MasonryLayout.columnCount(width: .infinity) == 1)
        check("宽度 0 兜底 1 列", MasonryLayout.columnCount(width: 0) == 1)

        // ② 真正走一遍 SwiftUI Layout 的 placeSubviews，验证落点而不只是数学函数
        let recorder = LayoutFrameRecorder()
        let probeWin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                                styleMask: [.titled], backing: .buffered, defer: false)
        probeWin.makeKeyAndOrderFront(nil)
        func layout(width w: CGFloat) -> [CGRect] {
            recorder.frames = []
            var probe = MasonryLayout()
            probe.onLayout = { rects in recorder.frames = rects }
            let host = NSHostingView(rootView:
                probe {
                    ForEach(0..<7, id: \.self) { i in
                        Color.clear.frame(height: 100 + CGFloat(i % 3) * 24)
                    }
                }
                .frame(width: w, height: 700))
            host.frame = NSRect(x: 0, y: 0, width: w, height: 700)
            probeWin.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            return recorder.frames
        }
        func verify(_ name: String, _ w: CGFloat, _ want: Int) {
            let frames = layout(width: w)
            let xs = Array(Set(frames.map { $0.minX.rounded() })).sorted()
            let cw = (w - CGFloat(want - 1) * 16) / CGFloat(want)
            check("\(name)：7 张卡片全部落位", frames.count == 7)
            check("\(name)：实际 \(xs.count) 列（期望 \(want)）", xs.count == want)
            check("\(name)：列宽均为 \(Int(cw))pt",
                  !frames.isEmpty && frames.allSatisfy { abs($0.width - cw) < 0.6 })
            if xs.count > 1 {
                check("\(name)：列间距 = 16pt",
                      abs((xs[1] - xs[0]) - (cw + 16)) < 0.6)
            }
            var noOverlap = true
            for x in xs {
                let col = frames.filter { abs($0.minX.rounded() - x) < 0.6 }
                    .sorted { $0.minY < $1.minY }
                for i in 1..<col.count where col[i].minY < col[i - 1].maxY - 0.6 {
                    noOverlap = false
                }
            }
            check("\(name)：同列卡片不重叠", noOverlap)
        }
        verify("当前窗口 960", 960 - 52, 3)
        verify("默认窗口 1180", 1180 - 52, 3)
        verify("最小窗口 720", 720 - 52, 2)
        verify("超宽 1400", 1400 - 52, 4)
        probeWin.close()

        // ③ 真实主窗口截图，供人工 review 卡片尺寸与整体密度
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: "shots", isDirectory: true), withIntermediateDirectories: true)
        let store = AppStore.demo()
        // 用户数据里有「横幅文字图」这种便签：列变窄后最容易被 fill 裁掉两端，
        // 造一张带左右标记的图专门核对
        let banner = NSImage(size: NSSize(width: 600, height: 220))
        banner.lockFocus()
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 600, height: 220).fill()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSRect(x: 30, y: 92, width: 88, height: 88).fill()
        NSRect(x: 150, y: 88, width: 400, height: 76).fill()
        NSRect(x: 566, y: 100, width: 22, height: 60).fill()   // 右端标记
        banner.unlockFocus()
        let bannerImage = ImageStore.save(banner)
        if let bannerImage {
            check("图片便签加入演示数据",
                  store.add(text: "图片宽度回归", paper: .cream, tag: "资料",
                            image: bannerImage) != nil)
        }
        func wallShot(_ width: CGFloat, _ name: String, dark: Bool = false) {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            if dark { w.appearance = NSAppearance(named: .darkAqua) }
            w.contentView = NSHostingView(rootView:
                WallView().environmentObject(store)
                    .frame(width: width, height: 820))
            w.center()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-l", "\(w.windowNumber)", "shots/\(name).png"]
            try? p.run()
            p.waitUntilExit()
            w.close()
        }
        wallShot(960, "grid-960")
        wallShot(1180, "grid-1180")
        wallShot(960, "grid-960-dark", dark: true)
        if let bannerImage {
            ThumbCache.shared.evict(bannerImage)
            ImageStore.delete(bannerImage)
        }
        check("三档真实主窗口截图已生成",
              ["grid-960", "grid-1180", "grid-960-dark"].allSatisfy {
                  FileManager.default.fileExists(atPath: "shots/\($0).png")
              })

        print(failures == 0 ? "gridtest 全部通过" : "gridtest \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}

if args.contains("--walltest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        ScrollChrome.startWatching()
        let store = AppStore.demo()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "便签墙"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        let dark = args.contains("dark")
        if dark { win.appearance = NSAppearance(named: .darkAqua) }
        win.contentView = NSHostingView(rootView:
            WallView().environmentObject(store)
                .frame(width: 1100, height: 760))
        // 命令行二进制没有 App 激活流程，窗口永远拿不到 key 身份；
        // 这里故意不挂 AppContext.wallWindow：两边都是 nil 时 ⌘↩ 的窗口守卫才放行，
        // 这样仍能端到端验证「键入 → binding → store → 清空」这条链路。
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))

        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: "shots", isDirectory: true), withIntermediateDirectories: true)
        func shot(_ name: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-l", "\(win.windowNumber)", "shots/\(name).png"]
            try? p.run()
            p.waitUntilExit()
        }
        shot(dark ? "wall-placeholder-dark" : "wall-placeholder")

        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "✓ \(name)" : "✗ \(name)")
            if !ok { failures += 1 }
        }
        let tv = findView(NSTextView.self, in: win.contentView)
        let holder = findView(EditorPlaceholderView.self, in: win.contentView)
        check("真实主界面挂载了自托管文本框", tv != nil)
        check("真实主界面挂载了原生占位", holder != nil)
        if let tv, let holder {
            check("真实主界面空输入：占位可见", !holder.hasContent)
            tv.setMarkedText("ni'hao", selectedRange: NSRange(location: 6, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            check("真实主界面组合输入：拼音没被删", tv.string == "ni'hao")
            check("真实主界面组合输入：占位已收起", holder.hasContent)
            shot(dark ? "wall-ime-dark" : "wall-ime")

            // 端到端：清空组合文本 → 真的键入 → ⌘↩ → 便签落盘 → 草稿清空
            tv.string = ""
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let before = store.notes.filter { $0.deletedAt == nil }.count
            tv.insertText("输入法回归测试", replacementRange: NSRange(location: 0, length: 0))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                         modifierFlags: [.command],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: win.windowNumber, context: nil,
                                         characters: "\r", charactersIgnoringModifiers: "\r",
                                         isARepeat: false, keyCode: 36) {
                // 直接走 sendEvent：postEvent 只是排队，RunLoop.main.run 不保证抽走它
                NSApp.sendEvent(ev)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let after = store.notes.filter { $0.deletedAt == nil }.count
            check("★ ⌘↩ 把键入内容真的存成了一张便签", after == before + 1)
            check("★ 保存后输入框被清空", tv.string.isEmpty)
            check("★ 保存后占位重新出现", !holder.hasContent)
        }
        print(failures == 0 ? "walltest 全部通过" : "walltest \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}

// 原生占位与 SwiftUI Text 的像素对齐 / 可见性：
// 没有 TextEditor 时占位恒定可见，把它（红）和 SwiftUI Text（半透明蓝）
// 放在同一位置叠一起，对齐就是紫色，错位就会看到红色毛边。
if args.contains("--placeholdertest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 130),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView:
            ZStack(alignment: .topLeading) {
                EditorPlaceholder(text: "记下点什么…", color: .red, fontSize: 16)
                    .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60,
                           alignment: .topLeading)
                Text("记下点什么…")
                    .font(.ui(16))
                    .foregroundStyle(Color.blue.opacity(0.55))
                    .offset(x: EditorMetrics.textOrigin.width, y: EditorMetrics.textOrigin.height)
            }
            .padding(20)
            .frame(width: 460, height: 130, alignment: .topLeading)
            .background(Color.white)
        )
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))

        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: "shots", isDirectory: true), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-l", "\(win.windowNumber)", "shots/placeholder-align.png"]
        try? p.run()
        p.waitUntilExit()
        print("placeholder-align.png written; origin=\(EditorMetrics.textOrigin)")
        exit(0)
    }
}

// 图片链路：剪贴板 → 落盘 → 纯图片便签 → 卡片/详情页读回 → 删除时清理
if args.contains("--imagetest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "✓ \(name)" : "✗ \(name)")
            if !ok { failures += 1 }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notewall-imagetest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Paths.overrideRoot = root
        func cleanup() {
            Paths.overrideRoot = nil
            try? FileManager.default.removeItem(at: root)
        }

        // 造一张 320×200 的纯色图
        let img = NSImage(size: NSSize(width: 320, height: 200))
        img.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 200).fill()
        NSColor.white.setFill()
        NSRect(x: 40, y: 40, width: 120, height: 120).fill()
        img.unlockFocus()

        // ① 剪贴板识别
        let pb = NSPasteboard(name: NSPasteboard.Name("notewall-imagetest"))
        pb.clearContents()
        _ = pb.writeObjects([img])
        check("剪贴板里放图 → 能识别", ImageStore.pasteboardHasImage(pb))
        check("剪贴板里放图 → 能取出", ImageStore.imageFromPasteboard(pb) != nil)

        pb.clearContents()
        pb.setString("只是一段文字", forType: .string)
        check("剪贴板里只有文字 → 不误判为图片", !ImageStore.pasteboardHasImage(pb))

        // 访达里「复制一个 png 文件」：剪贴板里是 fileURL，不是位图。
        // 这是用户最容易走的一条路，漏判就会把路径当文本插进输入框。
        let tmpPNG = root.appendingPathComponent("clip-source.png")
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: tmpPNG)
        }
        pb.clearContents()
        _ = pb.writeObjects([tmpPNG as NSURL])
        check("复制图片文件 → 能识别为图片", ImageStore.pasteboardHasImage(pb))
        check("复制图片文件 → 能取出图片", ImageStore.imageFromPasteboard(pb) != nil)

        // 复制一个非图片文件，不能被误判
        let tmpTXT = root.appendingPathComponent("note.txt")
        try? "hello".data(using: .utf8)?.write(to: tmpTXT)
        pb.clearContents()
        _ = pb.writeObjects([tmpTXT as NSURL])
        check("复制普通文件 → 不误判为图片", !ImageStore.pasteboardHasImage(pb))

        // ⌘V 的接管判断（handler 用的就是这一个函数）
        check("⌘V 接管：普通文件 → 不接管", ComposerPaste.image(pb) == nil)   // 此刻剪贴板是 txt
        pb.clearContents()
        _ = pb.writeObjects([tmpPNG as NSURL])
        check("⌘V 接管：图片文件 → 接管", ComposerPaste.image(pb) != nil)
        pb.clearContents()
        _ = pb.writeObjects([img])
        check("⌘V 接管：位图 → 接管", ComposerPaste.image(pb) != nil)
        pb.clearContents()
        pb.setString("只是文字", forType: .string)
        check("⌘V 接管：纯文本 → 不接管（让 TextEditor 正常粘字）", ComposerPaste.image(pb) == nil)

        // ② 落盘
        guard let saved = ImageStore.save(img) else {
            check("图片落盘", false)
            cleanup(); exit(1)
        }
        check("主图文件已写入",
              FileManager.default.fileExists(atPath: ImageStore.url(saved.fileName, thumb: false).path))
        check("缩略图已写入",
              FileManager.default.fileExists(atPath: ImageStore.url(saved.thumbName, thumb: true).path))
        check("记住像素尺寸", saved.pixelWidth > 0 && saved.pixelHeight > 0)

        // ③ 纯图片便签（用户最常干的事：只粘一张图不写字）
        let store = AppStore.demo()
        let before = store.notes.count
        let note = store.add(text: "", paper: .cream, tag: "灵感", image: saved)
        check("空文字 + 图片也能建便签", note != nil && store.notes.count == before + 1)
        check("便签带上了图片引用", note?.image?.fileName == saved.fileName)
        if let ni = note?.image {
            check("卡片缩略图能读回", ThumbCache.shared.image(ni) != nil)
            check("详情页大图能读回", ThumbCache.shared.full(ni) != nil)
        }

        // ④ 彻底删除要连图片文件一起清
        if let id = note?.id {
            store.delete(id)
            store.deleteForever(id)
            check("彻底删除后主图文件已清理",
                  !FileManager.default.fileExists(atPath: ImageStore.url(saved.fileName, thumb: false).path))
        }

        cleanup()
        print(failures == 0 ? "全部通过" : "\(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}

// 占位文案与光标对齐：把「光标顶部 / 占位文字顶部」量出来，别靠肉眼调 padding
if args.contains("--cursortest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)

        // 面板不是 key 时画不出插入点，所以改用「文字对文字」：
        // TextEditor 里的字染红、占位染蓝，同内容叠在一起。对齐就重合，
        // 错位就会看到红色和蓝色分成上下两层，量一下差值就是 padding 该调多少。
        final class TBuf: ObservableObject { @Published var s = "记下点什么…" }
        let buf = TBuf()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "cursor"
        win.contentView = NSHostingView(rootView:
            ZStack(alignment: .topLeading) {
                Text("记下点什么…")
                    .font(.ui(16))
                    .foregroundStyle(Color.blue)
                    .offset(x: EditorMetrics.textOrigin.width, y: EditorMetrics.textOrigin.height)
                PlainTextEditor(text: buf.bind(\.s), fontSize: 16, ink: .red)
                    .frame(height: 76)
            }
            .padding(16)
            .frame(width: 420, height: 120, alignment: .topLeading)
            .background(Color.white)
        )
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: "shots", isDirectory: true), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-l", "\(win.windowNumber)", "shots/cursor.png"]
        try? p.run()
        p.waitUntilExit()
        print("cursortest origin=\(EditorMetrics.textOrigin)")
        exit(0)
    }
}

// 自检：锁定 / 加密（全套在临时目录里跑，绝不碰真实存档）
if args.contains("--locktest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "✓ \(name)" : "✗ \(name)")
            if !ok { failures += 1 }
        }

        // 所有落盘都改到临时目录：密钥、存档、图片
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notewall-locktest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Paths.overrideRoot = root
        func cleanup() {
            Paths.overrideRoot = nil
            try? FileManager.default.removeItem(at: root)
        }

        // MARK: 密钥
        let v1 = Vault(persistent: true)
        check("主密钥已生成（指纹 \(v1.keyID)）", v1.keyID.count == 12)

        let attrs = try? FileManager.default.attributesOfItem(atPath: Vault.keyURL.path)
        let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check("密钥文件权限 0600", mode & 0o777 == 0o600)

        let excluded = (try? Vault.keyURL.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
            .isExcludedFromBackup ?? false
        check("密钥文件排除出备份", excluded)

        let v2 = Vault(persistent: true)
        check("重新启动读到同一把密钥", v2.keyID == v1.keyID)

        // MARK: 密文往返
        let secret = "客户报价底线 18 万"
        let sealed = try! v1.seal(LockedPayload(text: secret), aad: "note-a")
        check("密文里不含明文", !sealed.contains("18 万") && !sealed.contains(secret))
        let plain = try! v1.open(sealed, as: LockedPayload.self, aad: "note-a")
        check("解密还原原文", plain.text == secret)

        var tampered = Array(sealed)
        tampered[tampered.count - 2] = tampered[tampered.count - 2] == "A" ? "B" : "A"
        check("密文被改一个字符就解不开", (try? v1.open(String(tampered), as: LockedPayload.self, aad: "note-a")) == nil)
        check("换一张便签的 id 解不开（AAD 绑定）",
              (try? v1.open(sealed, as: LockedPayload.self, aad: "note-b")) == nil)

        // MARK: 锁 / 解锁
        let store = AppStore()
        store.authenticator = TestAuthenticator(allow: false)
        let note = store.add(text: secret, paper: .blue, tag: "资料")!
        check("普通便签在磁盘上是明文", (try? String(contentsOf: Paths.storeFile, encoding: .utf8))?.contains(secret) == true)

        let editBefore = store.notes.first { $0.id == note.id }!.updatedAt
        check("锁定成功", store.lock(note.id))
        var n = store.notes.first { $0.id == note.id }!
        check("锁定后正文清空", n.text.isEmpty)
        check("锁定后留下密文", n.lockPayload != nil)
        check("锁定后标记 lockedAt", n.lockedAt != nil)
        check("锁定不算编辑（最近编辑时间不动）", n.updatedAt == editBefore)

        let disk = (try? String(contentsOf: Paths.storeFile, encoding: .utf8)) ?? ""
        check("存档里没有明文", !disk.contains(secret))
        check("存档里有 lockPayload", disk.contains("lockPayload"))
        let keyB64 = (try? Data(contentsOf: Vault.keyURL))?.base64EncodedString() ?? ""
        check("存档里没有主密钥", !keyB64.isEmpty && !disk.contains(keyB64))
        check("锁定便签不进入关键词搜索", { store.searchText = "18 万"; return store.visibleNotes.isEmpty }())

        var denied: Bool? = nil
        store.unlock(note.id) { denied = $0 }
        check("拒绝验证时解锁失败", denied == false)
        check("拒绝验证后仍是密文", store.notes.first { $0.id == note.id }?.isLocked == true)

        store.authenticator = TestAuthenticator(allow: true)
        var opened: Bool? = nil
        store.unlock(note.id) { opened = $0 }
        n = store.notes.first { $0.id == note.id }!
        check("通过验证后解锁成功", opened == true)
        check("解锁后原文还原", n.text == secret && !n.isLocked)
        check("解锁后清掉密文", n.lockPayload == nil)
        check("解锁后重新进入搜索", { store.searchText = "18 万"; return store.visibleNotes.count == 1 }())

        store.relockSessionNotes()
        n = store.notes.first { $0.id == note.id }!
        check("退出时自动重新锁上", n.isLocked && n.text.isEmpty)
        let disk2 = (try? String(contentsOf: Paths.storeFile, encoding: .utf8)) ?? ""
        check("重新锁定后存档又只剩密文", !disk2.contains(secret))

        // MARK: 图片
        func makeImage(_ w: Int, _ h: Int) -> NSImage {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.systemPink.setFill()
            NSRect(x: 0, y: 0, width: w, height: h).fill()
            NSGraphicsContext.restoreGraphicsState()
            let img = NSImage(size: NSSize(width: w, height: h))
            img.addRepresentation(rep)
            return img
        }

        store.searchText = ""
        let shot = ImageStore.save(makeImage(320, 200))!
        let photo = store.add(text: "", paper: .mint, tag: "资料", image: shot)!
        check("带图便签锁定成功", store.lock(photo.id))
        check("图片被标记为密文", store.notes.first { $0.id == photo.id }?.image?.isEncrypted == true)
        check("图片文件已无法当作图片打开",
              NSImage(contentsOf: ImageStore.url(shot.fileName, thumb: false)) == nil)
        check("缩略图也一起加密",
              NSImage(contentsOf: ImageStore.url(shot.thumbName, thumb: true)) == nil)

        var photoOpen: Bool? = nil
        store.unlock(photo.id) { photoOpen = $0 }
        let restored = NSImage(contentsOf: ImageStore.url(shot.fileName, thumb: false))
        check("解锁后图片恢复可读", photoOpen == true && restored != nil)
        check("图片像素尺寸不变", restored.map { Int($0.size.width) == 320 } == true)

        // MARK: 旧存档迁移（以前只有遮罩，正文明文）
        let legacy = Note(wallID: store.walls[0].id, text: "旧版假锁的明文", paper: .pink, tag: "资料", isLocked: true)
        let archive = Archive(notes: [legacy], walls: store.walls, didSeed: true, keyID: v1.keyID)
        try? JSONEncoder.archive.encode(archive).write(to: Paths.storeFile, options: .atomic)
        check("迁移前存档里是明文", ((try? String(contentsOf: Paths.storeFile, encoding: .utf8)) ?? "").contains("旧版假锁的明文"))

        let migrated = AppStore()
        migrated.authenticator = TestAuthenticator(allow: true)
        let ln = migrated.notes.first { $0.id == legacy.id }!
        check("旧「假锁」被补成真加密", ln.isLocked && ln.text.isEmpty && ln.lockPayload != nil)
        check("迁移后存档里没有明文", !((try? String(contentsOf: Paths.storeFile, encoding: .utf8)) ?? "").contains("旧版假锁的明文"))
        var legacyOpen: Bool? = nil
        migrated.unlock(legacy.id) { legacyOpen = $0 }
        check("迁移后的便签仍能解锁", legacyOpen == true && migrated.notes.first { $0.id == legacy.id }?.text == "旧版假锁的明文")

        // MARK: 密钥换了要报警，而不是静默打不开
        let stale = Archive(notes: [legacy], walls: store.walls, didSeed: true, keyID: "000000000000")
        try? JSONEncoder.archive.encode(stale).write(to: Paths.storeFile, options: .atomic)
        check("密钥指纹不一致时报警", AppStore().keyStale)

        print("解锁凭证：\(BiometricGate.availability.title)")
        print(failures == 0 ? "全部通过" : "\(failures) 项失败")
        cleanup()
        exit(failures == 0 ? 0 : 1)
    }
}

// 自检：纯逻辑（清单解析、时间显示、存档往返）
if args.contains("--selftest") {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
        print(ok ? "✓ \(name)" : "✗ \(name)")
        if !ok { failures += 1 }
    }

    let src = "周五前要处理的三件事\n- [x] 给设计稿加标注\n- [ ] 改完原型里的三段文案"
    let items = Checklist.parse(src)
    check("清单识别出 2 项", items.count == 2)
    check("第一项已完成", items.first?.done == true)
    check("第二项未完成", items.last?.done == false)
    check("勾选文本正确", items.first?.text == "给设计稿加标注")

    let toggled = Checklist.toggle(src, itemID: 1)
    check("勾选后写回正文", toggled.contains("- [x] 改完原型里的三段文案"))
    let untoggled = Checklist.toggle(toggled, itemID: 0)
    check("取消勾选写回", untoggled.contains("- [ ] 给设计稿加标注"))

    check("输入 - 自动补成勾选框", Checklist.autoComplete("- ") == "- [ ] ")
    check("普通文本不被改写", Checklist.autoComplete("abc") == "abc")

    let now = Date()
    check("今天显示时分", TimeLabel.card(now, now: now).hasPrefix("今天"))
    check("3 天前显示天数", TimeLabel.card(now.addingTimeInterval(-3 * 86400), now: now) == "3 天前")

    let n = Note(wallID: UUID(), text: src, paper: .mint, tag: "待办")
    let enc = try! JSONEncoder.archive.encode(n)
    let dec = try! JSONDecoder.archive.decode(Note.self, from: enc)
    check("存档往返字段一致", dec.id == n.id && dec.text == n.text && dec.paper == n.paper)
    check("创建时间保真", abs(dec.createdAt.timeIntervalSince(n.createdAt)) < 1)

    // 主题：两套色值必须真的不同，层次差要肉眼可见，正文对比度要够。
    // 这些是「深色不能一团黑」的量化版本，靠肉眼每次看截图太不可靠。
    func srgb(_ c: Color, dark: Bool) -> (r: Double, g: Double, b: Double) {
        let app = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out = (0.0, 0.0, 0.0)
        app.performAsCurrentDrawingAppearance {
            let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
            out = (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        }
        return out
    }
    func luma(_ c: (r: Double, g: Double, b: Double)) -> Double {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }
    // 对比度必须按 WCAG 的线性化相对亮度算，直接拿 gamma 空间的通道值算会低估
    func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    func relLuma(_ c: (r: Double, g: Double, b: Double)) -> Double {
        0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    func contrast(_ a: (r: Double, g: Double, b: Double),
                  _ b: (r: Double, g: Double, b: Double)) -> Double {
        let la = relLuma(a), lb = relLuma(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    let bgD = srgb(T.bg, dark: true), bgL = srgb(T.bg, dark: false)
    let panelD = srgb(T.panel, dark: true), panelL = srgb(T.panel, dark: false)
    let textD = srgb(T.text, dark: true), textL = srgb(T.text, dark: false)

    check("浅色与深色画布不是同一个色", abs(luma(bgL) - luma(bgD)) > 0.5)
    check("深色画布不是纯黑（L > 0.10）", luma(bgD) > 0.10)
    check("深色顶栏比画布亮（至少 0.03）", luma(panelD) - luma(bgD) >= 0.03)
    check("浅色顶栏比画布暗（米灰顶栏 / 白画布）", luma(bgL) - luma(panelL) > 0.02)
    check("深色正文对比度 ≥ 7", contrast(textD, bgD) >= 7)
    check("浅色正文对比度 ≥ 7", contrast(textL, bgL) >= 7)
    check("深色正文比画布亮", luma(textD) > luma(bgD))
    check("浅色正文比画布暗", luma(textL) < luma(bgL))
    check("深色次要文字可见（对比 ≥ 3）", contrast(srgb(T.textDim, dark: true), bgD) >= 3)
    check("浅色次要文字可见（对比 ≥ 3）", contrast(srgb(T.textDim, dark: false), bgL) >= 3)

    // 外观必须能存住，且不能把老存档读坏
    var themeArchive = Archive()
    themeArchive.appearance = .light
    if let data = try? JSONEncoder.archive.encode(themeArchive),
       let back = try? JSONDecoder.archive.decode(Archive.self, from: data) {
        check("外观写进存档", back.appearance == .light)
    } else {
        check("外观写进存档", false)
    }
    let legacyJSON = """
    {"version":2,"notes":[],"walls":[],"sortMode":"newest","contentFilter":"all",\
    "didSeed":true,"lockEnabled":false,"checkCountVisible":true}
    """.data(using: .utf8)!
    check("没有 appearance 字段的老存档能解码",
          (try? JSONDecoder.archive.decode(Archive.self, from: legacyJSON)) != nil)
    check("老存档默认跟随系统",
          (try? JSONDecoder.archive.decode(Archive.self, from: legacyJSON))?.appearance == nil)

    // 快捷键自定义：显示格式、硬性规则、冲突引导、存档往返
    check("显示：⌥ Space", HotkeyCombo.altSpace.display == "⌥ Space")
    // Apple 的修饰键顺序是 ⌃ ⌥ ⇧ ⌘（⇧ 在 ⌘ 前，系统菜单里也是 ⇧⌘N 这样排），
    // 旧版硬编码的「⌘ ⇧ Space」其实不合规范
    check("显示：⇧ ⌘ Space", HotkeyCombo.cmdShiftSpace.display == "⇧ ⌘ Space")
    check("显示：修饰键顺序 ⌃ ⌥ ⇧ ⌘",
          HotkeyCombo(keyCode: UInt32(kVK_ANSI_K),
                      carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey)).display
              == "⌃ ⌥ ⇧ ⌘ K")
    check("显示：功能键", HotkeyCombo(keyCode: UInt32(kVK_F5), carbonModifiers: 0).display == "F5")

    check("规则：裸字母被拦截",
          HotkeyRules.problem(HotkeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: 0)) != nil)
    check("规则：只有 ⇧ 也被拦截",
          HotkeyRules.problem(HotkeyCombo(keyCode: UInt32(kVK_ANSI_K),
                                          carbonModifiers: UInt32(shiftKey))) != nil)
    check("规则：⌘ + 字母可用",
          HotkeyRules.problem(HotkeyCombo(keyCode: UInt32(kVK_ANSI_K),
                                          carbonModifiers: UInt32(cmdKey))) == nil)
    check("规则：裸功能键可用",
          HotkeyRules.problem(HotkeyCombo(keyCode: UInt32(kVK_F5), carbonModifiers: 0)) == nil)

    check("引导：⌥ Space 提示启动器占用",
          HotkeyRules.advisory(HotkeyCombo.altSpace)?.contains("Raycast") == true)
    check("引导：⌘ Space 提示聚焦搜索",
          HotkeyRules.advisory(HotkeyCombo(keyCode: UInt32(kVK_Space),
                                           carbonModifiers: UInt32(cmdKey)))?.contains("Spotlight") == true)
    check("引导：⌘ ⇧ 4 提示截屏",
          HotkeyRules.advisory(HotkeyCombo(keyCode: UInt32(kVK_ANSI_4),
                                           carbonModifiers: UInt32(cmdKey | shiftKey)))?.contains("截屏") == true)
    check("引导：⌘ + 单字母提示会抢 App 快捷键",
          HotkeyRules.advisory(HotkeyCombo(keyCode: UInt32(kVK_ANSI_K),
                                           carbonModifiers: UInt32(cmdKey)))?.contains("⌘C") == true)
    check("引导：普通组合不打扰",
          HotkeyRules.advisory(HotkeyCombo(keyCode: UInt32(kVK_ANSI_K),
                                           carbonModifiers: UInt32(cmdKey | optionKey))) == nil)

    var clash = HotkeyConfig.standard
    clash.newNote = clash.openWall
    check("同组两个位撞车会被发现", clash.clashes(clash.newNote, in: .newNote))
    check("不同的组合不算撞车",
          !HotkeyConfig.standard.clashes(
            HotkeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(cmdKey)),
            in: .openWall))

    var hotkeyArchive = Archive()
    hotkeyArchive.hotkeys = HotkeyConfig(
        newNote: HotkeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(cmdKey)),
        openWall: HotkeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(cmdKey)))
    if let data = try? JSONEncoder.archive.encode(hotkeyArchive),
       let back = try? JSONDecoder.archive.decode(Archive.self, from: data) {
        check("自定义快捷键写进存档", back.hotkeys == hotkeyArchive.hotkeys)
    } else {
        check("自定义快捷键写进存档", false)
    }
    check("老存档没有快捷键字段也能解码",
          (try? JSONDecoder.archive.decode(Archive.self, from: legacyJSON))?.hotkeys == nil)

    // 搜索语法、锁定便签的索引规则、回收站 30 天清理
    MainActor.assumeIsolated {
        let q1 = SearchQuery.parse("#待办 有图")
        check("搜索语法 #标签", q1.tag == "待办" && q1.keyword.isEmpty)
        check("搜索语法 有图", q1.hasImage)
        let q2 = SearchQuery.parse("墙:工作 报价")
        check("搜索语法 墙:", q2.wallName == "工作" && q2.keyword == "报价")
        check("搜索语法 锁:", SearchQuery.parse("锁:").lockedOnly)

        let home = Wall(name: "我的便签")
        let work = Wall(name: "工作")
        let img = NoteImage(fileName: "a.jpg", thumbName: "a_t.jpg",
                            pixelWidth: 10, pixelHeight: 10, byteSize: 100)
        let plain = Note(wallID: home.id, text: "报价单已经发出", tag: "资料")
        let locked = Note(wallID: work.id, text: "客户报价底线 18 万", tag: "资料", isLocked: true)
        let photo = Note(wallID: work.id, text: "买牛奶", tag: "生活", image: img)
        var oldTrash = Note(wallID: home.id, text: "旧便签", tag: "")
        oldTrash.deletedAt = Date().addingTimeInterval(-40 * 86400)
        var freshTrash = Note(wallID: home.id, text: "刚删的", tag: "")
        freshTrash.deletedAt = Date().addingTimeInterval(-2 * 86400)

        let s = AppStore(inMemory: true)
        s.loadDemo(notes: [plain, locked, photo, oldTrash, freshTrash], walls: [home, work])

        s.searchText = "报价"
        check("锁定便签正文不参与搜索",
              s.visibleNotes.map(\.id) == [plain.id])
        s.searchText = "资料"
        check("命中标签时锁定便签仍出现",
              s.visibleNotes.count == 2 && s.visibleNotes.contains { $0.id == locked.id })
        s.searchText = "#资料 墙:工作"
        check("标签 + 墙名组合过滤",
              s.visibleNotes.map(\.id) == [locked.id])
        s.searchText = "有图"
        check("有图 语法只留带图便签", s.visibleNotes.map(\.id) == [photo.id])

        let removed = s.purgeExpiredTrash()
        check("回收站 30 天自动清理", removed == 1 && !s.notes.contains { $0.id == oldTrash.id })
        check("未到期的回收站便签保留", s.notes.contains { $0.id == freshTrash.id })
    }

    // MARK: 筛选 / 手动排序 / 撤销 / 墙管理（PRD §2.5 §2.6 §2.9）
    MainActor.assumeIsolated {
        let w1 = Wall(name: "甲", sortOrder: 0)
        let w2 = Wall(name: "乙", sortOrder: 10)
        let now2 = Date()
        var nYellow = Note(wallID: w1.id, text: "今天的事项\n- [ ] 还没做完", paper: .yellow,
                           tag: "待办", createdAt: now2)
        nYellow.sortOrder = 200
        var nPink = Note(wallID: w1.id, text: "粉色便签", paper: .pink, tag: "灵感",
                         createdAt: now2.addingTimeInterval(-10 * 86400))
        nPink.sortOrder = 100
        var nBlue = Note(wallID: w2.id, text: "- [x] 全部做完", paper: .blue, tag: "待办",
                         createdAt: now2.addingTimeInterval(-40 * 86400))
        nBlue.sortOrder = 100
        var nLocked = Note(wallID: w1.id, text: "", paper: .purple, tag: "", createdAt: now2)
        nLocked.isLocked = true
        nLocked.sortOrder = 300

        let t = AppStore(inMemory: true)
        t.loadDemo(notes: [nYellow, nPink, nBlue, nLocked], walls: [w1, w2])

        // 颜色
        t.paperFilter.papers = [.yellow]
        check("颜色筛选只留黄纸", t.visibleNotes.map(\.id) == [nYellow.id])
        t.paperFilter.papers = [.yellow, .pink]
        check("颜色筛选可多选", Set(t.visibleNotes.map(\.id)) == Set([nYellow.id, nPink.id]))
        t.clearFilters()
        check("清除筛选后恢复全部", t.visibleNotes.count == 4)

        // 时间
        t.timeFilter = .today
        check("今天：只留今天贴的", Set(t.visibleNotes.map(\.id)) == Set([nYellow.id, nLocked.id]))
        t.timeFilter = .week
        check("最近 7 天不含 10 天前的", !t.visibleNotes.contains { $0.id == nPink.id })
        t.timeFilter = .month
        check("最近 30 天不含 40 天前的", !t.visibleNotes.contains { $0.id == nBlue.id })
        t.timeFilter = .any

        // 状态
        t.statusFilter = .todo
        check("未完成：只留清单没勾完的", t.visibleNotes.map(\.id) == [nYellow.id])
        t.statusFilter = .locked
        check("仅锁定", t.visibleNotes.map(\.id) == [nLocked.id])
        t.statusFilter = .unlocked
        check("隐藏锁定", !t.visibleNotes.contains { $0.id == nLocked.id })
        t.statusFilter = .all

        // 叠加
        t.paperFilter.papers = [.yellow]
        t.statusFilter = .todo
        check("颜色与状态可叠加", t.visibleNotes.map(\.id) == [nYellow.id])
        t.clearFilters()

        // 手动排序
        t.sortMode = .newest
        let beforeOrder = Dictionary(uniqueKeysWithValues:
            t.notes.filter { $0.wallID == w1.id }.map { ($0.id, $0.sortOrder) })
        t.reorder(nYellow.id, droppingOn: .note(nPink.id, after: true))
        check("拖动后自动切到手动排序", t.sortMode == .manual)
        let manualOrder = t.notes.filter { $0.wallID == w1.id }
            .sorted { $0.sortOrder < $1.sortOrder }.map(\.id)
        check("拖到目标后面就排在它后面",
              manualOrder == [nPink.id, nYellow.id, nLocked.id])
        check("顺序号重新编号且留出间隔",
              t.notes.filter { $0.wallID == w1.id }.allSatisfy { $0.sortOrder % 100 == 0 })
        _ = t.undo()
        let undone = Dictionary(uniqueKeysWithValues:
            t.notes.filter { $0.wallID == w1.id }.map { ($0.id, $0.sortOrder) })
        check("撤销顺序调整恢复原有编号", undone == beforeOrder)
        check("撤销也恢复原来的排序模式", t.sortMode == .newest)

        // 落点判断：上半插前、下半插后
        let probeID = UUID()
        check("落在卡片上半 → 插到前面",
              NoteDrop.target(for: probeID, locationY: 10, height: 200) == .note(probeID, after: false))
        check("落在卡片下半 → 插到后面",
              NoteDrop.target(for: probeID, locationY: 190, height: 200) == .note(probeID, after: true))

        // 删除 / 撤销 / 重做
        t.delete(nPink.id)
        check("删除进回收站", t.trashedNotes.contains { $0.id == nPink.id })
        _ = t.undo()
        check("撤销删除：便签回来了", !t.trashedNotes.contains { $0.id == nPink.id })
        _ = t.redo()
        check("重做删除", t.trashedNotes.contains { $0.id == nPink.id })
        _ = t.undo()

        // 换墙 + 撤销
        t.move(nYellow.id, to: w2.id)
        check("移到别的墙", t.notes.first { $0.id == nYellow.id }?.wallID == w2.id)
        check("移墙后落在目标墙末尾",
              (t.notes.first { $0.id == nYellow.id }?.sortOrder ?? 0) >
              (t.notes.first { $0.id == nBlue.id }?.sortOrder ?? 0))
        _ = t.undo()
        check("撤销移墙", t.notes.first { $0.id == nYellow.id }?.wallID == w1.id)

        // 墙管理
        t.moveWall(w1.id, by: 1)
        check("墙右移", t.walls.sorted { $0.sortOrder < $1.sortOrder }.map(\.name) == ["乙", "甲"])
        t.tintWall(w2.id, .mint)
        check("墙换色", t.walls.first { $0.id == w2.id }?.color == .mint)
        t.renameWall(w1.id, to: "  工作台  ")
        check("墙重命名去掉首尾空格", t.walls.first { $0.id == w1.id }?.name == "工作台")
        t.renameWall(w1.id, to: "   ")
        check("空白名字不覆盖原名", t.walls.first { $0.id == w1.id }?.name == "工作台")

        t.deleteWall(w2.id)
        check("删墙后墙内便签被移走", t.notes.filter { $0.wallID == w2.id }.isEmpty)
        check("删墙后只剩一面墙", t.walls.count == 1)
        _ = t.undo()
        check("撤销删墙：墙回来了", t.walls.contains { $0.id == w2.id })
        check("撤销删墙：便签回到原墙",
              t.notes.contains { $0.id == nBlue.id && $0.wallID == w2.id })

        // 清空回收站是不可逆操作：历史要一并清掉，不能留个假的撤销入口
        t.delete(nBlue.id)
        t.emptyTrash()
        check("清空回收站后没有可撤销的操作", t.undoLabel == nil)

        // 解锁有效期
        check("解锁有效期时长定义正确",
              UnlockPolicy.minutes5.seconds == 300
              && UnlockPolicy.session.seconds == nil
              && UnlockPolicy.everyTime.seconds == 0)

        let ls = AppStore(inMemory: true)
        ls.authenticator = TestAuthenticator(allow: true)
        ls.loadDemo(notes: [Note(wallID: w1.id, text: "秘密内容", paper: .blue, tag: "")], walls: [w1])
        let secretID = ls.notes[0].id
        _ = ls.lock(secretID)
        var opened = false
        ls.unlock(secretID) { opened = $0 }
        check("解锁成功（有效期测试的前置）", opened && !ls.notes[0].isLocked)
        ls.unlockPolicy = .everyTime
        ls.relockAfterViewing(secretID)
        check("「每次都要验证」：离开详情页就上锁", ls.notes[0].isLocked)

        // 屏幕边缘条：内容选取、安全排除、钉住顺序与撤销
        let es = AppStore(inMemory: true)
        es.authenticator = TestAuthenticator(allow: true)
        let ew = Wall(name: "边缘", sortOrder: 0, isDefault: true)
        var e1 = Note(wallID: ew.id, text: "第一张\n第二行", paper: .yellow, tag: "想法")
        var e2 = Note(wallID: ew.id, text: "第二张", paper: .blue, tag: "资料")
        var e3 = Note(wallID: ew.id, text: "第三张", paper: .mint, tag: "待办")
        e1.updatedAt = Date().addingTimeInterval(-300)
        e2.updatedAt = Date().addingTimeInterval(-200)
        e3.updatedAt = Date().addingTimeInterval(-100)
        es.loadDemo(notes: [e1, e2, e3], walls: [ew])
        check("最近编辑模式按 updatedAt 倒序",
              es.edgeNotes.map(\.id) == [e3.id, e2.id, e1.id])
        es.edgeCount = 2
        check("最近编辑模式受条数限制", es.edgeNotes.count == 2)
        es.edgeCount = 8

        var lockedID: UUID = e2.id
        _ = es.lock(e2.id)
        check("锁定的便签不进边缘条", !es.edgeNotes.contains { $0.id == lockedID })
        es.delete(e3.id)
        check("回收站里的便签不进边缘条", es.edgeNotes.map(\.id) == [e1.id])

        // 钉住模式：顺序由 edgePinnedIds 决定，不看编辑时间
        es.edgeMode = .pinned
        es.toggleEdgePin(e1.id)
        check("钉住后出现在边缘", es.edgeNotes.map(\.id) == [e1.id])
        check("钉住这一步可撤销", es.undoLabel == "钉到屏幕边缘")
        es.undo()
        check("撤销钉住后边缘为空", es.edgeNotes.isEmpty)
        check("撤销后仍在钉住集合外", !es.isEdgePinned(e1.id))
        es.redo()
        check("重做钉住", es.edgeNotes.map(\.id) == [e1.id])
        // 锁定的便签即使被钉住也不显示（id 保留，解锁后自动回来）
        es.toggleEdgePin(lockedID)
        check("钉住但锁定的便签仍不显示", es.edgeNotes.map(\.id) == [e1.id])
        check("钉住集合保留了锁定便签", es.isEdgePinned(lockedID))
        es.edgeMode = .recent

        // 几何：贴边侧必须与屏幕边缘齐平，overshoot 在屏幕外
        let vf = CGRect(x: 0, y: 25, width: 1440, height: 830)
        let right = EdgeDeckGeom.frame(side: .right, visible: vf, visibleSize: CGSize(width: 330, height: 420))
        check("右侧贴边：可视右缘正好落在屏幕边缘",
              abs((right.maxX - EdgeDeckGeom.overshoot) - vf.maxX) < 0.01)
        let left = EdgeDeckGeom.frame(side: .left, visible: vf, visibleSize: CGSize(width: 330, height: 420))
        check("左侧贴边：窗口左缘在屏幕外 overshoot", abs(left.minX - (vf.minX - EdgeDeckGeom.overshoot)) < 0.01)
        check("纵向不超出屏幕", right.minY >= vf.minY + 8 && right.maxY <= vf.maxY - 8)

        // 衬边：窗口要比内容宽/高出一条，自绘阴影才有地方衰减（否则被窗边硬切成「半透明边框」）
        let pullPad = EdgeDeckGeom.bleed(for: .pull(UUID()))
        let pullFrame = EdgeDeckGeom.frame(side: .right, visible: vf,
                                           visibleSize: CGSize(width: 362, height: 420),
                                           bleed: pullPad)
        check("抽出：窗口向左多长出一条衬边",
              abs(pullFrame.width - (362 + pullPad + EdgeDeckGeom.overshoot)) < 0.01)
        check("抽出：上下各留一条衬边（顶部/底部阴影不切边）",
              abs(pullFrame.height - (420 + pullPad * 2)) < 0.01)
        check("抽出：衬边不侵占贴边侧（内容仍在屏幕边缘）",
              abs(EdgeDeckGeom.contentEdge(side: .right, frame: pullFrame, bleed: pullPad) - vf.maxX) < 0.01)
        check("衬边按 2×半径 + 偏移 预留（面板 / 纸签）",
              pullPad >= EdgeDeckGeom.noteShadowRadius * 2 + EdgeDeckGeom.noteShadowDX
              && EdgeDeckGeom.bleed(for: .fan) >= EdgeDeckGeom.tabShadowRadius * 2 + EdgeDeckGeom.tabShadowDX)
        check("细条不留无用的衬边", EdgeDeckGeom.bleed(for: .rest) == 0)
        check("左侧：衬边与 overshoot 各在正确的一侧",
              abs(EdgeDeckGeom.contentEdge(side: .left,
                                          frame: EdgeDeckGeom.frame(side: .left, visible: vf,
                                                                    visibleSize: CGSize(width: 362, height: 420),
                                                                    bleed: pullPad),
                                          bleed: pullPad) - vf.minX) < 0.01)

        check("矮屏自动减签",
              EdgeDeckGeom.tabCapacity(visibleHeight: 300, requested: 6)
              < EdgeDeckGeom.tabCapacity(visibleHeight: 900, requested: 6))
        check("签列给按钮区让位（张数不多于纯签列）",
              EdgeDeckGeom.stackCapacity(visibleHeight: 900, requested: 8)
              <= EdgeDeckGeom.tabCapacity(visibleHeight: 900, requested: 8))
        check("签叠高度与张数一致",
              EdgeDeckGeom.stackHeight(count: 3) == EdgeDeckGeom.tabHeight + 2 * EdgeDeckGeom.tabStep)
        check("抽出面板高度有上下限",
              EdgeDeckGeom.noteHeight(text: "一行") == EdgeDeckGeom.noteMinHeight
              && EdgeDeckGeom.noteHeight(text: Array(repeating: "行", count: 40).joined(separator: "\n"))
                 == EdgeDeckGeom.noteMaxHeight)
        check("边缘标题取第一行", e1.edgeTitle == "第一张")

        // 「待办」标签的语义：普通文字要变成可勾选清单，否则标签只是个装饰
        check("待办：每行自动补 - [ ]",
              Checklist.asTodoList("买牛奶\n交房租") == "- [ ] 买牛奶\n- [ ] 交房租")
        check("待办：已是清单行不重复加前缀",
              Checklist.asTodoList("- [x] 已完成\n新的一条") == "- [x] 已完成\n- [ ] 新的一条")
        check("待办：空行原样保留",
              Checklist.asTodoList("第一条\n\n第二条") == "- [ ] 第一条\n\n- [ ] 第二条")
        check("待办：转换结果能被解析成 2 项",
              Checklist.parse(Checklist.asTodoList("a\nb")).count == 2)

        // 抽出期间冻结顺序：编辑会刷新 updatedAt，实时排序会让手里这张从第 3 跳到第 1
        let frozenModel = EdgeDeckModel()
        let wid = UUID()
        let n1 = Note(wallID: wid, text: "A", paper: .cream, tag: "")
        let n2 = Note(wallID: wid, text: "B", paper: .blue, tag: "")
        let n3 = Note(wallID: wid, text: "C", paper: .mint, tag: "")
        var bumped = n3
        bumped.updatedAt = Date().addingTimeInterval(60)   // 模拟刚编辑完
        let live = [bumped, n1, n2]                        // updatedAt 排序会把 C 顶到第一
        frozenModel.frozenOrder = [n1.id, n2.id, n3.id]
        check("冻结期间顺序不变（不会跳到第一位）",
              frozenModel.ordered(live).map(\.id) == [n1.id, n2.id, n3.id])
        frozenModel.frozenOrder = nil
        check("收起后恢复按最近编辑排序", frozenModel.ordered(live).first?.id == n3.id)

        // 新字段要能存住，且老存档没有这些字段也必须能解码
        var arch = Archive()
        arch.paperFilter = [.yellow, .blue]
        arch.timeFilter = .week
        arch.statusFilter = .todo
        arch.unlockPolicy = .minutes5
        arch.captureFrame = [10, 20, 566, 236]
        arch.edgeEnabled = false
        arch.edgeSide = .left
        arch.edgeMode = .pinned
        arch.edgeCount = 5
        arch.edgePinnedIds = [e1.id]
        if let data = try? JSONEncoder.archive.encode(arch),
           let back = try? JSONDecoder.archive.decode(Archive.self, from: data) {
            check("筛选条件写进存档", Set(back.paperFilter ?? []) == [.yellow, .blue])
            check("时间筛选写进存档", back.timeFilter == .week)
            check("状态筛选写进存档", back.statusFilter == .todo)
            check("解锁有效期写进存档", back.unlockPolicy == .minutes5)
            check("捕获面板位置写进存档", back.captureFrame?.count == 4)
            check("边缘设置写进存档",
                  back.edgeEnabled == false && back.edgeSide == .left
                  && back.edgeMode == .pinned && back.edgeCount == 5)
            check("边缘钉住顺序写进存档", back.edgePinnedIds == [e1.id])
        } else {
            check("筛选条件写进存档", false)
        }
        if let old = try? JSONDecoder.archive.decode(Archive.self, from: legacyJSON) {
            check("老存档缺新字段也能解码",
                  old.paperFilter == nil && old.timeFilter == nil && old.statusFilter == nil)
            check("老存档默认开启边缘条且停右侧",
                  old.edgeEnabled == nil && old.edgeSide == nil && old.edgePinnedIds == nil)
        } else {
            check("老存档缺新字段也能解码", false)
        }
    }

    print(failures == 0 ? "全部通过" : "\(failures) 项失败")
    exit(failures == 0 ? 0 : 1)
}

// 端到端：菜单栏「设置…」→ 通知 → 墙窗口弹设置 sheet。
// 不模拟点击（那要辅助功能授权），而是调菜单项自己绑的那个方法，
// 走完「立旗子 → bringWallToFront → post → onReceive」整条链路。
if args.contains("--settingsfrommenu") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)

        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "✓ \(name)" : "✗ \(name)")
            if !ok { failures += 1 }
        }
        func settle(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

        let store = AppStore.demo()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                           styleMask: [.titled, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "便签墙"
        win.titlebarAppearsTransparent = true
        win.contentView = NSHostingView(rootView:
            WallView().environmentObject(store).frame(width: 1000, height: 720))
        AppContext.shared.wallWindow = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settle(1.5)
        check("墙窗口已上屏", win.isVisible)
        check("点菜单项前没有设置 sheet", win.attachedSheet == nil)

        // 这就是菜单里「设置…」绑的方法，一分不差
        AppDelegate().openPreferences()
        settle(1.2)
        check("点「设置…」后设置 sheet 挂上了", win.attachedSheet != nil)

        // 取证：按 windowNumber 直接截窗口，不依赖它是否在当前 Space。
        // 前台被别的 App（尤其全屏 App）占着时，整屏截图根本拍不到我们。
        func shot(_ number: Int, _ path: String) -> Int {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-x", "-o", "-l", "\(number)", path]
            try? proc.run()
            proc.waitUntilExit()
            return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) as? Int ?? 0
        }
        let wallBytes = shot(win.windowNumber, "/tmp/sfm-wall.png")
        check("墙窗口截图非空（\(wallBytes / 1024) KB）", wallBytes > 10_000)
        if let sheet = win.attachedSheet {
            let sheetBytes = shot(sheet.windowNumber, "/tmp/sfm-sheet.png")
            print("  诊断 设置 sheet 窗口 #\(sheet.windowNumber)，截图 \(sheetBytes / 1024) KB")
            check("设置 sheet 截图非空（\(sheetBytes / 1024) KB）", sheetBytes > 10_000)
        } else {
            check("存在设置 sheet 窗口", false)
        }

        AppContext.shared.pendingOpenSettings = false
        print(failures == 0 ? "settingsfrommenu 全部通过" : "settingsfrommenu \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}

NoteWallApp.main()