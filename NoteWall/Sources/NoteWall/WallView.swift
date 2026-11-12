import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 局部 UI 状态

/// 墙相关的一次性对话。合成一个 enum 而不是给每个操作各挂一个 `.alert`：
/// 同一个视图上叠多个 alert，只有最后一个会响应（SwiftUI 的老问题）。
enum WallDialog: Equatable, Identifiable {
    case create
    case rename(Wall)
    case delete(Wall)

    var id: String {
        switch self {
        case .create: return "create"
        case .rename(let w): return "rename-\(w.id)"
        case .delete(let w): return "delete-\(w.id)"
        }
    }
}

/// SwiftUI 的 @State 宏在本机工具链下不可用，视图的局部状态统一放在这里。
final class WallUI: ObservableObject {
    @Published var draft: String = ""
    @Published var paper: Paper = .yellow
    @Published var tag: String = "灵感"
    @Published var editing: Note? = nil
    @Published var showDetail = false
    @Published var showSettings = false
    @Published var showTrash = false

    @Published var wallDialog: WallDialog? = nil
    @Published var wallNameDraft: String = ""
    @Published var showColorFilter = false

    /// 输入区待附加的图片。⌘V 或拖拽进来，提交时和正文一起落盘。
    @Published var draftImage: NSImage? = nil
    /// 拖拽悬停高亮：不加提示的话，用户不知道这里能接图
    @Published var draftDropTargeted = false

    var isDeleteDialog: Bool {
        if case .delete = wallDialog { return true }
        return false
    }

    var dialogTitle: String {
        switch wallDialog {
        case .create: return "新建一面墙"
        case .rename(let w): return "重命名「\(w.name)」"
        case .delete(let w): return "删除「\(w.name)」？"
        case .none: return ""
        }
    }

    var dialogConfirm: String {
        switch wallDialog {
        case .create: return "创建"
        case .rename: return "保存"
        case .delete: return "删除"
        case .none: return "确定"
        }
    }
}

// MARK: - 主界面（壳）

struct WallView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var ui = WallUI()

    var body: some View {
        WallContent(ui: ui, scrolls: true)
            .background(T.bg.ignoresSafeArea())
            // 主窗口的外观从这里下发。只设 NSApp.appearance 不够：已经开着的窗口
            // 不会因此重新解析 SwiftUI 里的动态色，实测点了没反应。
            // preferredColorScheme 一变，整棵子树重算，动态色才会真的换一套。
            .preferredColorScheme(store.appearance == .system ? nil : store.appearance.colorScheme)
            .sheet(isPresented: ui.bind(\.showDetail), onDismiss: {
                // 「每次都要验证」：面板一关就重新封上，明文不多留一秒
                if let n = ui.editing { store.relockAfterViewing(n.id) }
                ui.editing = nil
            }) {
                if let note = ui.editing {
                    NoteDetailSheet(note: note, onClose: { ui.showDetail = false })
                        .environmentObject(store)
                }
            }
            .sheet(isPresented: ui.bind(\.showSettings)) {
                SettingsSheet(onClose: { ui.showSettings = false })
                    .environmentObject(store)
            }
            .sheet(isPresented: ui.bind(\.showTrash)) {
                TrashSheet(onClose: { ui.showTrash = false })
                    .environmentObject(store)
            }
            .onAppear {
                KeyMonitor.shared.install()
                // 自检用：启动即弹设置，方便按像素核对 sheet 里的左右留白
                if CommandLine.arguments.contains("--opensettings") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ui.showSettings = true }
                }
                // 菜单栏「设置…」在墙窗口刚重建时发不出通知（订阅者还没起来），
                // 靠这个旗子兜住；消费完立刻清掉，免得下次开窗口又弹一次。
                if AppContext.shared.pendingOpenSettings {
                    AppContext.shared.pendingOpenSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ui.showSettings = true }
                }
            }
            // 墙窗口已经开着时的快路：菜单栏点「设置…」直接把 sheet 弹出来
            .onReceive(NotificationCenter.default.publisher(for: .noteWallOpenSettings)) { _ in
                guard AppContext.shared.pendingOpenSettings else { return }
                AppContext.shared.pendingOpenSettings = false
                ui.showSettings = true
            }
    }
}

// MARK: - 可见内容

/// 顶部区域常驻、只有便签区域滚动；离屏渲染时传 scrolls: false 直接渲染静态内容。
struct WallContent: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var ui: WallUI
    @ObservedObject private var toast = ToastCenter.shared
    var scrolls: Bool = true

    /// 拖拽过程中的临时状态（谁在被拖、落点在哪）。@StateObject 保证窗口重算不会丢。
    @StateObject private var dragState = DragState()
    /// 占位显隐由 EditorPlaceholder 在 AppKit 内部判断、正文由 PlainTextEditor 自己托管：
    /// 两者都不在打字期间发布 SwiftUI 状态，输入法组合文本才不会被重算吃掉。
    /// 焦点由 PlainTextEditor(focusOnAppear:) 在挂载时自己抢，不用 @FocusState。

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏单独一块底色：便签墙没有系统标题栏与侧栏，界面原本是一整片同色，
            // 看不出「工具在哪、内容在哪」。抬高一档明度 + 一条 1pt 分隔线就有了分区。
            VStack(spacing: 0) {
                header
                wallTabs
                composer
                filterBar
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background(T.panel)
            .overlay(alignment: .bottom) {
                Rectangle().fill(T.line).frame(height: 1)
            }

            if scrolls {
                ScrollView(.vertical, showsIndicators: false) {
                    grid
                        .padding(.horizontal, 26)
                        .padding(.bottom, 40)
                }
            } else {
                grid
                    .padding(.horizontal, 26)
                    .padding(.bottom, 40)
            }
        }
        .overlay(alignment: .bottom) { toastBar }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: toast.message)
        .onAppear {
            bindKeys()
        }
    }

    // MARK: 快捷键

    /// ⌘↩ 添加、⌘⇧↑ / ⌘⇧↓ 切换正倒序、⌘Z 撤销、⌘⇧Z 重做。
    /// 必须在这里注册：KeyMonitor 只是通道，注册了没人接等于快捷键不存在。
    private func bindKeys() {
        KeyMonitor.shared.install()
        KeyMonitor.shared.clear()
        KeyMonitor.shared.add { event in
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)

            // ⌘V：剪贴板里是图就自己收下。
            // 不拦截的话 TextEditor 会把文件 URL 当普通文本插进来，
            // 用户看到的是一串 /Users/... 路径——这就是「便签不支持图片」的真相。
            if cmd, event.keyCode == 9, let img = ComposerPaste.image() {
                if ui.showDetail, let note = ui.editing {
                    attachImageToNote(note)
                    return true
                }
                if !ui.showDetail, !ui.showSettings, !ui.showTrash, ui.wallDialog == nil,
                   NSApp.keyWindow?.firstResponder is NSTextView {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        ui.draftImage = img
                    }
                    return true
                }
                return false
            }

            // 主界面快捷键只在主窗口是 key 时生效。
            // 捕获面板是独立 NSPanel（不是 sheet），它有自己的 local monitor；
            // 主窗口这个 monitor 若抢先吞掉 ⌘↩，面板就永远收不到——用户按了没反应。
            guard NSApp.keyWindow === AppContext.shared.wallWindow else { return false }

            // 有弹层时让位：否则在详情/设置里按 ⌘↩ 会误触发主输入区的「添加」
            guard !ui.showDetail, !ui.showSettings, !ui.showTrash, ui.wallDialog == nil else { return false }
            let inText = NSApp.keyWindow?.firstResponder is NSTextView

            // ⌘Z / ⌘⇧Z：文本框里的撤销归 AppKit 管，抢了会让「刚打的字撤不掉」
            if cmd, event.keyCode == 6 {
                guard !inText else { return false }
                if shift {
                    guard let t = store.redo() else { return true }
                    ToastCenter.shared.show("已重做\(t)")
                } else {
                    guard let t = store.undo() else { return true }
                    ToastCenter.shared.show("已撤销\(t)", actionTitle: "重做") { _ = store.redo() }
                }
                return true
            }

            if cmd, !shift, event.keyCode == 36 {           // ⌘↩
                // 交给同一个提交入口：纯图片便签也能用快捷键存
                commitDraft()
                return true
            }
            if cmd, shift, event.keyCode == 126 {           // ⌘⇧↑ 最早在前
                store.sortMode = .oldest
                return true
            }
            if cmd, shift, event.keyCode == 125 {           // ⌘⇧↓ 最新在前
                store.sortMode = .newest
                return true
            }
            return false
        }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("便签墙")
                    .font(.ui(T.titleSize, .semibold))
                    .foregroundStyle(T.text)
                Text("每个灵感，都值得记下。便签自动保存。")
                    .font(.ui(12.5))
                    .foregroundStyle(T.textDim)
            }
            Spacer(minLength: 20)
            searchField
            HStack(spacing: 5) {
                Text("\(store.visibleNotes.count) 张便签")
                    .font(.ui(11.5))
                    .foregroundStyle(T.textFaint)
                if store.hasActiveFilters {
                    Text("· 已筛选")
                        .font(.ui(11.5))
                        .foregroundStyle(T.accent)
                }
            }
            .fixedSize()
            // 这个行是 .top 对齐：不撑到搜索框同高就会被顶到顶边，
            // 与 30pt 的搜索框差 8pt（实测），看起来像没对齐
            .frame(height: 30)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(T.textFaint)
            if RenderFlags.snapshot {
                Text(store.searchText.isEmpty ? "搜索便签" : store.searchText)
                    .font(.ui(12.5))
                    .foregroundStyle(store.searchText.isEmpty ? T.textFaint : T.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: store.bind(\.searchText),
                          prompt: Text("搜索便签").foregroundStyle(T.textFaint))
                    .textFieldStyle(.plain)
                    .font(.ui(12.5))
                    .foregroundStyle(T.text)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 240, height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(T.inset)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(T.line, lineWidth: 0.8)
                )
        )
    }

    // MARK: 墙

    private var orderedWalls: [Wall] {
        store.walls.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var wallTabs: some View {
        HStack(spacing: 4) {
            allTab
            ForEach(orderedWalls) { wall in wallTab(wall) }

            Button { openCreate() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(T.textFaint)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).handCursor()
            .help("新建一面墙")

            Spacer()

            Button { ui.showTrash = true } label: {
                Label("回收站", systemImage: "trash")
                    .font(.ui(11.5))
            }
            .buttonStyle(GhostButtonStyle(height: 26, hPad: 10)).handCursor()

            Button { ui.showSettings = true } label: {
                Label("设置", systemImage: "slider.horizontal.3")
                    .font(.ui(11.5))
            }
            .buttonStyle(GhostButtonStyle(height: 26, hPad: 10)).handCursor()
        }
        .padding(.top, 18)
        .alert(ui.dialogTitle,
               isPresented: Binding(get: { ui.wallDialog != nil },
                                    set: { if !$0 { ui.wallDialog = nil } })) {
            if !ui.isDeleteDialog, ui.wallDialog != nil {
                TextField("墙的名字", text: ui.bind(\.wallNameDraft))
            }
            if ui.isDeleteDialog {
                Button("删除", role: .destructive) { commitWallDialog() }
            } else {
                Button(ui.dialogConfirm) { commitWallDialog() }
            }
            Button("取消", role: .cancel) { ui.wallDialog = nil }
        } message: {
            if case let .delete(wall) = ui.wallDialog {
                Text(deleteWallMessage(wall))
            }
        }
    }

    private var allTab: some View {
        Button { store.selectedWallID = nil } label: {
            ChipLabel(text: "全部", active: store.selectedWallID == nil)
        }
        .buttonStyle(.plain).handCursor()
    }

    @ViewBuilder
    private func wallTab(_ wall: Wall) -> some View {
        if RenderFlags.snapshot {
            // 离屏渲染画不了 contextMenu / 拖放（会整块变成红色禁止符），截图路径不挂它们
            tabButton(wall)
        } else {
            tabButton(wall)
                .contextMenu { wallMenu(wall) }
                .onDrop(of: [.plainText], delegate: WallDropDelegate(
                    wallID: wall.id,
                    drag: dragState,
                    onDrop: { id, wid in moveToWall(id, wid) },
                    onHover: { _ in }))
        }
    }

    private func tabButton(_ wall: Wall) -> some View {
        let dropHover = dragState.target == .wall(wall.id)
        return Button { store.selectedWallID = wall.id } label: {
            ChipLabel(text: wall.name,
                      active: store.selectedWallID == wall.id || dropHover,
                      dot: wall.color.paper)
        }
        .buttonStyle(.plain).handCursor()
        .help("\(wall.name) · 右键可重命名、换色、排序")
    }

    @ViewBuilder
    private func wallMenu(_ wall: Wall) -> some View {
        let index = orderedWalls.firstIndex(where: { $0.id == wall.id }) ?? 0
        Button("重命名…") { openRename(wall) }
        Menu("换颜色") {
            ForEach(Paper.allCases) { p in
                Button(p.title) { store.tintWall(wall.id, p) }
            }
        }
        Divider()
        Button("左移") { store.moveWall(wall.id, by: -1) }
            .disabled(index == 0)
        Button("右移") { store.moveWall(wall.id, by: 1) }
            .disabled(index == orderedWalls.count - 1)
        Divider()
        Button("删除墙…", role: .destructive) { openDelete(wall) }
            .disabled(store.walls.count <= 1)
    }

    private func openCreate() {
        ui.wallNameDraft = ""
        ui.wallDialog = .create
    }

    private func openRename(_ wall: Wall) {
        ui.wallNameDraft = wall.name
        ui.wallDialog = .rename(wall)
    }

    private func openDelete(_ wall: Wall) {
        ui.wallDialog = .delete(wall)
    }

    private func deleteWallMessage(_ wall: Wall) -> String {
        let count = store.notes.filter { $0.wallID == wall.id && $0.deletedAt == nil }.count
        let fallback = orderedWalls.first(where: { $0.id != wall.id })?.name ?? "其它墙"
        return count > 0
            ? "这面墙里的 \(count) 张便签会移到「\(fallback)」，删除后可以按 ⌘Z 撤销。"
            : "这是一面空墙，删除后可以按 ⌘Z 撤销。"
    }

    private func commitWallDialog() {
        guard let dialog = ui.wallDialog else { return }
        switch dialog {
        case .create:
            let name = ui.wallNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let wall = store.addWall(name)
                store.selectedWallID = wall.id
            }
        case .rename(let wall):
            store.renameWall(wall.id, to: ui.wallNameDraft)
        case .delete(let wall):
            let count = store.notes.filter { $0.wallID == wall.id && $0.deletedAt == nil }.count
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                store.deleteWall(wall.id)
            }
            ToastCenter.shared.show(count > 0 ? "已删除「\(wall.name)」，便签已移走" : "已删除「\(wall.name)」",
                                    actionTitle: "撤销") { _ = store.undo() }
        }
        ui.wallDialog = nil
        ui.wallNameDraft = ""
    }

    // MARK: 输入区

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if RenderFlags.snapshot {
                    if ui.draft.isEmpty {
                        Text(ui.tag == "待办"
                             ? "每行一条待办，保存后自动变成可勾选项"
                             : "写下你的下一个灵感…")
                            .font(.ui(15))
                            .foregroundStyle(ui.paper.ink.opacity(0.38))
                            // 与 TextEditor 的文字起点对齐，否则光标压在占位字上
                            .offset(x: EditorMetrics.textOrigin.width, y: EditorMetrics.textOrigin.height)
                    }
                    Text(ui.draft)
                        .font(.ui(15))
                        .foregroundStyle(ui.paper.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 62, alignment: .topLeading)
                } else {
                    // 占位是常驻子视图：ZStack 的孩子数量恒定，TextEditor 的结构身份
                    // 不会因为「提示显/隐」而变化，输入法组合态也不会被重建。
                    EditorPlaceholder(
                        text: ui.tag == "待办"
                              ? "每行一条待办，保存后自动变成可勾选项"
                              : "写下你的下一个灵感…",
                        color: ui.paper.ink.opacity(0.38),
                        fontSize: 15)
                        .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62,
                               alignment: .topLeading)
                        .allowsHitTesting(false)
                    PlainTextEditor(text: ui.bind(\.draft), fontSize: 15,
                                    ink: ui.paper.ink, focusOnAppear: true)
                        .frame(height: 62)
                }
            }

            // 附加的图片：贴在正文下面、工具栏上面。
            // 移除按钮做成缩略图右上角的角标——放到行尾会离图太远，
            // 中间一大片空白，反而看不出它删的是哪张图。
            if let img = ui.draftImage {
                HStack(spacing: 12) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(ui.paper.ink.opacity(0.12), lineWidth: 1)
                        )
                        .overlay(alignment: .topTrailing) {
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) { ui.draftImage = nil }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 16, height: 16)
                                    .background(Circle().fill(Color.black.opacity(0.5)))
                            }
                            .buttonStyle(.plain).handCursor()
                            .offset(x: 6, y: -6)
                            .help("移除图片")
                        }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("图片已附加")
                            .font(.ui(11.5, .medium))
                            .foregroundStyle(ui.paper.ink.opacity(0.78))
                        Text("会和文字一起添加到墙上")
                            .font(.ui(10.5))
                            .foregroundStyle(ui.paper.ink.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
                .transition(.opacity)
            }

            HStack(spacing: 12) {
                paperTrack
                tagChips
                Spacer(minLength: 12)
                Text("⌘ ↩")
                    .font(.ui(10.5))
                    .foregroundStyle(ui.paper.ink.opacity(0.34))
                Button(action: commitDraft) {
                    Text("添加到墙上")
                }
                .buttonStyle(PillButtonStyle(bg: ui.paper.ink.opacity(0.85),
                                             fg: ui.paper.paper,
                                             height: 28, hPad: 14)).handCursor()
                .disabled(draftIsEmpty)
                .opacity(draftIsEmpty ? 0.55 : 1)
            }
            .padding(.top, 12)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ui.paper.paper)
                .shadow(color: T.cardShadow, radius: 12, y: 6)
        )
        // 拖图进来：和 ⌘V 等价。没有这个高亮，用户不知道纸面能接图。
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(ui.paper.ink.opacity(ui.draftDropTargeted ? 0.30 : 0),
                              lineWidth: 2)
        )
        .onDrop(of: [.fileURL, .image], isTargeted: ui.bind(\.draftDropTargeted)) { providers in
            guard let provider = providers.first else { return false }
            ImageStore.loadImage(from: provider) { img in
                guard let img else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    ui.draftImage = img
                }
            }
            return true
        }
        .padding(.top, 16)
    }

    /// 记录类型。之前在输入区根本没有入口，`ui.tag` 永远是「灵感」，
    /// 而「待办」这类标签不选就等于不存在——用户没法把一张便签记成待办。
    private var tagChips: some View {
        HStack(spacing: 2) {
            ForEach(["灵感", "想法", "待办", "资料"], id: \.self) { t in
                Button { ui.tag = t } label: {
                    Text(t)
                        .font(.ui(11))
                        .foregroundStyle(ui.tag == t ? ui.paper.ink.opacity(0.85)
                                                     : ui.paper.ink.opacity(0.40))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(
                            Capsule().fill(ui.tag == t ? ui.paper.ink.opacity(0.11) : Color.clear)
                        )
                }
                .buttonStyle(.plain).handCursor()
                .help(t == "待办" ? "每行会自动变成可勾选项" : "记录类型，用于筛选和归类")
            }
        }
    }

    /// 只有字和图都没有时才算空——否则粘了图还是点不动「添加到墙上」
    private var draftIsEmpty: Bool {
        ui.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ui.draftImage == nil
    }

    /// 六个色块必须垫在一条比纸面更深的轨道里，否则黄色色块和黄色纸面会重合。
    /// 色块是圆角方形而不是圆形：真实的便签纸就是方的，方形色块能被直接读成「一张纸」。
    private var paperTrack: some View {
        HStack(spacing: 0) {
            ForEach(Paper.allCases) { p in
                Button {
                    ui.paper = p
                } label: {
                    PaperSwatch(paper: p, ink: ui.paper.ink,
                                selected: ui.paper == p, side: 17, cell: 24)
                }
                .buttonStyle(.plain).handCursor()
                .help(p.title)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(ui.paper.ink.opacity(0.105))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(ui.paper.ink.opacity(0.07), lineWidth: 1)
                )
        )
    }

    // MARK: 筛选条

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(ContentFilter.allCases) { f in
                Button { store.contentFilter = f } label: {
                    ChipLabel(text: f.title, active: store.contentFilter == f)
                }
                .buttonStyle(.plain).handCursor()
            }

            if let tag = store.tagFilter {
                Button { store.tagFilter = nil } label: {
                    HStack(spacing: 5) {
                        Text("#\(tag)").font(.ui(12))
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(T.accent)
                    .frame(height: 26)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(T.accent.opacity(0.12)))
                }
                .buttonStyle(.plain).handCursor()
            }

            Rectangle()
                .fill(T.line)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 4)

            colorFilter
            timeFilter
            statusFilter

            if store.hasActiveFilters {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { store.clearFilters() }
                } label: {
                    Text("清除")
                        .font(.ui(11))
                        .foregroundStyle(T.textFaint)
                        .frame(height: 26)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain).handCursor()
                .help("清除全部筛选")
            }

            Spacer(minLength: 6)
            sortMenu
        }
        .padding(.top, 18)
    }

    @ViewBuilder
    private var colorFilter: some View {
        let active = !store.paperFilter.isEmpty
        if RenderFlags.snapshot {
            FilterChip(title: store.paperFilter.title, symbol: "paintpalette", active: active)
        } else {
            Button { ui.showColorFilter.toggle() } label: {
                FilterChip(title: store.paperFilter.title, symbol: "paintpalette", active: active)
            }
            .buttonStyle(.plain).handCursor()
            .help("按纸色筛选")
            .popover(isPresented: ui.bind(\.showColorFilter), arrowEdge: .bottom) {
                ColorFilterPanel().environmentObject(store)
            }
        }
    }

    @ViewBuilder
    private var timeFilter: some View {
        let active = store.timeFilter != .any
        if RenderFlags.snapshot {
            FilterChip(title: active ? store.timeFilter.shortTitle : "时间",
                       symbol: "clock", active: active)
        } else {
            Menu {
                ForEach(TimeFilter.allCases) { t in
                    Button {
                        store.timeFilter = t
                    } label: {
                        Label(t.title, systemImage: store.timeFilter == t ? "checkmark" : t.symbol)
                    }
                }
            } label: {
                FilterChip(title: active ? store.timeFilter.shortTitle : "时间",
                           symbol: "clock", active: active)
            }
            .menuStyle(.borderlessButton).handCursor()
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var statusFilter: some View {
        let active = store.statusFilter != .all
        if RenderFlags.snapshot {
            FilterChip(title: active ? store.statusFilter.shortTitle : "状态",
                       symbol: "line.3.horizontal.decrease", active: active)
        } else {
            Menu {
                ForEach(StatusFilter.allCases) { s in
                    Button {
                        store.statusFilter = s
                    } label: {
                        Label(s.title, systemImage: store.statusFilter == s ? "checkmark" : s.symbol)
                    }
                }
            } label: {
                FilterChip(title: active ? store.statusFilter.shortTitle : "状态",
                           symbol: "line.3.horizontal.decrease", active: active)
            }
            .menuStyle(.borderlessButton).handCursor()
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var sortMenu: some View {
        if RenderFlags.snapshot {
            FilterChip(title: store.sortMode.title, symbol: store.sortMode.symbol)
        } else {
            Menu {
                ForEach(SortMode.allCases) { m in
                    Button {
                        store.sortMode = m
                    } label: {
                        Label(m.title, systemImage: store.sortMode == m ? "checkmark" : m.symbol)
                    }
                }
            } label: {
                FilterChip(title: store.sortMode.title, symbol: store.sortMode.symbol)
            }
            .menuStyle(.borderlessButton).handCursor()
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: 瀑布流

    @ViewBuilder
    private var grid: some View {
        let notes = store.visibleNotes
        if notes.isEmpty {
            emptyState
        } else {
            // 默认 3 列：两列时卡片被拉到 ~450pt 宽，太大、不像一面便签墙
            MasonryLayout(preferredColumns: 3, minColumnWidth: 260,
                          wideColumnWidth: 320, maxColumns: 4, gap: 16) {
                ForEach(notes) { note in
                    card(note)
                }
            }
            .padding(.top, 20)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: notes.map(\.id))
        }
    }

    @ViewBuilder
    private func card(_ note: Note) -> some View {
        if RenderFlags.snapshot {
            // 离屏渲染时 onDrop 会画一块黄色占位（截图里是卡片角上的黄边），截图路径不挂
            cardBody(note)
        } else {
            cardBody(note)
                .onDrop(of: [.plainText], delegate: NoteDropDelegate(
                    noteID: note.id,
                    drag: dragState,
                    onDrop: { source, target in drop(source, onto: target) },
                    onMove: { _ in }))
        }
    }

    private func cardBody(_ note: Note) -> some View {
        NoteCard(
            note: note,
            walls: orderedWalls,
            isDragging: dragState.source == note.id,
            onOpen: {
                ui.editing = note
                ui.showDetail = true
            },
            onToggleCheck: { itemID in
                store.toggleCheck(noteID: note.id, itemID: itemID)
            },
            onPin: { withAnimation { store.togglePin(note.id) } },
            onDelete: { delete(note) },
            onLock: { withAnimation { _ = store.lock(note.id) } },
            onUnlock: { unlock(note) },
            onMoveToWall: { moveToWall(note.id, $0) },
            onDragBegin: { dragState.begin(note.id) },
            onToggleEdge: { store.toggleEdgePin(note.id) },
            isEdgePinned: store.isEdgePinned(note.id),
            canLock: store.canLock(note),
            showCheckCount: store.checkCountVisible
        )
        // 卡片高度要从真实布局里量：判断「落在上半还是下半」需要它，
        // 而便签高度完全由内容决定，没有固定值可写
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { dragState.heights[note.id] = proxy.size.height }
                    .onChange(of: proxy.size.height) { h in
                        dragState.heights[note.id] = h
                    }
            }
        )
        .overlay(alignment: .top) { dropLine(note, after: false) }
        .overlay(alignment: .bottom) { dropLine(note, after: true) }
    }

    /// 插入指示线：画在卡片外侧的间隙里，不盖住正文
    @ViewBuilder
    private func dropLine(_ note: Note, after: Bool) -> some View {
        if NoteDrop.side(dragState.target, for: note.id) == after {
            Capsule()
                .fill(T.accent)
                .frame(height: 3)
                .padding(.horizontal, 6)
                .offset(y: after ? 6 : -6)
                .shadow(color: T.accent.opacity(0.45), radius: 3)
                .transition(.opacity)
        }
    }

    private var emptyState: some View {
        let filtered = store.hasActiveFilters || !store.searchText.isEmpty
        return VStack(spacing: 10) {
            Image(systemName: filtered ? "line.3.horizontal.decrease.circle" : "square.on.square.dashed")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(T.textFaint)
            Text(filtered ? "没有符合条件的便签" : "这面墙还是空的")
                .font(.ui(14, .medium))
                .foregroundStyle(T.textDim)
            Text(filtered ? "试试放宽筛选条件" : "按 \(store.hotkeys.newNote.display) 随手记一条，或直接在上面输入")
                .font(.ui(12))
                .foregroundStyle(T.textFaint)
            if store.hasActiveFilters {
                Button("清除筛选") { withAnimation { store.clearFilters() } }
                    .buttonStyle(GhostButtonStyle(height: 26, hPad: 12)).handCursor()
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    // MARK: Toast

    @ViewBuilder
    private var toastBar: some View {
        if let message = toast.message {
            HStack(spacing: 10) {
                Text(message)
                    .font(.ui(12))
                    .foregroundStyle(T.text)
                if let action = toast.actionTitle {
                    Button(action) { toast.runAction() }
                        .buttonStyle(PillButtonStyle(bg: T.insetPressed, fg: T.accent,
                                                     height: 24, hPad: 10)).handCursor()
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, toast.actionTitle == nil ? 14 : 8)
            .frame(height: 38)
            .background(
                Capsule()
                    .fill(T.float)
                    .overlay(Capsule().strokeBorder(T.lineStrong, lineWidth: 0.8))
                    .shadow(color: Color.dyn(0x000000, 0x000000,
                                             lightAlpha: 0.16, darkAlpha: 0.45), radius: 10, y: 4)
            )
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: 动作

    /// 卡片上点「已锁定」→ Touch ID → 解开后直接进详情，省掉一次额外点击。
    /// 解不开时不装死：如果是因为主密钥换了，也要把详情页打开，那里有明确的原因。
    private func unlock(_ note: Note) {
        store.unlock(note.id) { ok in
            guard let fresh = store.notes.first(where: { $0.id == note.id }) else { return }
            guard ok || store.keyStale else { return }
            ui.editing = fresh
            ui.showDetail = true
        }
    }

    private func delete(_ note: Note) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            store.delete(note.id)
        }
        ToastCenter.shared.show("已移到回收站", actionTitle: "撤销") { _ = store.undo() }
    }

    private func moveToWall(_ noteID: UUID, _ wallID: UUID) {
        guard let wall = store.walls.first(where: { $0.id == wallID }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            store.move(noteID, to: wallID)
        }
        ToastCenter.shared.show("已移到「\(wall.name)」", actionTitle: "撤销") { _ = store.undo() }
    }

    private func drop(_ source: UUID, onto target: DropTarget) {
        let wasManual = store.sortMode == .manual
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            store.reorder(source, droppingOn: target)
        }
        // 手动拖过之后要明确告诉用户「排序方式变了」，否则他会以为按时间排序坏了
        if !wasManual {
            ToastCenter.shared.show("已切换为手动排序", actionTitle: "撤销") { _ = store.undo() }
        }
    }

    private func commitDraft() {
        var text = ui.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || ui.draftImage != nil else { return }
        // 选了「待办」：每行自动变成可勾选项，否则这个标签只是个装饰
        if ui.tag == "待办", !text.isEmpty {
            text = Checklist.asTodoList(text)
        }
        var image: NoteImage? = nil
        if let ns = ui.draftImage {
            image = ImageStore.save(ns)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            store.add(text: text, paper: ui.paper, tag: ui.tag, image: image)
        }
        ui.draft = ""
        withAnimation(.easeOut(duration: 0.15)) { ui.draftImage = nil }
    }

    /// 详情页里 ⌘V：把图片贴到当前便签上（已有图就替换，旧文件一并删掉）
    private func attachImageToNote(_ note: Note) {
        guard let img = ImageStore.imageFromPasteboard(),
              let saved = ImageStore.save(img) else {
            ToastCenter.shared.show("剪贴板里没有可用的图片")
            return
        }
        let hadImage = note.image != nil
        var updated = note
        if let old = note.image { ImageStore.delete(old) }
        updated.image = saved
        store.update(updated)
        ui.editing = updated
        ToastCenter.shared.show(hadImage ? "已替换图片" : "已粘贴图片")
    }
}

// MARK: - 颜色筛选面板

struct ColorFilterPanel: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按纸色筛选")
                .font(.ui(11, .medium))
                .foregroundStyle(T.textDim)
            HStack(spacing: 4) {
                ForEach(Paper.allCases) { p in
                    let on = store.paperFilter.papers.contains(p)
                    Button { store.paperFilter.toggle(p) } label: {
                        VStack(spacing: 5) {
                            PaperSwatch(paper: p, ink: T.text, selected: on, side: 22, cell: 30)
                            Text(p.title)
                                .font(.ui(9.5))
                                .foregroundStyle(on ? T.text : T.textFaint)
                        }
                        .frame(width: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).handCursor()
                    .help(p.title)
                }
            }
            if !store.paperFilter.isEmpty {
                Button("清除颜色") { store.paperFilter.papers = [] }
                    .buttonStyle(GhostButtonStyle(height: 22, hPad: 8)).handCursor()
            }
        }
        .padding(14)
        .background(T.float)
    }
}

// MARK: - 键位监听

/// ⌘↩ 保存、⌘⇧↑↓ 翻转排序、⌘Z 撤销。用本地监听而不是 Button 快捷键，
/// 因为焦点在 TextEditor 里时命令菜单收不到按键。
final class KeyMonitor {
    static let shared = KeyMonitor()
    private var monitor: Any?
    private var handlers: [(NSEvent) -> Bool] = []

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            for h in self.handlers where h(event) { return nil }
            return event
        }
    }

    func add(_ handler: @escaping (NSEvent) -> Bool) {
        handlers.append(handler)
    }

    func clear() { handlers.removeAll() }
}
