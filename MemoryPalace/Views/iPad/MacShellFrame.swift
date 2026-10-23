#if os(macOS)
import Foundation
import CoreGraphics

/// mac 停靠布局：收起的面板不占位，正文面板填满其余窗口。
/// 阅读最大宽度属于面板内部，不能参与窗口分栏预算。
/// 浮窗与 iPad 的 GridFrame 仍保持原有桌面格子行为。
struct MacShellFrame: Equatable {
    let width: CGFloat
    let height: CGFloat
    /// dockShown ? 52 : 0
    let dock: CGFloat
    let dockSide: DockSide
    /// 列表开着 → 渲染宽（钳过）；收起 → nil
    let conv: CGFloat?
    /// 工具面板开着 → 渲染宽（钳过）；收起 → nil
    let tool: CGFloat?
    /// 可见左面板宽；关闭时为 0。
    let leftLane: CGFloat
    let rightLane: CGFloat
    /// 正文卡槽的宽（含 cardGapX 两侧）= width − dock − leftLane − rightLane
    let card: CGFloat
    let cols: MacGridBudget.Columns
    /// 没有缩起工具时为 nil；显式缩起工具时按需提供格子。
    let grid: GridFrame?
    /// 底列（只在正文卡槽下方，plan-panel-ps 阶段 4）开着 → 渲染高（钳过）；收起 → nil
    let bottom: CGFloat?
    /// 卡槽里正文部分的高 = height − bottom（左右列与格子仍满高，不受底列影响）
    var cardHeight: CGFloat { max(0, height - (bottom ?? 0)) }

    /// 卡槽在工作区里的 x（标题居卡用）
    var cardX: CGFloat { (dockSide == .left ? dock : 0) + leftLane }

    static let toolMinWidth: CGFloat = 280
    static let toolMaxWidth: CGFloat = 460
    /// = 今天两列的宽（2×164 + 2×16），她第一眼看到的不变
    static let toolDefaultWidth: CGFloat = 360
    /// 底列：下限 / 占工作区高的上限比例 / 正文卡槽至少留的高
    static let bottomMin: CGFloat = 140
    static let bottomMaxRatio: CGFloat = 0.6
    static let cardMinHeight: CGFloat = 280
    static let maxColsPerSide = MacGridBudget.maxColsPerSide
    static let shrinkHysteresis = MacGridBudget.shrinkHysteresis

    /// 正文卡最窄 = 正文下限 + 卡两侧的外边距和内边距
    static func cardMin(cardEdges: CGFloat) -> CGFloat { IPadPanelLayout.minBodyWidth + cardEdges }
    /// 底列的渲染高：`[140, max(140, min(0.6H, H − 280))]`，再不超过 H（极矮的窗卡槽先让，永远非负）
    static func bottomHeight(stored: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        let upper = max(bottomMin, min(bottomMaxRatio * height, height - cardMinHeight))
        let s = stored.isFinite ? stored : bottomMin
        return min(height, max(bottomMin, min(upper, s)))
    }

    /// 列表的渲染宽：给工具面板留下限（工具**后**让），上限还受 `maxPanelWidth` 钳
    static func convWidth(stored: CGFloat, width: CGFloat, dock: CGFloat, toolShown: Bool, cardEdges: CGFloat) -> CGFloat {
        let upper = min(IPadPanelLayout.maxPanelWidth,
                        width - dock - (toolShown ? toolMinWidth : 0) - cardMin(cardEdges: cardEdges))
        return max(IPadPanelLayout.minPanelWidth, min(upper, stored))
    }

    /// 工具面板的渲染宽：吃列表钳后剩下的
    static func toolWidth(stored: CGFloat, width: CGFloat, dock: CGFloat, conv: CGFloat?, cardEdges: CGFloat) -> CGFloat {
        let upper = min(toolMaxWidth, width - dock - (conv ?? 0) - cardMin(cardEdges: cardEdges))
        return max(toolMinWidth, min(upper, stored))
    }

    static func cardComfort(cardEdges: CGFloat) -> CGFloat { MacGridBudget.chatComfortWidth + cardEdges }

    static func lane(cols: Int, spec: WidgetGridSpec) -> CGFloat {
        cols == 0 ? 0 : spec.margin + CGFloat(cols) * (spec.small + spec.gutter)
    }

    static func targetColumns(free: CGFloat, spec: WidgetGridSpec, arrangement: DesktopArrangement,
                              leftOpen: Bool, rightOpen: Bool) -> MacGridBudget.Columns {
        var n = 0, k = 0
        let canL = leftOpen && arrangement == .a, canR = rightOpen
        for _ in 0..<(maxColsPerSide * 2) {
            var moved = false
            if canL, n < maxColsPerSide, lane(cols: n + 1, spec: spec) + lane(cols: k, spec: spec) <= free { n += 1; moved = true }
            if canR, k < maxColsPerSide, lane(cols: n, spec: spec) + lane(cols: k + 1, spec: spec) <= free { k += 1; moved = true }
            if !moved { break }
        }
        return .init(conv: n, tools: k)
    }

    /// 停靠模式不为已收起的面板保留桌面列；忽略旧存档的列数。
    static func columns(width: CGFloat, spec: WidgetGridSpec, arrangement: DesktopArrangement,
                        dockShown: Bool, leftShown: Bool, leftWidth: CGFloat,
                        toolShown: Bool, toolWidth: CGFloat, cardEdges: CGFloat,
                        previous: MacGridBudget.Columns?) -> MacGridBudget.Columns {
        .init(conv: 0, tools: 0)
    }

    static func compute(width: CGFloat, height: CGFloat, spec: WidgetGridSpec, arrangement: DesktopArrangement,
                        dockSide: DockSide, dockShown: Bool, leftShown: Bool, leftWidth: CGFloat,
                        toolShown: Bool, toolWidth: CGFloat, cardEdges: CGFloat,
                        cols committed: MacGridBudget.Columns? = nil,
                        bottomShown: Bool = false, bottomHeight storedBottom: CGFloat = 0,
                        reserveDesktopSpace: Bool = false) -> MacShellFrame {
        guard width > 0, height > 0 else {
            return MacShellFrame(width: 0, height: 0, dock: 0, dockSide: dockSide, conv: nil, tool: nil,
                                 leftLane: 0, rightLane: 0, card: 0, cols: .init(conv: 0, tools: 0), grid: nil, bottom: nil)
        }
        let bottom = bottomShown ? bottomHeight(stored: storedBottom, height: height) : nil
        let dock = dockShown ? WidgetGridSpec.dockWidth : 0
        let conv = leftShown ? convWidth(stored: leftWidth, width: width, dock: dock, toolShown: toolShown, cardEdges: cardEdges) : nil
        let tool = toolShown ? self.toolWidth(stored: toolWidth, width: width, dock: dock, conv: conv, cardEdges: cardEdges) : nil
        let s = spec.small, g = spec.gutter, m = spec.margin
        let free = width - dock - (conv ?? 0) - (tool ?? 0) - cardComfort(cardEdges: cardEdges)
        let cols = reserveDesktopSpace
            ? targetColumns(free: free, spec: spec, arrangement: arrangement, leftOpen: !leftShown, rightOpen: !toolShown)
            : MacGridBudget.Columns(conv: 0, tools: 0)
        let leftLane = conv ?? lane(cols: cols.conv, spec: spec)
        let rightLane = tool ?? lane(cols: cols.tools, spec: spec)
        let card = width - dock - leftLane - rightLane
        // 格子：从工作区顶留 m 起（不是 64——那是给悬浮胶囊留的），下面留 m
        let rows = max(0, Int(((height - 2 * m + g) / (s + g)).rounded(.down)))
        let leftStart: CGFloat = dockSide == .left ? dock : 0
        let rightStart = width - (dockSide == .right ? dock : 0) - rightLane
        var zones: [GridFrame.Zone] = []
        // 排版 a 恒两道（对话侧 0 列也保身份，存档不搬）；排版 b 只发工具侧一道（`zones.count == 1` 的搬迁规则）
        if arrangement == .a {
            zones.append(.init(side: .left, x: leftStart + m, cols: cols.conv))
        }
        zones.append(.init(side: .right, x: rightStart + g, cols: cols.tools))
        let grid: GridFrame? = rows >= 1 && cols.total >= 1
            ? GridFrame(spec: spec, width: width, height: height, leftLane: leftLane, rightLane: rightLane,
                        zones: zones, dockX: dockSide == .left ? 0 : width - dock, rows: rows,
                        toolsCols: cols.tools, top: m)
            : nil
        return MacShellFrame(width: width, height: height, dock: dock, dockSide: dockSide, conv: conv, tool: tool,
                             leftLane: leftLane, rightLane: rightLane, card: card,
                             cols: cols, grid: grid, bottom: bottom)
    }
}
#endif
