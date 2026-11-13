import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - 便签详情

final class NoteDraftBox: ObservableObject {
    @Published var note: Note
    init(_ note: Note) { self.note = note }
}

struct NoteDetailSheet: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var box: NoteDraftBox
    var onClose: () -> Void

    init(note: Note, onClose: @escaping () -> Void) {
        _box = StateObject(wrappedValue: NoteDraftBox(note))
        self.onClose = onClose
    }

    private var draft: Note { box.note }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if draft.isLocked {
                lockedBody
            } else {
                topBar
                editor
                if let img = draft.image, let ns = ThumbCache.shared.full(img) {
                    imageBlock(ns)
                }
                footer
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(draft.paper.paper)
        )
        .overlay(alignment: .topTrailing) { closeButton }
        .background(lockShortcut)
        // ⌘V 粘图是在主界面的键盘监听里做的（它才拿得到全局按键），
        // 这里把 store 里的新图同步进来——box 是独立副本，不同步就看不到刚贴的图。
        .onReceive(store.$notes) { notes in
            guard let fresh = notes.first(where: { $0.id == box.note.id }),
                  fresh.image?.fileName != box.note.image?.fileName else { return }
            box.note.image = fresh.image
        }
    }

    /// ⌘⇧L 锁定。用隐藏按钮而不是全局键盘监听：全局监听要额外管注册/注销，
    /// 而键盘快捷键是窗口级的，sheet 一关自然失效，不会残留到主界面。
    private var lockShortcut: some View {
        Button("") { lockNow() }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!store.canLock(draft))
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// 详情页也要拦：锁着的时候连编辑框都不该存在，而不是「显示出来但禁止编辑」。
    private var lockedBody: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(draft.paper.ink.opacity(0.5))
                .frame(width: 48, height: 48)
                .background(Circle().fill(draft.paper.ink.opacity(0.07)))

            VStack(spacing: 5) {
                Text("这张便签已锁定")
                    .font(.ui(14, .medium))
                    .foregroundStyle(draft.paper.ink.opacity(0.82))
                Text(store.keyStale
                     ? "内容已无法解密：主密钥换过了。"
                     : (store.authenticator.kind.available
                        ? "内容以密文保存在本机，解锁需要 \(store.authenticator.kind.title)。"
                        : "这台 Mac 上无法验证身份（没有 Touch ID，也没设登录密码），暂时打不开。"))
                    .font(.ui(11.5))
                    .foregroundStyle(draft.paper.ink.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button { unlock() } label: { Text("解锁") }
                .buttonStyle(PillButtonStyle(bg: draft.paper.ink.opacity(0.86),
                                             fg: draft.paper.paper, height: 30, hPad: 18)).handCursor()
                .disabled(store.keyStale || !store.authenticator.kind.available)

            if let at = draft.lockedAt {
                Text("锁定于 \(TimeLabel.card(at))")
                    .font(.ui(10.5))
                    .foregroundStyle(draft.paper.ink.opacity(0.32))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
        .padding(.bottom, 40)
    }

    private func unlock() {
        store.unlock(draft.id) { ok in
            guard ok, let fresh = store.notes.first(where: { $0.id == draft.id }) else { return }
            box.note = fresh
        }
    }

    private func lockNow() {
        _ = store.lock(draft.id)
        onClose()
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            ForEach(["想法", "灵感", "待办", "资料", "参考"], id: \.self) { tag in
                Button {
                    box.note.tag = (box.note.tag == tag) ? "" : tag
                } label: {
                    Text(tag)
                        .font(.ui(11.5, .medium))
                        .foregroundStyle(draft.paper.ink.opacity(draft.tag == tag ? 0.9 : 0.42))
                        .frame(height: 24)
                        .padding(.horizontal, 9)
                        .background(
                            Capsule().fill(draft.paper.ink.opacity(draft.tag == tag ? 0.10 : 0.04))
                        )
                }
                .buttonStyle(.plain).handCursor()
            }
            Spacer(minLength: 8)
            if draft.isLocked {
                Label("已锁定", systemImage: "lock.fill")
                    .font(.ui(10.5))
                    .foregroundStyle(draft.paper.ink.opacity(0.5))
            }
        }
        .padding(.bottom, 14)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if RenderFlags.snapshot {
                if draft.text.isEmpty {
                    Text("写点什么…")
                        .font(.ui(15))
                        .foregroundStyle(draft.paper.ink.opacity(0.3))
                        // 与 TextEditor 的文字起点对齐，否则光标压在占位字上
                        .offset(x: EditorMetrics.textOrigin.width, y: EditorMetrics.textOrigin.height)
                }
                Text(draft.text)
                    .font(.ui(15))
                    .foregroundStyle(draft.paper.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 150, alignment: .topLeading)
                    .lineSpacing(5)
            } else {
                EditorPlaceholder(text: "写点什么…",
                                  color: draft.paper.ink.opacity(0.3),
                                  fontSize: 15)
                    .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150,
                           alignment: .topLeading)
                    .allowsHitTesting(false)
                PlainTextEditor(text: box.bind(\.note.text), fontSize: 15,
                                ink: draft.paper.ink)
                    .frame(height: 150)
            }
        }
    }

    private func imageBlock(_ ns: NSImage) -> some View {
        Image(nsImage: ns)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(draft.paper.ink.opacity(0.10))
            HStack(spacing: 8) {
                Text("添加于 \(TimeLabel.card(draft.createdAt))")
                    .font(.ui(10.5))
                    .foregroundStyle(draft.paper.ink.opacity(0.42))
                if draft.updatedAt.timeIntervalSince(draft.createdAt) > 60 {
                    Text("· 编辑于 \(TimeLabel.card(draft.updatedAt))")
                        .font(.ui(10.5))
                        .foregroundStyle(draft.paper.ink.opacity(0.32))
                }
                Spacer()
                Button { lockNow() } label: {
                    Image(systemName: "lock")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(draft.paper.ink.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(draft.paper.ink.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).handCursor()
                .help("锁定这张便签（⌘⇧L，解锁要 Touch ID）")
                .disabled(!store.canLock(draft))
                .opacity(store.canLock(draft) ? 1 : 0.4)
                .padding(.trailing, 2)
                paperTrack
                Button { save() } label: { Text("保存") }
                    .buttonStyle(PillButtonStyle(bg: draft.paper.ink.opacity(0.86),
                                                 fg: draft.paper.paper,
                                                 height: 28, hPad: 14)).handCursor()
            }
            .padding(.top, 10)
        }
        .padding(.top, 14)
    }

    private var paperTrack: some View {
        HStack(spacing: 0) {
            ForEach(Paper.allCases) { p in
                Button { box.note.paper = p } label: {
                    PaperSwatch(paper: p, ink: draft.paper.ink,
                                selected: draft.paper == p, side: 15, cell: 22)
                }
                .buttonStyle(.plain).handCursor()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(draft.paper.ink.opacity(0.10))
        )
        .padding(.trailing, 6)
    }

    private var closeButton: some View {
        Button { save() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(draft.paper.ink.opacity(0.45))
                .frame(width: 22, height: 22)
                .background(Circle().fill(draft.paper.ink.opacity(0.06)))
        }
        .buttonStyle(.plain).handCursor()
        .padding(14)
    }

    private func save() {
        guard !draft.isLocked else { onClose(); return }
        var n = box.note
        n.text = Checklist.autoComplete(n.text)
        store.update(n)
        onClose()
    }
}

// MARK: - 回收站

struct TrashSheet: View {
    @EnvironmentObject private var store: AppStore
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("回收站").font(.ui(16, .semibold)).foregroundStyle(T.text)
                Spacer()
                Button("清空") { store.emptyTrash() }
                    .buttonStyle(GhostButtonStyle(height: 26, hPad: 10)).handCursor()
                    .disabled(store.trashedNotes.isEmpty)
                Button("关闭") { onClose() }
                    .buttonStyle(PillButtonStyle(bg: T.insetPressed, fg: T.text, height: 26, hPad: 12)).handCursor()
            }
            .padding(.bottom, 14)

            if store.trashedNotes.isEmpty {
                Text("回收站是空的。删掉的便签会在这里保留 30 天。")
                    .font(.ui(12.5)).foregroundStyle(T.textDim)
                    .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.trashedNotes) { note in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(note.paper.paper)
                                    .frame(width: 22, height: 22)
                                if note.isLocked {
                                    // 锁定便签在回收站里也不露出内容（PRD §2.8）
                                    Label("已锁定的便签", systemImage: "lock.fill")
                                        .font(.ui(12.5)).foregroundStyle(T.textDim)
                                } else {
                                    Text(note.text.replacingOccurrences(of: "\n", with: " ").prefix(40))
                                        .font(.ui(12.5)).foregroundStyle(T.text)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("恢复") { store.restore(note.id) }
                                    .buttonStyle(GhostButtonStyle(height: 24, hPad: 9)).handCursor()
                                Button("彻底删除") { store.deleteForever(note.id) }
                                    .buttonStyle(GhostButtonStyle(height: 24, hPad: 9)).handCursor()
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(T.panelCard))
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 520, height: 420)
        .background(T.panel)
    }
}

// MARK: - 设置

final class SettingsBox: ObservableObject {
    @Published var launchAtLogin: Bool = LaunchAtLogin.isEnabled
}

struct SettingsSheet: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var box = SettingsBox()
    var onClose: () -> Void

    private var lockedCount: Int { store.notes.filter(\.isLocked).count }

    /// 说明文字跟着当前选择走：三种模式的实际行为不一样，不要用一句通用废话糊过去。
    private var appearanceHint: String {
        switch store.appearance {
        case .system: return "跟随 macOS 的浅色/深色设置，系统切换时立刻同步。"
        case .light:  return "固定浅色。侧栏是米白，主区是纯白，便签靠一圈细边和淡投影压住。"
        case .dark:   return "固定深色。侧栏 #171717、主区 #212121，比纯黑亮一档，便签才浮得起来。"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(T.line)
            Group {
                if RenderFlags.snapshot {
                    settingsBody
                } else {
                    // 只把滚动条改成 overlay：静止时不占位，滚动/输入时浮出来。
                    // 直接关掉指示器会让「下面还有内容」完全没提示。
                    // 关掉滚动指示器：SwiftUI 的 ScrollView 即使换成 overlay 滚动条，
                    // 仍会在布局层预留约 16pt，右侧就比左侧宽出一条，内容看着不居中。
                    // 设置页靠触控板/滚轮滚动，指示器本来也只在滚动时才该出现。
                    ScrollView(.vertical, showsIndicators: false) { settingsBody }
                }
            }
        }
        .frame(width: SettingsSheet.windowWidth,
               height: (RenderFlags.snapshot || SettingsSheet.autoHeight) ? nil : 640)
        .background(T.panel)
    }

    /// 自检用：放开固定高度，一屏截完整个设置页（真实使用永远是 580 的 sheet）
    static var autoHeight = false

    /// 窗口与内容区的间距。标题栏和内容用同一个数，左右才对齐。
    static let gutter: CGFloat = 28
    static let windowWidth: CGFloat = 600
    static var contentWidth: CGFloat { windowWidth - gutter * 2 }

    private var header: some View {
        HStack(spacing: 10) {
            Text("设置").font(.ui(15, .semibold)).foregroundStyle(T.text)
            Spacer()
            Button("完成") { onClose() }
                .buttonStyle(PillButtonStyle(bg: T.insetPressed, fg: T.text, height: 26, hPad: 12)).handCursor()
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Self.gutter)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 26) {
                    group("外观") {
                        VStack(alignment: .leading, spacing: 10) {
                            AppearancePicker(current: store.appearance) { mode in
                                store.appearance = mode
                            }
                            Text(appearanceHint)
                                .font(.ui(10.5)).foregroundStyle(T.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    group("通用") {
                        row("显示清单完成数", subtitle: "卡片底部显示 2/5 这样的计数") {
                            if RenderFlags.snapshot {
                                FakeSwitch(on: store.checkCountVisible)
                            } else {
                                Toggle("", isOn: store.bind(\.checkCountVisible))
                                    .toggleStyle(.switch).labelsHidden().handCursor()
                            }
                        }
                        row("开机自动启动", subtitle: "登录时自动打开随手贴") {
                            if RenderFlags.snapshot {
                                FakeSwitch(on: box.launchAtLogin)
                            } else {
                                Toggle("", isOn: $box.launchAtLogin)
                                    .toggleStyle(.switch).labelsHidden().handCursor()
                                    .onChange(of: box.launchAtLogin) { on in
                                        // 注册失败要回滚，否则用户以为设成功了
                                        if !LaunchAtLogin.set(on) {
                                            box.launchAtLogin = LaunchAtLogin.isEnabled
                                        }
                                    }
                            }
                        }
                        row("菜单栏图标", subtitle: "无刘海设备上作为主要入口", showDivider: false) {
                            if RenderFlags.snapshot {
                                FakeSwitch(on: true)
                            } else {
                                Toggle("", isOn: .constant(true))
                                    .toggleStyle(.switch).labelsHidden().handCursor()
                                    .disabled(true)
                            }
                        }
                    }

                    group("快捷键") {
                        hotkeyRow(.newNote)
                        hotkeyRow(.openWall)
                        row("钉住捕获面板", subtitle: "保存后不自动关闭（面板打开时才生效）") {
                            keyCap("⌘ ⇧ P")
                        }
                        row("恢复默认", subtitle: "\(HotkeyConfig.standard.newNote.display) 新建 · \(HotkeyConfig.standard.openWall.display) 打开", showDivider: false) {
                            Button("恢复") { store.resetHotkeys() }
                                .buttonStyle(GhostButtonStyle(height: 24, hPad: 9)).handCursor()
                                .disabled(store.hotkeys == .standard)
                        }
                        if let msg = store.hotkeyMessage {
                            Label(msg, systemImage: "exclamationmark.triangle.fill")
                                .font(.ui(11))
                                .foregroundStyle(T.accent)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 10)
                        } else {
                            hint("点上面的按键就能重新录入。全局快捷键会把这组键从所有 App 手里接过来，被占用或影响系统功能时会在这里说明。")
                        }
                    }

                    group("屏幕边缘") {
                        row("边缘便签条", subtitle: "屏幕边缘常驻一条细边，鼠标移过去展开") {
                            if RenderFlags.snapshot {
                                FakeSwitch(on: store.edgeEnabled)
                            } else {
                                Toggle("", isOn: store.bind(\.edgeEnabled))
                                    .toggleStyle(.switch).labelsHidden().handCursor()
                            }
                        }
                        row("停靠在", subtitle: "换边立即生效，也可以右键边缘条切换") {
                            edgePicker(
                                selection: store.bind(\.edgeSide),
                                options: EdgeSide.allCases.map { ($0, $0.title) }
                            )
                            .disabled(!store.edgeEnabled)
                            .opacity(store.edgeEnabled ? 1 : 0.45)
                        }
                        row("显示内容", subtitle: store.edgeMode.hint,
                            showDivider: store.edgeMode == .recent) {
                            edgePicker(
                                selection: store.bind(\.edgeMode),
                                options: EdgeMode.allCases.map { ($0, $0.title) }
                            )
                            .disabled(!store.edgeEnabled)
                            .opacity(store.edgeEnabled ? 1 : 0.45)
                        }
                        if store.edgeMode == .recent {
                            row("最多显示", subtitle: "按最近编辑排序取前几张", showDivider: false) {
                                stepperControl(value: store.bind(\.edgeCount), range: 3...12,
                                               unit: "张")
                            }
                            .disabled(!store.edgeEnabled)
                            .opacity(store.edgeEnabled ? 1 : 0.45)
                        }
                        hint("锁定的便签永远不会出现在边缘。钉住模式从卡片的「⋯」菜单里逐张管理；抽出面板里改完即存，停手自动写盘。")
                    }

                    group("安全") {
                        row("解锁方式", subtitle: "锁定是把内容加密落盘，解锁要验证身份") {
                            valueText(store.authenticator.kind.title,
                                      accent: !store.authenticator.kind.available)
                        }
                        policyRow
                        row("已锁定", subtitle: "这些便签的正文与图片在磁盘上都是密文") {
                            valueText("\(lockedCount) 张")
                        }
                        row("加密", subtitle: "AES-GCM 256 · 主密钥 \(store.vault.keyID)",
                            showDivider: !store.keyStale) {
                            valueText("vault.key")
                        }
                        if store.keyStale {
                            row("主密钥已更换", subtitle: "与存档里的密文不匹配，锁定的便签暂时无法解密",
                                showDivider: false) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11)).foregroundStyle(T.accent)
                            }
                        }
                        hint("锁定的便签不进搜索结果、不显示缩略图，回收站里只显示「已锁定的便签」。主密钥是本机一个 0600 权限的独立文件，不写进存档、不进 Time Machine 备份；退出应用时本次解锁过的便签会自动重新锁上。")
                    }

                    group("数据") {
                        row("存储位置", subtitle: Paths.support.path) {
                            Button("在访达中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([Paths.support])
                            }
                            .buttonStyle(GhostButtonStyle(height: 24, hPad: 9)).handCursor()
                        }
                        row("捕获面板位置", subtitle: store.captureFrame == nil ? "默认在屏幕中央偏上" : "已记住上次的位置") {
                            Button("重置") { store.captureFrame = nil }
                                .buttonStyle(GhostButtonStyle(height: 24, hPad: 9)).handCursor()
                                .disabled(store.captureFrame == nil)
                        }
                        row("回收站", subtitle: "\(store.trashedNotes.count) 张便签待清理", showDivider: false) {
                            Button("清空") { store.emptyTrash() }
                                .buttonStyle(GhostButtonStyle(height: 24, hPad: 9)).handCursor()
                                .disabled(store.trashedNotes.isEmpty)
                        }
                    }
                }
        // 先限宽、再撑满居中：只写 maxWidth: .infinity 会让每张卡片各按内容长度缩，
        // 视觉上就是「左边齐、右边参差」，正是这一版要修的问题。
        .frame(maxWidth: Self.contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, Self.gutter)
        .padding(.vertical, 22)
    }

    /// 快捷键行：右侧是可录制的组合键，选中热门/危险组合时在行下给出引导。
    /// 引导文字算在这一行里，所以分隔线画在它后面，不能画在行本身。
    @ViewBuilder
    private func hotkeyRow(_ slot: HotkeySlot, showDivider: Bool = true) -> some View {
        let combo = store.hotkeys.combo(for: slot)
        VStack(spacing: 0) {
            row(slot.title,
                subtitle: slot == .newNote ? "在任何 App 里唤起悬浮输入面板" : "唤起整个随手贴窗口",
                showDivider: false) {
                if RenderFlags.snapshot {
                    keyCap(combo.display)
                } else {
                    HotkeyRecorder(combo: combo) { new in
                        store.setHotkey(slot, to: new)
                    }
                }
            }
            if let advice = HotkeyRules.advisory(combo) {
                hint(advice, top: 0)
            }
            if showDivider {
                Rectangle().fill(T.line).frame(height: 0.5).padding(.leading, 14)
            }
        }
    }

    /// 解锁有效期。做成一行下拉而不是三个开关：这几个值互斥，开关会让人误会能组合。
    @ViewBuilder
    private var policyRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("解锁有效期", subtitle: "解锁后多久自动重新上锁", showDivider: false) {
                if RenderFlags.snapshot {
                    menuChrome(store.unlockPolicy.title)
                } else {
                    Picker("", selection: store.bind(\.unlockPolicy)) {
                        ForEach(UnlockPolicy.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.menu).handCursor()
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            hint(store.unlockPolicy.hint, top: 0)
        }
    }

    /// 下拉选择的外观。macOS 的 `borderlessButton` 菜单只剩一行字，
    /// 用户根本看不出它可点——所以统一加胶囊底 + chevron，和开关、按钮说同一套语言。
    private func menuChrome(_ text: String) -> some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.ui(11.5, .medium))
                .foregroundStyle(T.text)
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(T.textFaint)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(T.line, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func edgePicker<Value: Hashable>(selection: Binding<Value>,
                                             options: [(Value, String)]) -> some View {
        let current = options.first { $0.0 == selection.wrappedValue }?.1 ?? ""
        if RenderFlags.snapshot {
            menuChrome(current)
        } else {
            // 用系统标准的下拉外观，不要自己画壳，也不要 borderlessButton：
            // 后者会把自定义 label 简化成一行字，还在**左边**补一个箭头，
            // 看上去既不像控件也不是 macOS 的惯例。
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { value, title in
                    Text(title).tag(value)
                }
            }
            .pickerStyle(.menu).handCursor()
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.ui(11.5, .semibold))
                .kerning(0.2)
                .foregroundStyle(T.textFaint)
                .padding(.leading, 2)
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(T.panelCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(T.line, lineWidth: 0.5)
                )
        }
    }

    /// 设置行。`showDivider` 由调用方给最后一行传 false——分组末尾不该再有一条半截线。
    private func row(_ title: String, subtitle: String, showDivider: Bool = true,
                     @ViewBuilder trailing: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(12.5)).foregroundStyle(T.text)
                    Text(subtitle)
                        .font(.ui(10.5))
                        .foregroundStyle(T.textFaint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                trailing()
                    .layoutPriority(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if showDivider {
                Rectangle()
                    .fill(T.line)
                    .frame(height: 0.5)
                    .padding(.leading, 14)
            }
        }
    }

    /// 只读值（Touch ID / 已锁定 / 密钥文件名）。不是控件，所以不给底、不给边，
    /// 只靠右对齐和颜色跟左侧标题拉开层次——免得它和下拉长得像。
    private func valueText(_ s: String, accent: Bool = false) -> some View {
        Text(s)
            .font(.ui(11.5, .medium))
            .foregroundStyle(accent ? T.accent : T.textDim)
            .lineLimit(1)
    }

    /// 步进器。系统 `Stepper` 是两根 8pt 的上下箭头，在一行设置里几乎看不见，
    /// 也说不清「现在到底是多少」——换成 [−] 数值 [＋] 的一体胶囊。
    private func stepperControl(value: Binding<Int>, range: ClosedRange<Int>,
                                unit: String) -> some View {
        HStack(spacing: 0) {
            stepGlyph("minus", enabled: value.wrappedValue > range.lowerBound) {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1)
            }
            Text("\(value.wrappedValue) \(unit)")
                .font(.ui(11.5, .medium))
                .foregroundStyle(T.text)
                .monospacedDigit()
                .frame(minWidth: 42)
                .padding(.horizontal, 2)
            stepGlyph("plus", enabled: value.wrappedValue < range.upperBound) {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + 1)
            }
        }
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(T.line, lineWidth: 0.5)
        )
    }

    private func stepGlyph(_ symbol: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? T.text : T.textFaint)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .disabled(!enabled)
    }

    /// 分组底部的说明文字：跟行的左内边距对齐
    private func hint(_ s: String, top: CGFloat = 2) -> some View {
        Text(s)
            .font(.ui(10.5))
            .foregroundStyle(T.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, top)
            .padding(.bottom, 10)
    }

    private func keyCap(_ s: String) -> some View {
        Text(s)
            .font(.ui(10.5, .medium))
            .foregroundStyle(T.textDim)
            .padding(.horizontal, 8).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(T.inset))
    }
}


/// 仅为离屏渲染准备的开关替身（真实 Toggle 由 AppKit 绘制，截不出来）
struct FakeSwitch: View {
    var on: Bool
    var body: some View {
        Capsule()
            .fill(on ? T.accent : T.insetPressed)
            .frame(width: 38, height: 22)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            }
    }
}

// MARK: - 录键控件

/// 录键期间的瞬时状态。本地键盘监听只在录制中存在，
/// 不录制时一个多余的事件都不碰。
@MainActor
final class RecorderBox: ObservableObject {
    @Published var isRecording = false
    /// 按住修饰键还没敲主键时的实时预览，如「⌥ …」
    @Published var live: String? = nil

    private var monitor: Any? = nil
    private var onCommit: ((HotkeyCombo) -> Void)? = nil

    func start(onCommit: @escaping (HotkeyCombo) -> Void) {
        guard !isRecording else { return }
        self.onCommit = onCommit
        isRecording = true
        live = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }

    func stop() {
        isRecording = false
        live = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        if event.type == .flagsChanged {
            // 只按修饰键时给个预览，不算完成
            live = KeySymbols.modifierPreview(carbonModifiers: event.modifierFlags.carbonMask)
            return event
        }
        // Esc 是「取消」不是「录成 Esc」
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return nil
        }
        let combo = HotkeyCombo(event: event)
        stop()
        onCommit?(combo)
        return nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// 平时显示当前组合键；点一下开始录制，敲下组合键提交，Esc 取消
struct HotkeyRecorder: View {
    let combo: HotkeyCombo
    var onCommit: (HotkeyCombo) -> Void
    @StateObject private var box = RecorderBox()

    var body: some View {
        Button {
            // 再点一次 = 取消，比「只能按 Esc」多一条出路
            if box.isRecording { box.stop() } else { box.start(onCommit: onCommit) }
        } label: {
            Text(box.isRecording ? (box.live ?? "按下新的组合键") : combo.display)
                .font(.ui(10.5, .medium))
                .foregroundStyle(box.isRecording ? T.accent : T.textDim)
                .frame(minWidth: 100)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(box.isRecording ? T.accent.opacity(0.12) : T.inset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(box.isRecording ? T.accent.opacity(0.7) : Color.clear,
                                      lineWidth: 1)
                )
        }
        .buttonStyle(.plain).handCursor()
        .help("点一下，再按下想要的组合键；Esc 取消")
        .onDisappear { box.stop() }   // 设置页关掉时别留一个还在监听键盘的监控器
    }
}


