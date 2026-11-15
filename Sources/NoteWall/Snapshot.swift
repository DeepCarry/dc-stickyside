import SwiftUI
import AppKit

/// 离屏渲染：把真实 SwiftUI 视图渲成 PNG，用于在没有屏幕录制权限的环境里检查版式。
/// 用法：NoteWall --snapshot wall /tmp/wall.png 1440x920
enum Snapshot {
    @MainActor
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot") else { return false }
        let scene = i + 1 < args.count ? args[i + 1] : "wall"
        let out = i + 2 < args.count ? args[i + 2] : "/tmp/notewall-\(scene).png"
        var size = CGSize(width: 1440, height: 920)
        if i + 3 < args.count {
            let parts = args[i + 3].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
        }
        // 主题要能单独渲染，否则浅色那套没人看得见、也没法做像素断言
        var scheme = ColorScheme.dark
        if let k = args.firstIndex(of: "--appearance"), k + 1 < args.count {
            scheme = args[k + 1] == "light" ? .light : .dark
        }
        MainActor.assumeIsolated { render(scene: scene, to: out, size: size, scheme: scheme) }
        return true
    }

    @MainActor
    private static func render(scene: String, to path: String, size: CGSize, scheme: ColorScheme) {
        // 需要一个 NSApplication 实例，否则字体与颜色解析不完整
        _ = NSApplication.shared
        RenderFlags.snapshot = true
        NSApp.setActivationPolicy(.prohibited)

        let store = AppStore.demo()
        store.searchText = ""
        // 设置页要展示选中态；顺便让 demo 数据的外观跟截图一致
        store.appearance = scheme == .light ? .light : .dark

        let view: AnyView
        switch scene {
        case "capture":
            let m = CaptureModel()
            m.walls = store.walls
            m.wallID = store.walls.first(where: { $0.name == "工作" })?.id
            m.text = "便签不需要更聪明，只需要更快出现。"
            m.tag = "灵感"
            m.pinned = false
            view = AnyView(CaptureView(model: m, onSave: {}, onClose: {}, onPaste: {})
                .frame(width: 594, height: 268)
                .background(scheme == .light ? Color(hex: 0xD9D7D1) : Color(hex: 0x0E0E12)))
        case "cardmenu":
            view = AnyView(NoteCard(note: store.notes[2], walls: store.walls, hoverPreview: true)
                .frame(width: 340)
                .padding(24)
                .background(T.bg))
        case "card":
            view = AnyView(NoteCard(note: store.notes[2], walls: store.walls)
                .frame(width: 340)
                .padding(24)
                .background(T.bg))
        case "detail":
            view = AnyView(NoteDetailSheet(note: store.notes[3], onClose: {})
                .environmentObject(store)
                .frame(width: 520)
                .background(T.bg))
        case "locked":
            let n = store.notes.first(where: { $0.isLocked }) ?? store.notes[0]
            view = AnyView(NoteCard(note: n)
                .frame(width: 340)
                .padding(24)
                .background(T.bg))
        case "lockdetail":
            let n = store.notes.first(where: { $0.isLocked }) ?? store.notes[0]
            view = AnyView(NoteDetailSheet(note: n, onClose: {})
                .environmentObject(store)
                .frame(width: 520)
                .background(T.bg))
        case "edgefan", "edgepull":
            // 边缘条的扇开/抽出两态。细条态太简单，不值得一张图。
            let m = EdgeDeckModel()
            let target = store.notes.first(where: { !$0.isLocked }) ?? store.notes[0]
            if scene == "edgepull" {
                m.phase = .pull(target.id)
                m.draft = target.text
            } else {
                m.phase = .fan
            }
            view = AnyView(
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    EdgeDeckView(store: store, model: m)
                        .frame(width: scene == "edgepull" ? 340 : 36)
                }
                .frame(width: size.width, height: size.height)
                .background(scheme == .light ? Color(hex: 0xD9D7D1) : Color(hex: 0x0E0E12))
            )
        case "settings":
            view = AnyView(SettingsSheet(onClose: {}).environmentObject(store))
        case "trash":
            view = AnyView(TrashSheet(onClose: {}).environmentObject(store))
        case "empty":
            let s = AppStore(inMemory: true)
            s.loadDemo(notes: [], walls: [Wall(name: "我的便签")])
            view = AnyView(WallContent(ui: WallUI(), scrolls: false)
                .environmentObject(s)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(T.bg))
        default:
            let ui = WallUI()
            ui.draft = ""
            // wallimage：给输入区附一张图，用来核对「粘贴后的预览」长什么样
            if scene == "wallimage" {
                ui.draft = "这句话配一张图"
                let img = NSImage(size: NSSize(width: 320, height: 200))
                img.lockFocus()
                NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.58, alpha: 1).setFill()
                NSRect(x: 0, y: 0, width: 320, height: 200).fill()
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: NSRect(x: 96, y: 36, width: 128, height: 128)).fill()
                img.unlockFocus()
                ui.draftImage = img
            }
            view = AnyView(WallContent(ui: ui, scrolls: false)
                .environmentObject(store)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(T.bg))
        }

        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        renderer.isOpaque = true

        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(Int(img.size.width))x\(Int(img.size.height))")
    }
}
