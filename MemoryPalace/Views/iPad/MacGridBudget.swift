import Foundation
import CoreGraphics

/// mac 桌面格子的**列数预算**（plan-mac-shape A3 / astra F7）：iPad 按机型查档、列数固定；mac 按窗宽算。
/// 纯函数 + 显式前态：列数决策只在 `ContentView.macLayout` 的 `onGeometryChange` 一处提交，
/// `grid(in:)` / inset / overlay / 吸边读同一份快照，查询不写状态。
///
/// 横向链（排版 a，dock 右）：`[M][对话侧 n 列][G][ 聊天 ][G][工具侧 k 列][G][dock][dockInset]`
/// - 基线：工具侧 = 停靠预留 2 列（浮窗模式 1 列），对话侧 = 排版 a 1 列 / 排版 b 0 列
/// - 降列：聊天 < `minChatWidth`（480）→ 对话侧降到 **0 列但保留 zone 身份**（存档不搬）；仍不够 → 没格子
/// - 加列：聊天超过 `contentMaxWidth`（720）的余量每满 S+G 加一列——a 先对话侧、再工具侧、交替；b 只加工具侧；每侧封顶 4
/// - 滞回：缩窗时只有「再宽 24pt 也保不住上一次列数」才减，避免在跳点附近逐帧抖
enum MacGridBudget {
    struct Columns: Equatable {
        var conv: Int
        var tools: Int
        var total: Int { conv + tools }
    }

    static let maxColsPerSide = 4
    static let shrinkHysteresis: CGFloat = 24
    /// 聊天道超过这个数的余量才拿来加列（`Theme.contentMaxWidth` mac 固定 720；这里不引 Theme，保持纯函数可测）
    static let chatComfortWidth: CGFloat = 720

    /// 对话侧让位宽：0 列只留外边距；n 列 = M + n×(S+G)
    static func convLane(cols: Int, spec: WidgetGridSpec) -> CGFloat {
        cols == 0 ? spec.margin : spec.margin + CGFloat(cols) * (spec.small + spec.gutter)
    }

    /// 工具侧让位宽：G + 列区 + G + dock + dockInset
    static func toolsLane(cols: Int, spec: WidgetGridSpec, dockInset: CGFloat) -> CGFloat {
        let zone = CGFloat(cols) * spec.small + CGFloat(max(0, cols - 1)) * spec.gutter
        return spec.gutter + zone + spec.gutter + WidgetGridSpec.dockWidth + dockInset
    }

    static func chatWidth(width: CGFloat, cols: Columns, spec: WidgetGridSpec, arrangement: DesktopArrangement,
                          dockInset: CGFloat) -> CGFloat {
        let conv = arrangement == .a ? convLane(cols: cols.conv, spec: spec) : 0
        return width - conv - toolsLane(cols: cols.tools, spec: spec, dockInset: dockInset)
    }

    /// 不带滞回的目标列数（纯按宽度）。
    /// mac 停靠壳不走这里（它的列在 `MacShellFrame`，按空地算）；这份是浮窗模式 + iPad 的口径
    static func target(width: CGFloat, spec: WidgetGridSpec, arrangement: DesktopArrangement,
                       dockInset: CGFloat, reserveToolsSide: Bool) -> Columns {
        // 基线同 GridFrame.compute 默认：b 永远两列；a 的工具侧停靠预留时两列、浮窗一列
        var cols = Columns(conv: arrangement == .a ? 1 : 0, tools: arrangement == .b ? 2 : (reserveToolsSide ? 2 : 1))
        func chat(_ c: Columns) -> CGFloat { chatWidth(width: width, cols: c, spec: spec, arrangement: arrangement, dockInset: dockInset) }
        // 降列：聊天守 480，对话侧先让（保留 zone 身份由 GridFrame 负责）
        if chat(cols) < WidgetGridSpec.minChatWidth, cols.conv > 0 { cols.conv = 0 }
        // 加列：余量每满 S+G 加一列，a 交替（先对话侧）、b 只加工具侧；两侧都封顶就停
        let step = spec.small + spec.gutter
        var addToConv = arrangement == .a
        while chat(cols) - chatComfortWidth >= step {
            var added = false
            if arrangement == .a, addToConv, cols.conv < maxColsPerSide {
                cols.conv += 1; added = true
            } else if cols.tools < maxColsPerSide {
                cols.tools += 1; added = true
            } else if arrangement == .a, cols.conv < maxColsPerSide {
                cols.conv += 1; added = true
            }
            if !added { break }
            if arrangement == .a { addToConv.toggle() }
        }
        return cols
    }

    /// 带滞回的决策：`previous` 是上一次提交的列数（nil = 首次，直接取目标）。
    /// 只在**缩窗减列**这个方向加 24pt 的带：宽一点点（+24）还能保住上一次的列数就不减；加列不加带。
    static func columns(width: CGFloat, spec: WidgetGridSpec, arrangement: DesktopArrangement,
                        dockInset: CGFloat, reserveToolsSide: Bool, previous: Columns?) -> Columns {
        let now = target(width: width, spec: spec, arrangement: arrangement, dockInset: dockInset,
                         reserveToolsSide: reserveToolsSide)
        guard let previous, now.total < previous.total else { return now }
        let wider = target(width: width + shrinkHysteresis, spec: spec, arrangement: arrangement,
                           dockInset: dockInset, reserveToolsSide: reserveToolsSide)
        return wider.total >= previous.total ? previous : now
    }
}
