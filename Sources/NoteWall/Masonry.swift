import SwiftUI

/// 瀑布流布局：按列高最短优先放置，卡片自然错落。
///
/// **默认 3 列**：两列时每张便签会被拉到 ~450pt 宽，块头太大、内容显得稀，
/// 看起来不像一面便签墙。列数跟随窗口宽度自适应，但以 3 列为锚点：
/// · 列宽被挤到 260pt 以下就逐级减列（窄窗口 → 2 列 → 1 列），避免卡片变成细条
/// · 只有拉到每列仍能 ≥ 320pt 时才加到第 4 列，避免默认窗口一动就跳成 4 列
struct MasonryLayout: Layout {
    var preferredColumns: Int = 3
    /// 降到更少列的下限：当前列宽小于它就减一列
    var minColumnWidth: CGFloat = 260
    /// 加到更多列的门槛：新增一列后每列还得有这么宽
    var wideColumnWidth: CGFloat = 320
    var maxColumns: Int = 4
    var gap: CGFloat = 16
    /// 测试用：默认 nil，placeSubviews 完成后把每张卡片的落点交出去。
    /// 故意不进 init——否则 `MasonryLayout { 卡片... }` 的尾随闭包会被当成这个参数。
    var onLayout: (([CGRect]) -> Void)? = nil

    init(preferredColumns: Int = 3, minColumnWidth: CGFloat = 260,
         wideColumnWidth: CGFloat = 320, maxColumns: Int = 4, gap: CGFloat = 16) {
        self.preferredColumns = preferredColumns
        self.minColumnWidth = minColumnWidth
        self.wideColumnWidth = wideColumnWidth
        self.maxColumns = maxColumns
        self.gap = gap
    }

    struct Cache {
        var columns: [Int] = []
        var sizes: [CGSize] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    /// 抽成静态方法，`--gridtest` 可以直接对各档窗口宽度做断言。
    static func columnCount(width: CGFloat,
                            gap: CGFloat = 16,
                            preferred: Int = 3,
                            minColumnWidth: CGFloat = 260,
                            wideColumnWidth: CGFloat = 320,
                            maxColumns: Int = 4) -> Int {
        // SwiftUI 在根视图未定宽时会给 .infinity：Int(infinity) 会直接 SIGTRAP，
        // 不能只判断 > 0。窄/未定宽一律按单列兜底。
        guard width.isFinite, width > 0 else { return 1 }

        func columnWidth(_ n: Int) -> CGFloat {
            (width - CGFloat(n - 1) * gap) / CGFloat(n)
        }

        var cols = max(1, min(maxColumns, preferred))
        while cols > 1 && columnWidth(cols) < minColumnWidth { cols -= 1 }
        while cols < maxColumns && columnWidth(cols + 1) >= wideColumnWidth { cols += 1 }
        return cols
    }

    private func columnCount(for width: CGFloat) -> Int {
        Self.columnCount(width: width, gap: gap, preferred: preferredColumns,
                         minColumnWidth: minColumnWidth,
                         wideColumnWidth: wideColumnWidth, maxColumns: maxColumns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let proposed = proposal.width ?? 900
        let width = proposed.isFinite ? max(1, proposed) : 900
        let cols = columnCount(for: width)
        let colWidth = (width - CGFloat(cols - 1) * gap) / CGFloat(cols)

        var heights = Array(repeating: CGFloat(0), count: cols)
        var total: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(ProposedViewSize(width: colWidth, height: nil))
            let idx = heights.enumerated().min { $0.element < $1.element }?.offset ?? 0
            heights[idx] += size.height + gap
            total = max(total, heights[idx])
        }
        return CGSize(width: width, height: max(0, total - gap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let cols = columnCount(for: bounds.width)
        let colWidth = (bounds.width - CGFloat(cols - 1) * gap) / CGFloat(cols)
        var heights = Array(repeating: CGFloat(0), count: cols)
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)

        for sv in subviews {
            let size = sv.sizeThatFits(ProposedViewSize(width: colWidth, height: nil))
            let idx = heights.enumerated().min { $0.element < $1.element }?.offset ?? 0
            let x = bounds.minX + CGFloat(idx) * (colWidth + gap)
            let y = bounds.minY + heights[idx]
            sv.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: colWidth, height: size.height)
            )
            frames.append(CGRect(x: x, y: y, width: colWidth, height: size.height))
            heights[idx] += size.height + gap
        }
        onLayout?(frames)
    }
}
