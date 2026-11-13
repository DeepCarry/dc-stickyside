import SwiftUI
import AppKit

// MARK: - 外观

/// 外观模式。`system` 跟随 macOS，其余强制锁定。
enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil                       // nil = 继承系统
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark:  return .dark
        case .system: return ThemeApplier.systemIsDark ? .dark : .light
        }
    }
}

/// 侧边栏三态：展开 → 图标栏 → 收起。⌘B / 标题栏按钮循环切换，重启保持。
enum SidebarMode: String, Codable, CaseIterable, Identifiable {
    case expanded, rail, hidden
    var id: String { rawValue }
    var next: SidebarMode {
        switch self {
        case .expanded: return .rail
        case .rail: return .hidden
        case .hidden: return .expanded
        }
    }
    /// 展开态宽度（v8 原型）；图标栏 54pt；收起不渲染。
    var width: CGFloat {
        switch self {
        case .expanded: return 216
        case .rail: return 54
        case .hidden: return 0
        }
    }
}

/// 主区视图：网格是桌面，列表是紧凑行，适合扫几十张。
enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
}

/// 侧栏里的智能视图：不属于任何一面墙，按规则算出来的集合。
enum SmartView: String, Codable, CaseIterable, Identifiable {
    case favorites, recent, desktop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .favorites: return "收藏"
        case .recent: return "最近"
        case .desktop: return "桌面便签"
        }
    }
    var subtitle: String {
        switch self {
        case .favorites: return "你标星的便签都在这里。"
        case .recent: return "最近 30 天动过的便签。"
        case .desktop: return "把重要的便签钉在桌面，始终可见。"
        }
    }
    var symbol: String {
        switch self {
        case .favorites: return "star"
        case .recent: return "clock"
        case .desktop: return "macwindow"
        }
    }
}

/// 把外观应用到所有窗口。改 `NSApp.appearance` 会让 SwiftUI 重新解析动态色，
/// 不需要重建视图树——否则切主题会把正在编辑的草稿和滚动位置一起清掉。
enum ThemeApplier {
    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func apply(_ mode: Appearance) {
        // 只作用于 AppKit 自己画的东西（菜单、NSAlert、交通灯）。
        // SwiftUI 的内容不吃这个：已经开着的窗口不会因为 NSApp.appearance 变了
        // 就重新解析动态色（实测点了没反应），那一层由各处的 preferredColorScheme 驱动。
        NSApp.appearance = mode.nsAppearance
    }
}

// MARK: - 设计 token
//
// 每个颜色都是一对值：浅色一套、深色一套，交给 AppKit 的动态色在绘制时解析。
// 好处是切换外观不需要重算视图树，`T.bg` 这种静态引用也不会被缓存成旧值。

enum T {
    // 层次：画布 < 顶栏 < 浮层 < 控件。
    // 之前整窗只有一个 #0A0A0C，卡片飘在近黑上，看起来是一团黑；
    // 现在画布抬到 #1B1B1E，顶栏再亮一档，靠明度差而不是靠描边分出「上工具栏/下画布」。
    static let bg     = Color.dyn(0xFFFFFF, 0x212121)   // 画布（便签网格底）
    static let panel  = Color.dyn(0xF7F6F2, 0x2E2E33)   // 顶栏、弹层底
    /// 侧栏：浅色米白、深色比画布再暗一档（ChatGPT 双色）。不能复用 T.panel：
    /// 深色下 panel 比画布亮（顶栏），侧栏比画布暗，两者方向相反。
    static let sidebar = Color.dyn(0xF7F6F2, 0x171717)
    static let float  = Color.dyn(0xFFFFFF, 0x35353B)   // 悬浮面板
    static let raised = Color.dyn(0xFFFFFF, 0x3E3E45)   // 抬起的控件

    // 文字
    static let text      = Color.dyn(0x1B1A18, 0xF2F2F4)
    static let textDim   = Color.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.58, darkAlpha: 0.56)
    static let textFaint = Color.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.36, darkAlpha: 0.34)

    // 强调色：只用于当前态、主按钮、示例标记
    static let accent    = Color.dyn(0xB0821F, 0xE8C46B)
    static let accentInk = Color.dyn(0xFFFFFF, 0x2A2415)

    // 分隔线
    static let line       = Color.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.08)
    static let lineStrong = Color.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.14)

    // 控件底：深色靠提亮、浅色靠压暗，不能都写 white.opacity()
    static let inset        = Color.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.06)
    static let insetSoft    = Color.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.032, darkAlpha: 0.035)
    static let insetPressed = Color.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.10)
    static let chipActive   = Color.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.075, darkAlpha: 0.10)

    /// 弹层里的分组卡片：浅色下是纯白，浮在米灰面板上；深色下仍是淡白叠加
    static let panelCard = Color.dyn(0xFFFFFF, 0xFFFFFF, lightAlpha: 1, darkAlpha: 0.035)

    // 主按钮（浅色下是米黄纸配深褐字，深色下是暗金配浅金）
    static let pillBg = Color.dyn(0xEFE4C6, 0x2A2718)
    static let pillFg = Color.dyn(0x4A3A12, 0xF7EDCB)

    // 便签卡片：浅色底上白纸要有一条边，阴影也要轻，否则整页发灰
    static let cardEdge   = Color.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.055, darkAlpha: 0.22)
    static let cardShadow = Color.dyn(0x000000, 0x000000, lightAlpha: 0.10, darkAlpha: 0.30)

    // 字号
    static let titleSize: CGFloat = 28
    static let bodySize: CGFloat = 15
    static let auxSize: CGFloat = 13
    static let metaSize: CGFloat = 11

    // 圆角
    static let rWindow: CGFloat = 16
    static let rCard: CGFloat = 12
    static let rControl: CGFloat = 8

    // 间距
    static let gap: CGFloat = 16
    static let pad: CGFloat = 20
}

extension Color {
    /// 一对色值，按当前外观解析。alpha 也分深浅两套：深色下的 6% 白 ≈ 浅色下的 6% 黑，
    /// 但视觉重量并不相等，所以两端各给一次。
    static func dyn(_ light: UInt32, _ dark: UInt32,
                    lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(hexValue: dark, alpha: darkAlpha)
                          : NSColor(hexValue: light, alpha: lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hexValue: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hexValue >> 16) & 0xFF) / 255,
                  green: CGFloat((hexValue >> 8) & 0xFF) / 255,
                  blue: CGFloat(hexValue & 0xFF) / 255,
                  alpha: CGFloat(alpha))
    }
}

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - 复用控件

/// 胶囊按钮：文字必须显式居中，否则不同渲染环境下会偏。
struct PillButtonStyle: ButtonStyle {
    var bg: Color = T.pillBg
    var fg: Color = T.pillFg
    var height: CGFloat = 30
    var hPad: CGFloat = 15

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12.5, .medium))
            .foregroundStyle(fg)
            .lineLimit(1)
            .fixedSize()
            .frame(height: height)
            .padding(.horizontal, hPad)
            .background(Capsule().fill(bg))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var hPad: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12.5, .medium))
            .foregroundStyle(configuration.isPressed ? T.text : T.textDim)
            .fixedSize()
            .frame(height: height)
            .padding(.horizontal, hPad)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? T.insetPressed : T.inset)
            )
    }
}

/// 便签纸色块：圆角方形，不是圆形。
/// 便签纸本身是方的，方形色块能被直接读成「换一张纸」，圆形只会读成「一个色点」。
/// 纸面叠一层极轻的上亮下暗，缩到 16pt 也有纸的厚度感，不会平得像色标。
struct PaperSwatch: View {
    let paper: Paper
    let ink: Color
    var selected: Bool
    var side: CGFloat = 17
    /// 命中区（含留白），比色块大，点击不费劲
    var cell: CGFloat = 22
    /// 选中环深浅：深色面板上白环要更实才看得出来
    var ringOpacity: Double = 0.55

    /// 真便签的圆角很小（约纸宽的 5%）。放到 17pt 上取 20%，再小就成硬方块了。
    private var radius: CGFloat { (side * 0.20 * 10).rounded() / 10 }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(paper.paper)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.10), .clear, .black.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom))
            )
            // 白纸块放在米黄纸面上几乎看不见，仍需一条极淡的分界，不能真的取消
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(ink.opacity(0.09), lineWidth: 1)
            )
            .overlay(
                // 选中：像把这张纸从一叠里抽出来一点
                RoundedRectangle(cornerRadius: radius + 2.5, style: .continuous)
                    .strokeBorder(ink.opacity(ringOpacity), lineWidth: 1.3)
                    .padding(-2.5)
                    .opacity(selected ? 1 : 0)
            )
            .frame(width: side, height: side)
            // 选中那张纸「被抽出来」：略微抬起 + 投影变实
            .scaleEffect(selected ? 1.045 : 1)
            .shadow(color: .black.opacity(selected ? 0.22 : 0.10),
                    radius: selected ? 2.5 : 1, y: selected ? 1.5 : 0.5)
            .frame(width: cell, height: cell)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// 侧栏/工具栏里的小标签（墙 tab、筛选 chip）
struct ChipLabel: View {    let text: String
    var active: Bool = false
    var dot: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            Text(text).font(.ui(12.5, active ? .medium : .regular))
        }
        .foregroundStyle(active ? T.text : T.textDim)
        .lineLimit(1)
        .fixedSize()
        .frame(height: 28)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? T.chipActive : Color.clear)
        )
    }
}

// MARK: - 外观选择器

/// 三张缩略图：直接给「长什么样」，比三个词更少误会。
/// 缩略图用固定色，不跟当前主题变——否则选中「浅色」时预览也被染成浅色，看不出对比。
struct AppearancePicker: View {
    var current: Appearance
    var onPick: (Appearance) -> Void

    private let thumbW: CGFloat = 112
    private let thumbH: CGFloat = 68

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Appearance.allCases) { mode in
                Button {
                    onPick(mode)
                } label: {
                    VStack(spacing: 7) {
                        thumb(mode)
                            .frame(width: thumbW, height: thumbH)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(current == mode ? T.accent : T.line,
                                                  lineWidth: current == mode ? 2 : 1)
                            )
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                            .padding(1.5)          // 选中描边不能被裁剪吃掉
                        Text(mode.title)
                            .font(.ui(11, current == mode ? .medium : .regular))
                            .foregroundStyle(current == mode ? T.text : T.textFaint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor()
                .help(mode.title)
            }
            Spacer(minLength: 0)
        }
    }

    /// 迷你窗口：顶栏 + 三张便签。必须画出「整个窗口」，
    /// 只给一块色板的话，用户分不清哪块是顶栏、哪块是画布。
    @ViewBuilder
    private func thumb(_ mode: Appearance) -> some View {
        switch mode {
        case .light:
            thumbBody(dark: false)
        case .dark:
            thumbBody(dark: true)
        case .system:
            // 一半浅一半深，就是这个模式的意思；中线表示「系统在中间替你选」
            HStack(spacing: 0) {
                thumbBody(dark: false, compact: true)
                thumbBody(dark: true, compact: true)
            }
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(Color(hex: 0xB0821F).opacity(0.9))
                    .frame(width: 1.5)
            }
        }
    }

    private func thumbBody(dark: Bool, compact: Bool = false) -> some View {
        let canvas = dark ? Color(hex: 0x212125) : Color(hex: 0xFFFFFF)
        let bar    = dark ? Color(hex: 0x2E2E33) : Color(hex: 0xEFEEE9)
        let edge   = dark ? Color.white.opacity(0.12) : Color.black.opacity(0.09)

        return ZStack(alignment: .top) {
            canvas
            VStack(spacing: 0) {
                HStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(edge).frame(width: 3, height: 3)
                    }
                    Spacer(minLength: 2)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(edge)
                        .frame(width: compact ? 10 : 16, height: 4)
                }
                .padding(.horizontal, 6)
                .frame(height: 14)
                .background(bar)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(edge).frame(height: 0.5)
                }

                HStack(spacing: 5) {
                    if compact {
                        note(.yellow)
                    } else {
                        note(.yellow); note(.blue); note(.mint)
                    }
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
        }
    }

    private func note(_ paper: Paper) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(paper.paper)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2.5) {
                    Capsule().fill(Color.black.opacity(0.20)).frame(width: 12, height: 1.8)
                    Capsule().fill(Color.black.opacity(0.13)).frame(width: 16, height: 1.8)
                    Capsule().fill(Color.black.opacity(0.09)).frame(width: 9, height: 1.8)
                }
                .padding(4)
            }
            .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
    }
}

/// 筛选条上的下拉入口：比纯文字 chip 多一个图标，用户能一眼分清「在筛什么」。
/// 激活态用强调色 + 一个 × 提示「点它就能取消」，不需要另设清除按钮。
struct FilterChip: View {
    let title: String
    var symbol: String? = nil
    var active: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .medium))
            }
            Text(title).font(.ui(11.5, active ? .medium : .regular))
            if active {
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
            }
        }
        .foregroundStyle(active ? T.accent : T.textDim)
        .lineLimit(1)
        .fixedSize()
        .frame(height: 26)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? T.accent.opacity(0.13) : T.inset)
        )
    }
}
