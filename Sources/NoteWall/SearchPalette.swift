import SwiftUI
import AppKit

// MARK: - 全局搜索浮层（v8，⌘K / ⌘F）
//
// 居中面板 + 实时结果。输入直接写 store.searchText，所以身后的墙会跟着筛——
// 浮层与墙内搜索是同一套规则（SearchQuery.matches），不会两处打架。
// 空查询时列最近动过的 8 张；选一条打开详情时清空搜索并关闭；Esc 同样清空并关闭。
//
// ↑↓/⏎/Esc 用本地事件监听实现：TextField 自己的方向键只会移动光标，
// 选不中结果行。监听在浮层出现时装、消失时拆，只吞这四个键，其余原样放行。

struct SearchPalette: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var ui: WallUI

    @FocusState private var fieldFocused: Bool
    @State private var monitor: Any? = nil

    private var results: [Note] { Self.computeResults(store: store) }

    private var queryIsEmpty: Bool { SearchQuery.parse(store.searchText).isEmpty }

    private static func computeResults(store: AppStore) -> [Note] {
        let pool = store.notes.filter { $0.deletedAt == nil }
        let q = SearchQuery.parse(store.searchText)
        if q.isEmpty {
            return Array(pool.sorted { $0.updatedAt > $1.updatedAt }.prefix(8))
        }
        return Array(pool.filter { SearchQuery.matches($0, query: q, walls: store.walls) }.prefix(8))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }
            panel
                .frame(width: 560)
                .padding(.top, 64)
        }
        .onAppear {
            installKeys()
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onDisappear { removeKeys() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            inputRow
            Divider().overlay(T.line)
            resultsArea
            Divider().overlay(T.line)
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(T.float)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        )
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.icon(14))
                .foregroundStyle(T.textFaint)
            if RenderFlags.snapshot {
                Text(store.searchText.isEmpty ? "搜索便签、标签、墙…" : store.searchText)
                    .font(.ui(15))
                    .foregroundStyle(store.searchText.isEmpty ? T.textFaint : T.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: store.bind(\.searchText),
                          prompt: Text("搜索便签、标签、墙…").foregroundStyle(T.textFaint))
                    .textFieldStyle(.plain)
                    .font(.ui(15))
                    .foregroundStyle(T.text)
                    .focused($fieldFocused)
                    .onChange(of: store.searchText) { _ in ui.searchSelection = 0 }
            }
            Button { close() } label: {
                Text("esc")
                    .font(.ui(T.captionSize, .medium))
                    .foregroundStyle(T.textFaint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(T.inset))
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var resultsArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(queryIsEmpty ? "最近" : "搜索结果")
                .font(.ui(T.metaSize, .medium))
                .foregroundStyle(T.textFaint)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            if results.isEmpty {
                Text(queryIsEmpty ? "还没有便签" : "没有找到相关便签")
                    .font(.ui(13))
                    .foregroundStyle(T.textFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { idx, note in
                    resultRow(note, selected: idx == clampedSelection)
                        .onTapGesture { open(note) }
                        .onHover { if $0 { ui.searchSelection = idx } }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    /// 选中行要夹在结果范围内：结果集一缩，旧下标可能越界。
    private var clampedSelection: Int {
        guard !results.isEmpty else { return 0 }
        return min(max(ui.searchSelection, 0), results.count - 1)
    }

    private func resultRow(_ note: Note, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(note.paper.paper)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(T.line, lineWidth: 0.8))
            VStack(alignment: .leading, spacing: 1) {
                Text(note.isLocked ? "已锁定的便签" : firstLine(note))
                    .font(.ui(13.5, selected ? .medium : .regular))
                    .foregroundStyle(T.text)
                    .lineLimit(1)
                Text("\(wallName(note)) · \(TimeLabel.card(note.createdAt))")
                    .font(.ui(T.metaSize))
                    .foregroundStyle(T.textFaint)
            }
            Spacer(minLength: 0)
            if note.isLocked {
                Image(systemName: "lock.fill")
                    .font(.icon(10))
                    .foregroundStyle(T.textFaint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? T.chipActive : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("↑↓ 选择").font(.ui(T.metaSize)).foregroundStyle(T.textFaint)
            Text("⏎ 打开").font(.ui(T.metaSize)).foregroundStyle(T.textFaint)
            Text("Esc 关闭").font(.ui(T.metaSize)).foregroundStyle(T.textFaint)
            Spacer()
            Text("支持 #标签 · 墙:名字 · 有图 · 锁:").font(.ui(T.metaSize)).foregroundStyle(T.textFaint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func firstLine(_ note: Note) -> String {
        let line = note.text.components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        if !line.isEmpty { return line }
        if note.image != nil { return "图片便签" }
        return "空便签"
    }

    private func wallName(_ note: Note) -> String {
        store.walls.first(where: { $0.id == note.wallID })?.name ?? ""
    }

    // MARK: 打开 / 关闭

    private func open(_ note: Note) {
        Self.openNote(note, store: store, ui: ui)
    }

    private func close() {
        Self.closePalette(store: store, ui: ui)
    }

    private static func openNote(_ note: Note, store: AppStore, ui: WallUI) {
        closePalette(store: store, ui: ui)
        if note.isLocked {
            // 锁着的便签走解锁流程，不直接打开一个空详情页（与卡片点一下的行为一致）。
            store.unlock(note.id) { ok in
                guard let fresh = store.notes.first(where: { $0.id == note.id }) else { return }
                guard ok || store.keyStale else { return }
                ui.editing = fresh
                ui.showDetail = true
            }
            return
        }
        ui.editing = note
        ui.showDetail = true
    }

    private static func closePalette(store: AppStore, ui: WallUI) {
        store.searchText = ""
        ui.searchSelection = 0
        ui.showSearch = false
    }

    // MARK: 键盘

    private func installKeys() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak ui, weak store] event in
            guard let ui, let store, ui.showSearch else { return event }
            let results = Self.computeResults(store: store)
            switch event.keyCode {
            case 126: // ↑
                if !results.isEmpty {
                    ui.searchSelection = max(ui.searchSelection - 1, 0)
                }
                return nil
            case 125: // ↓
                if !results.isEmpty {
                    ui.searchSelection = min(ui.searchSelection + 1, results.count - 1)
                }
                return nil
            case 36: // ⏎
                guard !results.isEmpty else { return event }
                let idx = min(max(ui.searchSelection, 0), results.count - 1)
                Self.openNote(results[idx], store: store, ui: ui)
                return nil
            case 53: // Esc
                Self.closePalette(store: store, ui: ui)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeys() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}
