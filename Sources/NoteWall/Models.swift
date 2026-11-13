import Foundation
import SwiftUI

// MARK: - 纸色

/// 六种纸色。纸色是产品的核心视觉资产：它不属于主题，深色/浅色模式下都不变，
/// 这样用户才能靠颜色记住一张便签。
enum Paper: String, Codable, CaseIterable, Identifiable {
    case yellow, pink, blue, mint, purple, cream

    var id: String { rawValue }

    var paper: Color {
        switch self {
        case .yellow: return Color(hex: 0xF7E7A6)
        case .pink:   return Color(hex: 0xF4D2DC)
        case .blue:   return Color(hex: 0xCFE0F7)
        case .mint:   return Color(hex: 0xD2EDDC)
        case .purple: return Color(hex: 0xE2D8F5)
        case .cream:  return Color(hex: 0xF0E8DA)
        }
    }

    var ink: Color {
        switch self {
        case .yellow: return Color(hex: 0x2C2718)
        case .pink:   return Color(hex: 0x2E1F25)
        case .blue:   return Color(hex: 0x1B2436)
        case .mint:   return Color(hex: 0x1B2A22)
        case .purple: return Color(hex: 0x251F30)
        case .cream:  return Color(hex: 0x2A241C)
        }
    }

    /// 墨色的不同强度，用于次级信息。
    var inkSoft: Color { ink.opacity(0.52) }
    var inkFaint: Color { ink.opacity(0.34) }

    var title: String {
        switch self {
        case .yellow: return "黄"; case .pink: return "粉"; case .blue: return "蓝"
        case .mint: return "薄荷"; case .purple: return "紫"; case .cream: return "米白"
        }
    }
}

// MARK: - 便签

struct NoteImage: Codable, Hashable {
    var fileName: String      // 相对 images/ 的文件名
    var thumbName: String     // 相对 thumbs/ 的文件名
    var pixelWidth: Int
    var pixelHeight: Int
    var byteSize: Int
    var isEncrypted: Bool = false
}

struct Note: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var wallID: UUID
    var text: String = ""
    var paper: Paper = .yellow
    var tag: String = ""            // 类型标签：想法 / 灵感 / 待办 / 资料 / 参考
    var createdAt: Date = Date()    // 添加时间，创建后不可修改
    var updatedAt: Date = Date()    // 最近编辑时间，仅用于「最近编辑」排序
    var sortOrder: Int = 0
    var isPinned: Bool = false
    /// 收藏：Optional 是有意的——老存档没有这个 key，非可选字段缺 key 会让整个存档解码失败（见 Archive 的注释）。
    var isFavorite: Bool? = nil
    /// 收藏态：老存档里没有这一项，读出来就是没收藏。
    var favorite: Bool { isFavorite ?? false }
    var deletedAt: Date? = nil      // 软删除：进回收站
    var image: NoteImage? = nil

    // 锁定态：加锁时 text 清空，密文写进 lockPayload；图片文件亦加密
    var isLocked: Bool = false
    var lockPayload: String? = nil
    var lockedAt: Date? = nil

    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil
    }

    var isChecklist: Bool { !Checklist.parse(text).isEmpty }

    var checklistProgress: (done: Int, total: Int) {
        let items = Checklist.parse(text)
        return (items.filter(\.done).count, items.count)
    }
}

struct Wall: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var sortOrder: Int = 0
    var isDefault: Bool = false
    /// 墙的标识色，只用于 tab 上的小圆点。Optional 是必须的：
    /// 老存档没有这个 key，写成非可选会让整个存档解码失败（进「损坏」分支）。
    var tint: Paper? = nil

    var color: Paper { tint ?? .yellow }
}

// MARK: - 清单解析

/// 勾选框不是独立的数据结构，而是正文里的一行语法：`- [ ] 文本` / `- [x] 文本`。
/// 这样"文本"始终是唯一事实来源，编辑、复制、导出都不会出现两份内容。
enum Checklist {
    struct Item: Identifiable, Hashable {
        let id: Int          // 是第几个勾选行（不是行号），用于回写
        let lineIndex: Int   // 在全文中的行号
        let text: String
        let done: Bool
    }

    /// 宽松识别：`- [ ]`、`- [x]`、`* [ ]`、`[ ]` 都算，容忍全角方括号。
    static func parse(_ text: String) -> [Item] {
        var items: [Item] = []
        for (i, line) in text.components(separatedBy: .newlines).enumerated() {
            guard let parsed = split(line) else { continue }
            items.append(Item(id: items.count, lineIndex: i, text: parsed.0, done: parsed.1))
        }
        return items
    }

    /// 返回 (勾选后的文本, 是否已完成)；不是勾选行则返回 nil
    static func split(_ line: String) -> (String, Bool)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3 else { return nil }
        var body = t
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            body = String(body.dropFirst(2))
        }
        let chars = Array(body)
        guard chars.count >= 3, chars[0] == "[", chars[2] == "]" else { return nil }
        let mark = chars[1]
        guard mark == " " || mark == "x" || mark == "X" || mark == "✓" else { return nil }
        let content = String(chars.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return (content, mark != " ")
    }

    /// 切换第 n 个勾选行的完成状态，返回改写后的全文
    static func toggle(_ text: String, itemID: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        var seen = 0
        for (i, line) in lines.enumerated() {
            guard let parsed = split(line) else { continue }
            if seen == itemID {
                let newMark = parsed.1 ? " " : "x"
                // 保留原来的列表前缀与缩进
                let leading = line.prefix { $0 == " " || $0 == "\t" }
                let prefix: String
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") { prefix = "- " }
                else if trimmed.hasPrefix("* ") { prefix = "* " }
                else if trimmed.hasPrefix("+ ") { prefix = "+ " }
                else { prefix = "" }
                lines[i] = "\(leading)\(prefix)[\(newMark)] \(parsed.0)"
                return lines.joined(separator: "\n")
            }
            seen += 1
        }
        return text
    }

    /// 把一段普通文字变成待办清单：每行前面补 `- [ ] `。
    ///
    /// 只在标签是「待办」时调用。用户选了待办、敲三行字，期望的是三个能勾的方框，
    /// 而不是一段普通文本——否则「待办」这个标签就只是个装饰。
    /// 已经是清单行的、空行都原样保留。
    static func asTodoList(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return line }
            if split(t) != nil { return line }          // 已经是 `- [ ] xxx`
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            return "\(leading)- [ ] \(t)"
        }.joined(separator: "\n")
    }

    /// 这段文字里有没有可勾选的行
    static func hasItems(_ text: String) -> Bool {
        !parse(text).isEmpty
    }
    /// 输入 `- ` 时自动补成 `- [ ] `
    static func autoComplete(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let last = lines.last else { return text }
        let trimmed = last.trimmingCharacters(in: .whitespaces)
        guard trimmed == "-" || trimmed == "- " || trimmed == "* " || trimmed == "*" else { return text }
        var out = lines
        let leading = last.prefix { $0 == " " }
        let bullet = trimmed.hasPrefix("*") ? "*" : "-"
        out[out.count - 1] = "\(leading)\(bullet) [ ] "
        return out.joined(separator: "\n")
    }
}

// MARK: - 时间显示规格（PRD §2.5）

enum TimeLabel {
    private static let calendar = Calendar.current

    /// 卡片上的时间：像纸上写的日期，不是永远跳动的相对时间
    static func card(_ date: Date, now: Date = Date()) -> String {
        let cal = calendar
        if cal.isDateInToday(date) {
            return "今天 " + time(date)
        }
        if cal.isDateInYesterday(date) {
            return "昨天 " + time(date)
        }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        if days >= 2 && days <= 6 { return "\(days) 天前" }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
        let md = "\(cal.component(.month, from: date))月\(cal.component(.day, from: date))日"
        if sameYear { return md }
        return "\(cal.component(.year, from: date))年\(md)"
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// 悬停提示：完整时间
    static func full(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

// MARK: - 排序与筛选

enum SortMode: String, Codable, CaseIterable, Identifiable {
    case newest, oldest, edited, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: return "最新"
        case .oldest: return "最早"
        case .edited: return "最近编辑"
        case .manual: return "手动"
        }
    }
    var symbol: String {
        switch self {
        case .newest: return "arrow.down"
        case .oldest: return "arrow.up"
        case .edited: return "clock.arrow.circlepath"
        case .manual: return "hand.draw"
        }
    }
}

enum ContentFilter: String, Codable, CaseIterable, Identifiable {
    case all, text, image, checklist
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .text: return "纯文字"
        case .image: return "含图片"
        case .checklist: return "有清单"
        }
    }
}

// MARK: - Color(hex)

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
