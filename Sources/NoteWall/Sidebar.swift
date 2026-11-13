import SwiftUI
import AppKit

// MARK: - 左侧边栏（v8）
//
// 品牌头住在侧栏（不在标题栏）：logo + 随手贴 StickySide + 工作区切换。
// 导航是「视图」（全部 / 收藏 / 最近 / 桌面便签 / 回收站），分类是「墙」。
// 三态：展开 216pt → 图标栏 54pt（仅图标，悬停出提示）→ 收起。

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var ui: WallUI

    private var orderedWalls: [Wall] {
        store.walls.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var isRail: Bool { store.sidebarMode == .rail }

    var body: some View {
        if store.sidebarMode == .hidden {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                brandHeader
                Divider().overlay(T.line)
                navSection
                categoriesSection
                Spacer(minLength: 0)
                footerSection
            }
            .padding(.horizontal, isRail ? 7 : 12)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(width: store.sidebarMode.width, alignment: .leading)
            .background(T.sidebar)
            .overlay(alignment: .trailing) {
                Rectangle().fill(T.line).frame(width: 1)
            }
        }
    }

    // MARK: 品牌头

    /// 整个品牌头是一个真实菜单：切墙 + 新建墙。⌄ 不是装饰——
    /// 只有一个工作区还挂个切换箭头，那就是假控件（v7 的教训）。
    private var brandHeader: some View {
        Menu {
            ForEach(orderedWalls) { wall in
                Button(wall.name) { selectWall(wall.id) }
            }
            Divider()
            Button("新建一面墙…") {
                ui.wallNameDraft = ""
                ui.wallDialog = .create
            }
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                if !isRail {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("随手贴")
                            .font(.ui(14.5, .bold))
                            .foregroundStyle(T.text)
                        Text("StickySide")
                            .font(.ui(10.5, .medium))
                            .foregroundStyle(T.textFaint)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(T.textFaint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.bottom, 12)
    }

    // MARK: 导航

    private var navSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            navRow(title: "全部便签", symbol: "square.grid.2x2", count: store.count(for: nil),
                   selected: store.smartView == nil && store.selectedWallID == nil) {
                store.smartView = nil
                store.selectedWallID = nil
            }
            ForEach(SmartView.allCases) { view in
                navRow(title: view.title, symbol: view.symbol,
                       // 桌面便签尚未实现：不给它一个假计数。
                       count: view == .desktop ? nil : store.smartCount(view),
                       selected: store.smartView == view) {
                    store.smartView = view
                    store.selectedWallID = nil
                }
            }
            navRow(title: "回收站", symbol: "trash", count: store.trashedNotes.count,
                   selected: false) {
                ui.showTrash = true
            }
        }
        .padding(.top, 12)
    }

    private func navRow(title: String, symbol: String, count: Int?,
                        selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? T.text : T.textDim)
                    .frame(width: 18)
                if !isRail {
                    Text(title)
                        .font(.ui(13.5, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? T.text : T.textDim)
                    Spacer(minLength: 0)
                    if let count {
                        Text("\(count)")
                            .font(.ui(11.5))
                            .foregroundStyle(T.textFaint)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: isRail ? .center : .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? T.chipActive : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help(title)
    }

    // MARK: 分类（墙）

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !isRail {
                Text("分类")
                    .font(.ui(11, .bold))
                    .foregroundStyle(T.textFaint)
                    .padding(.horizontal, 9)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
            }
            ForEach(orderedWalls) { wall in
                wallRow(wall)
            }
            Button {
                ui.wallNameDraft = ""
                ui.wallDialog = .create
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(T.textFaint)
                        .frame(width: 18)
                    if !isRail {
                        Text("新建分类")
                            .font(.ui(13.5))
                            .foregroundStyle(T.textFaint)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: isRail ? .center : .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("新建一面墙")
        }
    }

    private func wallRow(_ wall: Wall) -> some View {
        let selected = store.smartView == nil && store.selectedWallID == wall.id
        return Button { selectWall(wall.id) } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(wall.color.paper)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(T.line, lineWidth: 0.8))
                    .frame(width: 18)
                if !isRail {
                    Text(wall.name)
                        .font(.ui(13.5, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? T.text : T.textDim)
                    Spacer(minLength: 0)
                    Text("\(store.count(for: wall.id))")
                        .font(.ui(11.5))
                        .foregroundStyle(T.textFaint)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: isRail ? .center : .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? T.chipActive : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help("\(wall.name) · 右键可重命名、换色、排序")
        .contextMenu { wallMenu(wall) }
    }

    private func selectWall(_ id: UUID?) {
        store.smartView = nil
        store.selectedWallID = id
    }

    /// 墙的右键菜单。重命名 / 删除走 ui.wallDialog，确认框挂在 WallContent 根上；
    /// 换色 / 排序直接调 store。
    @ViewBuilder
    private func wallMenu(_ wall: Wall) -> some View {
        let index = orderedWalls.firstIndex(where: { $0.id == wall.id }) ?? 0
        Button("重命名…") {
            ui.wallNameDraft = wall.name
            ui.wallDialog = .rename(wall)
        }
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
        Button("删除墙…", role: .destructive) { ui.wallDialog = .delete(wall) }
            .disabled(store.walls.count <= 1)
    }

    // MARK: 页脚

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().overlay(T.line)
            Button { ui.showSettings = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(T.textDim)
                        .frame(width: 18)
                    if !isRail {
                        Text("设置")
                            .font(.ui(13.5))
                            .foregroundStyle(T.textDim)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: isRail ? .center : .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("设置")
        }
        .padding(.top, 10)
    }
}
