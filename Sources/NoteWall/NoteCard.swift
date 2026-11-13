import SwiftUI
import AppKit

// MARK: - 缩略图缓存

@MainActor
final class ThumbCache {
    static let shared = ThumbCache()
    private var cache: [String: NSImage] = [:]

    func image(_ image: NoteImage) -> NSImage? {
        if let hit = cache[image.thumbName] { return hit }
        guard let img = ImageStore.load(image.thumbName, thumb: true) else { return nil }
        cache[image.thumbName] = img
        return img
    }

    func full(_ image: NoteImage) -> NSImage? {
        NSImage(contentsOf: ImageStore.url(image.fileName, thumb: false))
    }

    /// 锁定/删除时清掉内存里的明文缩略图——图片文件加密了，缓存里还留着明图等于没锁。
    func evict(_ image: NoteImage?) {
        guard let image else { return }
        cache.removeValue(forKey: image.thumbName)
    }
}

// MARK: - 便签主体

/// 一张便签的"内容区"，卡片和详情页共用，保证两处看起来是同一张纸。
struct NoteBody: View {
    let note: Note
    var fontScale: CGFloat = 1
    var lineLimit: Int? = 6
    var onToggleCheck: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    Text(s)
                        .font(.ui(15 * fontScale))
                        .foregroundStyle(note.paper.ink)
                        .lineSpacing(4)
                        .lineLimit(lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .checks(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            CheckRow(item: item, paper: note.paper, scale: fontScale) {
                                onToggleCheck?(item.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private enum Block {
        case text(String)
        case checks([Checklist.Item])
    }

    /// 把正文切成「文字段 / 清单段」，保持原有顺序
    private var blocks: [Block] {
        var out: [Block] = []
        var textBuffer: [String] = []
        var checkBuffer: [Checklist.Item] = []
        let allItems = Checklist.parse(note.text)
        var itemCursor = 0

        func flushText() {
            if !textBuffer.isEmpty {
                out.append(.text(textBuffer.joined(separator: "\n")))
                textBuffer.removeAll()
            }
        }
        func flushChecks() {
            if !checkBuffer.isEmpty {
                out.append(.checks(checkBuffer))
                checkBuffer.removeAll()
            }
        }

        for line in note.text.components(separatedBy: "\n") {
            if Checklist.split(line) != nil {
                flushText()
                if itemCursor < allItems.count {
                    checkBuffer.append(allItems[itemCursor])
                    itemCursor += 1
                }
            } else {
                flushChecks()
                textBuffer.append(line)
            }
        }
        flushText()
        flushChecks()
        return out
    }
}

struct CheckRow: View {
    let item: Checklist.Item
    let paper: Paper
    var scale: CGFloat = 1
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(item.done ? paper.ink.opacity(0.75) : paper.ink.opacity(0.35), lineWidth: 1.3)
                        .frame(width: 13, height: 13)
                    if item.done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(paper.ink.opacity(0.75))
                    }
                }
                .padding(.top, 2)

                Text(item.text)
                    .font(.ui(14 * scale))
                    .foregroundStyle(paper.ink.opacity(item.done ? 0.42 : 1))
                    .strikethrough(item.done, color: paper.ink.opacity(0.4))
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }
}

// MARK: - 卡片

struct NoteCard: View {
    let note: Note
    /// 换墙菜单要列出所有墙；空数组时不显示这一项（快照/预览场景）
    var walls: [Wall] = []
    var isDragging: Bool = false
    /// 离屏渲染用：没有鼠标，hover 永远是 false，菜单按钮就永远看不到
    var hoverPreview: Bool = false
    var onOpen: () -> Void = {}
    var onToggleCheck: (Int) -> Void = { _ in }
    var onPin: () -> Void = {}
    var onDelete: () -> Void = {}
    var onLock: () -> Void = {}
    var onUnlock: () -> Void = {}
    var onMoveToWall: (UUID) -> Void = { _ in }
    var onDragBegin: () -> Void = {}
    var onToggleEdge: () -> Void = {}
    var isEdgePinned: Bool = false
    var canLock: Bool = true
    var showCheckCount: Bool = true
    /// 墙上微转（按 id 哈希恒定角度）。紧凑行 / 边缘 / 刘海不转。
    var tilt: Bool = true
    /// 整齐模式：关掉旋转、胶带与折角。
    var neat: Bool = false
    /// 刚贴上的那张：从 -6° 落下来一次。
    var isNew: Bool = false
    /// 列表视图的紧凑行：横排、无旋转、无胶带。
    var compact: Bool = false
    var onFavorite: () -> Void = {}

    @StateObject private var hover = UIBox(false)
    /// 指针停在「⋯」上时不触发卡片的单击（否则点菜单会连带打开详情页）
    @StateObject private var menuHover = UIBox(false)
    /// 落下动画跑完的标记：只在挂载那一刻动画一次，滚动回来不重播。
    @State private var appeared = false
    private var hovering: Bool { hoverPreview || hover.value }

    /// 同一张便签的角度恒定：用 id 的确定性哈希映射到 -2.4°~+2.4°。
    /// 不能用 hashValue——Swift 的 Hasher 每次启动换种子，重启后整墙角度会重排。
    private var tiltAngle: Double {
        guard tilt, !neat, !compact else { return 0 }
        let h = note.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let m = (h % 49 + 49) % 49
        return Double(m) / 10.0 - 2.4
    }

    /// 悬停回正、平时微转；刚贴上的那张从 -6° 落下来。
    private var displayAngle: Double {
        if isNew && !appeared { return -6 }
        if hovering { return 0 }
        return tiltAngle
    }

    /// 卡片左上角的类型：文字 / 清单 / 图片 / 锁定，一眼认出这张纸是什么。
    private var typeSymbol: String {
        if note.isLocked { return "lock.fill" }
        if note.image != nil { return "photo" }
        if note.isChecklist { return "checklist" }
        return "doc.text"
    }

    private var firstLine: String {
        if note.isLocked { return "已锁定的便签" }
        let line = note.text.components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        if !line.isEmpty { return line }
        if note.image != nil { return "图片便签" }
        return "空便签"
    }

    var body: some View {
        if compact {
            compactRow
        } else {
            cardBody
        }
    }

    // MARK: - 卡片（墙）

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
            foot
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: T.rCard, style: .continuous)
                .fill(note.paper.paper)
                // 浅色底上阴影要轻，重了整页发灰；深色底反过来，纸要浮起来
                .shadow(color: Color.dyn(0x000000, 0x000000,
                                         lightAlpha: hovering ? 0.16 : 0.10,
                                         darkAlpha: hovering ? 0.40 : 0.30),
                        radius: hovering ? 14 : 10, x: 0, y: hovering ? 7 : 5)
        )
        .overlay(
            // 顶部受光：纸的上缘亮、下缘暗，135° 光源。整齐模式也留着——它只是光，不是装饰。
            RoundedRectangle(cornerRadius: T.rCard, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.04)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: T.rCard, style: .continuous)
                .strokeBorder(T.cardEdge, lineWidth: 0.8)
                .blendMode(.overlay)
        )
        .overlay(alignment: .top) { tapeOverlay }
        .overlay(alignment: .bottomTrailing) { foldOverlay }
        .overlay(alignment: .topTrailing) {
            if hovering && !note.isLocked { menuButton }
        }
        .offset(y: (isNew && !appeared) ? -16 : (hovering ? -1.5 : 0))
        .rotationEffect(.degrees(displayAngle))
        // 正在拖的那张要明显「被拿起来」：留个半透明影子在原地，用户才知道自己在搬什么
        .opacity((isNew && !appeared) ? 0 : (isDragging ? 0.4 : 1))
        .scaleEffect(isDragging ? 0.985 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.8), value: hovering)
        .animation(.easeOut(duration: 0.16), value: isDragging)
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .onDrag {
            onDragBegin()
            return NoteDragPayload.provider(for: note.id)
        }
        .handCursor()
        .onTapGesture {
            guard !menuHover.value else { return }
            // 锁着的便签点一下就是「解锁」，不是打开一个空的详情页
            if note.isLocked { onUnlock() } else { onOpen() }
        }
        .contextMenu { actions }
        .onAppear {
            if isNew && !RenderFlags.snapshot && !neat {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { appeared = true }
            } else {
                appeared = true
            }
        }
    }

    /// 置顶的视觉语言是胶带：把纸贴在墙上的动作本身（0.3.0 scope 定，替代旧版的 ▲）。
    /// 两端撕开：mask 在左右各留一道透明渐变。
    @ViewBuilder
    private var tapeOverlay: some View {
        if note.isPinned && !compact && !neat {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xFFF6BE).opacity(0.92),
                                              Color(hex: 0xFAE896).opacity(0.82)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 86, height: 22)
                .rotationEffect(.degrees(-2))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .mask(LinearGradient(colors: [.clear, .black, .black, .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .offset(y: -11)
        }
    }

    /// 右下折角：纸的厚度。整齐模式与紧凑行不画。
    /// 折角要顺着卡片的圆角走：把 18pt 的小块按卡片圆角裁一下，否则方角会戳出圆角外面。
    @ViewBuilder
    private var foldOverlay: some View {
        if !compact && !neat {
            FoldShape()
                .fill(.white.opacity(0.45))
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: T.rCard, style: .continuous))
        }
    }

    /// 直角三角形：斜边朝左上，直角贴着卡片右下角。
    private struct FoldShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }

    // MARK: - 紧凑行（列表视图）

    /// 列表视图的横排：类型图标 + 首行 + 标签 + 清单进度 + 时间。
    /// 旋转、胶带、折角、阴影、拖拽都不进列表——列表是用来扫的，不是用来看纸的。
    private var compactRow: some View {
        HStack(spacing: 10) {
            Image(systemName: typeSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(note.paper.ink.opacity(0.6))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(firstLine)
                    .font(.ui(13.5, .medium))
                    .foregroundStyle(note.paper.ink)
                    .lineLimit(1)
                if !note.tag.isEmpty {
                    Text(note.tag)
                        .font(.ui(11))
                        .foregroundStyle(note.paper.ink.opacity(0.5))
                }
            }
            Spacer(minLength: 8)
            if note.isChecklist {
                let p = note.checklistProgress
                Text("\(p.done)/\(p.total)")
                    .font(.ui(11))
                    .foregroundStyle(note.paper.ink.opacity(0.5))
            }
            if note.isPinned {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(note.paper.ink.opacity(0.45))
            }
            if note.favorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color(hex: 0xB8860B).opacity(0.85))
            }
            Text(TimeLabel.card(note.createdAt))
                .font(.ui(11))
                .foregroundStyle(note.paper.ink.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(note.paper.paper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(T.cardEdge, lineWidth: 0.8)
        )
        .contentShape(Rectangle())
        .handCursor()
        .onTapGesture {
            if note.isLocked { onUnlock() } else { onOpen() }
        }
        .contextMenu { actions }
    }

    private var header: some View {
        HStack(spacing: 6) {
            // 类型一眼认出：文字 / 清单 / 图片 / 锁定。v8 富卡片。
            Image(systemName: typeSymbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(note.paper.ink.opacity(0.55))
            if !note.tag.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(note.paper.ink.opacity(0.28)).frame(width: 4, height: 4)
                    Text(note.tag).font(.ui(10.5, .medium))
                }
                .foregroundStyle(note.paper.ink.opacity(0.55))
            }
            if note.isPinned && compact {
                // 墙上置顶用胶带（0.3.0 scope）；紧凑行没有胶带，▲ 是唯一的置顶信号。
                // PRD §2.5：置顶标识用 ▲，不用图钉意象。
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(note.paper.ink.opacity(0.45))
            }
            if note.favorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color(hex: 0xB8860B).opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 13)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if note.isLocked {
            lockedBody
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let img = note.image, let ns = ThumbCache.shared.image(img) {
                    let aspect = CGFloat(img.pixelWidth) / max(1, CGFloat(img.pixelHeight))
                    Image(nsImage: ns)
                        .resizable()
                        // 3 列后列宽只剩 ~292pt：原来「固定高度 + fill」会把横幅图两端裁掉
                        // （实测右端标记整块消失）。改成按列宽等比缩放，整张图完整显示，
                        // 竖图最多占 200pt 高，不至于把卡片顶穿。
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 200, alignment: .top)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.8)
                        )
                }
                if !note.text.isEmpty {
                    NoteBody(note: note, onToggleCheck: onToggleCheck)
                }
            }
        }
    }

    private var lockedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这里有一段被锁住的内容")
                .font(.ui(15))
                .foregroundStyle(note.paper.ink.opacity(0.55))
                .blur(radius: 3.2)
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 9))
                Text("已锁定 · 点击解锁").font(.ui(11.5, .medium))
            }
            .foregroundStyle(note.paper.ink.opacity(hovering ? 0.85 : 0.6))
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Capsule().fill(note.paper.ink.opacity(hovering ? 0.13 : 0.08)))
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var foot: some View {
        HStack(spacing: 8) {
            Text(TimeLabel.card(note.createdAt))
                .font(.ui(10.5))
                .foregroundStyle(note.paper.ink.opacity(0.34))
                .help(TimeLabel.full(note.createdAt))
            Spacer(minLength: 0)
            if showCheckCount, note.isChecklist {
                let p = note.checklistProgress
                Text("\(p.done)/\(p.total)")
                    .font(.ui(10.5))
                    .foregroundStyle(note.paper.ink.opacity(0.34))
            }
        }
        .padding(.top, 10)
    }

    /// 悬停才出现的「⋯」。一个入口装下所有操作，比在卡片角上排三四个图标更稳：
    /// 便签高度不固定，图标一多就容易压到正文，也会把「纸」的感觉破坏掉。
    @ViewBuilder
    private var menuButton: some View {
        if RenderFlags.snapshot {
            menuLabel
        } else {
            Menu { actions } label: { menuLabel }
                .menuStyle(.borderlessButton).handCursor()
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }

    private var menuLabel: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(note.paper.ink.opacity(0.58))
            .frame(width: 22, height: 22)
            .background(Circle().fill(note.paper.ink.opacity(0.085)))
            .contentShape(Circle())
            .padding(9)
            .onHover { menuHover.value = $0 }
            .help("更多操作")
    }

    /// 悬停菜单与右键菜单共用同一份定义：两处内容一旦分叉，用户点右键会发现少了功能
    @ViewBuilder
    private var actions: some View {
        Button("打开", action: onOpen)
        Button(note.isPinned ? "取消置顶" : "置顶", action: onPin)
        Button(note.favorite ? "取消收藏" : "收藏", action: onFavorite)
        // 锁定的便签不给这个入口：边缘条是「路过就能看到」的地方，安全规则比主窗口更严
        if !note.isLocked {
            Button(isEdgePinned ? "从屏幕边缘移除" : "钉到屏幕边缘", action: onToggleEdge)
        }
        if walls.count > 1 {
            Menu("移动到墙") {
                ForEach(walls) { w in
                    Button(w.name) { onMoveToWall(w.id) }
                        .disabled(w.id == note.wallID)
                }
            }
        }
        Divider()
        if note.isLocked {
            Button("解锁…", action: onUnlock)
        } else if note.hasContent {
            Button("锁定…", action: onLock).disabled(!canLock)
        }
        Button("复制便签") {
            let r = NoteCopy.copy(note)
            if r != .nothing { ToastCenter.shared.show(r.toast) }
        }
            .disabled(note.isLocked || !note.hasContent)
        Divider()
        Button("删除", role: .destructive, action: onDelete)
    }

}
