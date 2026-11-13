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
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .text(let s):
                    titleBodyText(s, isFirst: index == 0)
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

    /// 首个文字段的首行是标题（17 semibold），其余正文 14.5；后续文字段全是正文。
    /// 用 Text 拼接混排，仍是一个 Text，lineLimit/lineSpacing 照常生效。
    private func titleBodyText(_ s: String, isFirst: Bool) -> Text {
        guard isFirst else { return Text(s).font(.ui(14.5 * fontScale)) }
        let lines = s.components(separatedBy: "\n")
        guard let first = lines.first, !first.isEmpty else {
            return Text(s).font(.ui(14.5 * fontScale))
        }
        let rest = lines.dropFirst().joined(separator: "\n")
        var t = Text(first).font(.ui(17 * fontScale, .semibold))
        if !rest.isEmpty { t = t + Text("\n" + rest).font(.ui(14.5 * fontScale)) }
        return t
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
    /// 整齐模式：不转、间距拉开（折角与图钉保留）。默认整齐，与参考图一致。
    var neat: Bool = true
    /// 刚贴上的那张：从 -2° 落下来一次。
    var isNew: Bool = false
    /// 列表视图的紧凑行：横排、无旋转、无图钉。
    var compact: Bool = false
    var onFavorite: () -> Void = {}

    @StateObject private var hover = UIBox(false)
    /// 指针停在「⋯」上时不触发卡片的单击（否则点菜单会连带打开详情页）
    @StateObject private var menuHover = UIBox(false)
    /// 落下动画跑完的标记：只在挂载那一刻动画一次，滚动回来不重播。
    @State private var appeared = false
    private var hovering: Bool { hoverPreview || hover.value }

    /// 同一张便签的角度恒定：用 id 的确定性哈希映射到 -1.2°~+1.2°。
    /// 不能用 hashValue——Swift 的 Hasher 每次启动换种子，重启后整墙角度会重排。
    /// 角度取边缘条的量级：边缘签 [3, -2.2, 2.4, -3]° 看着舒服是因为签窄（~30pt），
    /// 墙上卡片宽 ~300pt，同样角度角落要摆 16pt；±1.2° 只摆 4–6pt，微微即可。
    private var tiltAngle: Double {
        guard tilt, !neat, !compact else { return 0 }
        let h = note.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let m = (h % 25 + 25) % 25
        return Double(m) / 10.0 - 1.2
    }

    /// 悬停回正、平时微转；刚贴上的那张从 -2° 落下来。
    private var displayAngle: Double {
        if isNew && !appeared { return -2 }
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
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: T.rCard, style: .continuous)
                .fill(note.paper.paper)
                // 浅色底上阴影要轻，重了整页发灰；深色底反过来，纸要浮起来
                .shadow(color: Color.dyn(0x000000, 0x000000,
                                         lightAlpha: hovering ? 0.16 : 0.12,
                                         darkAlpha: hovering ? 0.40 : 0.30),
                        radius: hovering ? 18 : 14, x: 0, y: hovering ? 8 : 6)
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
        .overlay(alignment: .topTrailing) { pinOverlay }
        .overlay(alignment: .topTrailing) { cornerCluster }
        .offset(y: (isNew && !appeared) ? -16 : (hovering ? -1.5 : 0))
        // 旋转轴钉在顶边：卡片像从顶部钉子处垂下来摆，而不是绕中心转。
        .rotationEffect(.degrees(displayAngle), anchor: .top)
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

    /// 置顶的视觉语言是图钉（0.3.1，替代 0.3.0 的胶带：胶带占地方、不好看）。
    /// 钉在右上角、半出角，顺时针转 28°；卡片旋转时图钉跟着转，它就是支点。
    @ViewBuilder
    private var pinOverlay: some View {
        if note.isPinned && !compact {
            Image(systemName: "pin.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(hex: 0xB45309))
                .rotationEffect(.degrees(28))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .offset(x: 8, y: -8)
        }
    }

    // MARK: - 紧凑行（列表视图）

    /// 列表视图的横排：类型图标 + 首行 + 标签 + 清单进度 + 时间。
    /// 旋转、图钉、折角、阴影、拖拽都不进列表——列表是用来扫的，不是用来看纸的。
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
                // 墙上置顶用图钉（0.3.1）；紧凑行没有图钉，▲ 是唯一的置顶信号。
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(note.paper.ink.opacity(0.45))
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

    /// 右上角：收藏星常驻 + 悬停「⋯」。图钉钉在角外（pinOverlay），三者不重叠。
    private var cornerCluster: some View {
        HStack(spacing: 8) {
            if note.favorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0xB8860B).opacity(0.9))
            }
            if hovering && !note.isLocked { menuButton }
        }
        .padding(.top, 10)
        .padding(.trailing, 10)
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
