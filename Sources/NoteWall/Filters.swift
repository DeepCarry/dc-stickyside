import Foundation

// MARK: - 筛选维度（PRD §2.6）
//
// 三个维度彼此独立、可叠加：颜色 × 时间 × 状态。原来的「内容类型」筛选是同层的第四个，
// 保留在筛选条最左侧常驻（它是最常用的那个），其余三个收成紧凑控件，避免顶栏塞满。

/// 时间筛选按**创建时间**算：便签像纸，时间戳是它被贴上墙的那一刻，
/// 不是最后一次改字的时间——否则「今天」会不断收进旧便签。
enum TimeFilter: String, Codable, CaseIterable, Identifiable {
    case any, today, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "全部时间"
        case .today: return "今天"
        case .week: return "最近 7 天"
        case .month: return "最近 30 天"
        }
    }

    var shortTitle: String {
        switch self {
        case .any: return "时间"
        case .today: return "今天"
        case .week: return "7 天"
        case .month: return "30 天"
        }
    }

    var symbol: String {
        switch self {
        case .any: return "clock"
        case .today: return "sun.max"
        case .week: return "calendar"
        case .month: return "calendar.circle"
        }
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .any:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .week:
            return date >= calendar.startOfDay(for: now.addingTimeInterval(-6 * 86400))
        case .month:
            return date >= calendar.startOfDay(for: now.addingTimeInterval(-29 * 86400))
        }
    }
}

enum StatusFilter: String, Codable, CaseIterable, Identifiable {
    case all, todo, locked, unlocked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部状态"
        case .todo: return "未完成的清单"
        case .locked: return "只看锁定的"
        case .unlocked: return "隐藏锁定的"
        }
    }

    var shortTitle: String {
        switch self {
        case .all: return "状态"
        case .todo: return "未完成"
        case .locked: return "已锁定"
        case .unlocked: return "不含锁定"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "line.3.horizontal.decrease"
        case .todo: return "checklist"
        case .locked: return "lock"
        case .unlocked: return "lock.open"
        }
    }

    /// 锁定便签读不到正文，所以永远不算「未完成」——把它当成已完成处理，
    /// 而不是按「看不到就当没做完」硬塞进结果里（那会让人以为锁坏了）。
    func matches(_ note: Note) -> Bool {
        switch self {
        case .all:
            return true
        case .todo:
            guard !note.isLocked else { return false }
            let items = Checklist.parse(note.text)
            return items.contains { !$0.done }
        case .locked:
            return note.isLocked
        case .unlocked:
            return !note.isLocked
        }
    }
}

/// 颜色筛选是多选：想同时看黄色和粉色是常见需求，单选会逼人来回切。
/// 空集合 = 不筛颜色（而不是「什么都不显示」）。
struct PaperFilter: Equatable {
    var papers: Set<Paper> = []

    var isEmpty: Bool { papers.isEmpty }

    func matches(_ note: Note) -> Bool {
        papers.isEmpty || papers.contains(note.paper)
    }

    mutating func toggle(_ paper: Paper) {
        if papers.contains(paper) { papers.remove(paper) } else { papers.insert(paper) }
    }

    var title: String {
        if papers.isEmpty { return "颜色" }
        if papers.count == 1, let p = papers.first { return p.title }
        return "\(papers.count) 种颜色"
    }
}
