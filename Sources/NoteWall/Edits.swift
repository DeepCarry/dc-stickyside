import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 撤销
//
// 不用 NSUndoManager：它按 First Responder 找 target，而便签墙的焦点几乎总在
// TextEditor 里，⌘Z 会被文本编辑抢走；而且我们要在 Toast 上显示「刚刚做了什么」，
// 需要一条自己的、带标题的历史。栈只保留结构操作，最多 30 步。

struct UndoStep {
    /// 给用户看的一句话，例如「删除便签」
    let title: String
    let undo: () -> Void
    let redo: () -> Void
}

// MARK: - 轻提示

/// 屏幕底部的临时提示。删除这类「做错了才知道」的操作必须给一次后悔入口，
/// 而不是弹一个必须点确定的对话框去打断人。
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var message: String? = nil
    @Published private(set) var actionTitle: String? = nil

    private var action: (() -> Void)? = nil
    private var dismiss: DispatchWorkItem?

    func show(_ text: String,
              actionTitle: String? = nil,
              action: (() -> Void)? = nil,
              seconds: TimeInterval = 3.4) {
        message = text
        self.actionTitle = actionTitle
        self.action = action
        // 新提示顶掉旧的，并重新计时：连着删三条不该只剩最后一条的计时
        dismiss?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        dismiss = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func runAction() {
        let work = action
        hide()
        work?()
    }

    func hide() {
        dismiss?.cancel()
        dismiss = nil
        action = nil
        actionTitle = nil
        message = nil
    }
}

// MARK: - 拖拽

/// 拖拽落点。墙用 UUID?（nil = 全部，但全部不是真实墙，不能当落点，仅作标识）。
enum DropTarget: Equatable {
    case note(UUID, after: Bool)
    case wall(UUID)
}

/// 一次拖拽过程中的共享状态。不放在 store 里：它是纯 UI 瞬时状态，
/// 不该跟着存档走，也不该让 store 的 @Published 连锁刷新整个网格。
@MainActor
final class DragState: ObservableObject {
    @Published var source: UUID? = nil
    @Published var target: DropTarget? = nil

    /// 卡片高度缓存：判断落在上半还是下半需要它，拖拽开始时由卡片自己上报
    var heights: [UUID: CGFloat] = [:]

    var isDragging: Bool { source != nil }

    func begin(_ id: UUID) {
        source = id
        target = nil
    }

    func end() {
        source = nil
        target = nil
    }
}

// MARK: - 落点计算

enum NoteDrop {
    /// 卡片自身的落点判断：上半 → 插到它前面，下半 → 插到它后面。
    /// 用 0.55 而不是 0.5：卡片底部常有一行时间戳，视觉上那一条更像是「放在它后面」。
    static func target(for id: UUID, locationY: CGFloat, height: CGFloat) -> DropTarget {
        let h = max(height, 1)
        return .note(id, after: locationY > h * 0.55)
    }

    /// 进度条画在哪一侧
    static func side(_ target: DropTarget?, for id: UUID) -> Bool? {
        guard case let .note(tid, after) = target, tid == id else { return nil }
        return after
    }
}

// MARK: - 卡片拖拽

/// 卡片既是拖拽源也是落点。
/// `onDrag` 只给 NSItemProvider；方向判断发生在 DropDelegate 里，那里才有局部坐标。
enum NoteDragPayload {
    static func provider(for id: UUID) -> NSItemProvider {
        NSItemProvider(object: id.uuidString as NSString)
    }
}

/// DropDelegate 的协议方法在 SDK 里没有标 @MainActor，但从 SwiftUI 调过来时
/// 一定在主线程上（拖拽事件就是主线程事件）。所以这里不标 @MainActor（否则
/// 满足不了协议），改用 assumeIsolated 进入主线程上下文，和工程里其他
/// AppKit 回调的处理方式一致。
struct NoteDropDelegate: DropDelegate {
    let noteID: UUID
    let drag: DragState
    let onDrop: (UUID, DropTarget) -> Void
    let onMove: (DropTarget?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let source = drag.source else { return false }
            return source != noteID
        }
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { update(info) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated { update(info) }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            // 只在离开的就是自己时才清，否则会把下一张刚点亮的指示线擦掉
            if case let .note(id, _)? = drag.target, id == noteID {
                drag.target = nil
                onMove(nil)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let source = drag.source,
                  let target = drag.target,
                  case let .note(id, _) = target, id == noteID else { return false }
            onDrop(source, target)
            drag.end()
            onMove(nil)
            return true
        }
    }

    @MainActor
    private func update(_ info: DropInfo) {
        guard drag.source != nil else { return }
        let h = drag.heights[noteID] ?? 200
        let t = NoteDrop.target(for: noteID, locationY: info.location.y, height: h)
        if drag.target != t {
            drag.target = t
            onMove(t)
        }
    }
}

// MARK: - 墙 tab 拖拽

/// 把便签拖到墙 tab 上 = 换墙。跨墙挪动只有这一个入口：
/// 网格里只显示当前墙的卡片，想「拖到看不见的墙」不可能靠卡片落点完成。
struct WallDropDelegate: DropDelegate {
    let wallID: UUID?
    let drag: DragState
    let onDrop: (UUID, UUID) -> Void
    let onHover: (Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard wallID != nil, let source = drag.source else { return false }
            return true
        }
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let wallID else { return }
            drag.target = .wall(wallID)
            onHover(true)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            if case let .wall(id)? = drag.target, id == wallID {
                drag.target = nil
            }
            onHover(false)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let wallID, let source = drag.source else { return false }
            onDrop(source, wallID)
            drag.end()
            onHover(false)
            return true
        }
    }
}
