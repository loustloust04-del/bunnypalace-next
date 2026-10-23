import Foundation
import CoreGraphics

// 桌面格子的纯规则层：放哪一格（`DesktopGridPlacer`）、拖到哪能不能落 / 跟谁对换（`DesktopDropRules`）。
// 不包 `#if os(iOS)`——mac 的测试目标要编它，mac 新壳（plan-mac-shape）也直接用。视图层在 `DesktopGridView`。

/// 桌面格子上的一样东西：页 2 的小组件 / 缩成组件的工具窗
enum DesktopItem {
    case widget(WidgetInstance)
    case tool(String)

    var id: String {
        switch self {
        case .widget(let w): return "w.\(w.kind.rawValue)"
        case .tool(let t):   return "t.\(t)"
        }
    }
}

/// 排好位的一块
struct DesktopPlaced: Identifiable {
    let item: DesktopItem
    let size: WidgetSize
    let zone: GridFrame.Zone
    let col: Int, row: Int
    let colSpan: Int, rowSpan: Int
    let frame: CGRect
    var id: String { item.id }
    var placement: DesktopGridStore.Placement { .init(side: zone.side, col: col, row: row) }
}

/// 格子里的一格（区 + 列 + 行）：拖放的落点
struct DesktopCell: Equatable {
    let side: GridFrame.Side
    let col: Int, row: Int
}

/// 排位算法（纯函数，视图和「缩成组件」的飞行动画共用）：存过位置的照存的放，没存过的按顺序找第一个空格；
/// 排版 a 全是 1×1（长条 / 大方降成小方脸），排版 b 的两列才放 2×1 / 2×2，放不下也降 1×1
@MainActor
enum DesktopGridPlacer {
    static func place(_ items: [DesktopItem], grid: GridFrame, arrangement: DesktopArrangement,
                      store: DesktopGridStore) -> [DesktopPlaced] {
        var occ: [GridFrame.Side: [[Bool]]] = [:]
        for z in grid.zones { occ[z.side] = Array(repeating: Array(repeating: false, count: grid.rows), count: z.cols) }
        var out: [DesktopPlaced] = []
        var pending: [DesktopItem] = []

        func span(_ item: DesktopItem) -> (cols: Int, rows: Int, size: WidgetSize) {
            guard case .widget(let w) = item, arrangement == .b else { return (1, 1, .small) }
            switch w.size {
            case .small:  return (1, 1, .small)
            case .medium: return (2, 1, .medium)
            case .large:  return (2, 2, .large)
            }
        }

        func tryPlace(_ item: DesktopItem, zone: GridFrame.Zone, col: Int, row: Int, span s: (cols: Int, rows: Int, size: WidgetSize)) -> Bool {
            guard col >= 0, row >= 0, col + s.cols <= zone.cols, row + s.rows <= grid.rows else { return false }
            for dc in 0..<s.cols { for dr in 0..<s.rows where occ[zone.side]![col + dc][row + dr] { return false } }
            for dc in 0..<s.cols { for dr in 0..<s.rows { occ[zone.side]![col + dc][row + dr] = true } }
            out.append(DesktopPlaced(item: item, size: s.size, zone: zone, col: col, row: row, colSpan: s.cols, rowSpan: s.rows,
                                     frame: grid.cellFrame(zone: zone, col: col, row: row, colSpan: s.cols, rowSpan: s.rows)))
            return true
        }

        for item in items {
            let s = span(item)
            if let p = store.placement(of: item.id, in: arrangement) {
                // 存的那一侧还在：放得下就放，放不下（格子被临时压少）就先不显示，存档不动
                // 存的那一侧没了（排版 b 把 dock 从右挪到左，唯一那道从 right 变 left）：
                // 只有一道时按存的行列搬过去，否则当没排过重新填——否则组件会**整片消失**
                if let zone = grid.zone(p.side) ?? (grid.zones.count == 1 ? grid.zones.first : nil) {
                    if tryPlace(item, zone: zone, col: p.col, row: p.row, span: s) { continue }
                    if grid.zone(p.side) != nil { continue }   // 那一侧还在、只是这会儿放不下 → 不动它
                }
                pending.append(item)
                continue
            }
            pending.append(item)
        }
        for item in pending {
            let s = span(item)
            let spans = s.cols * s.rows > 1 ? [s, (1, 1, .small)] : [s]
            outer: for sp in spans {
                for zone in grid.zones where zone.cols >= sp.cols {
                    for r in 0..<grid.rows { for c in 0..<zone.cols where tryPlace(item, zone: zone, col: c, row: r, span: sp) { break outer } }
                }
            }
        }
        return out
    }

    /// 桌面小组件一共占几格（排版 a 全 1×1；b 按各自尺寸）——喂给 `IPadPanelLayout.canMinimize / minimize`
    static func widgetCells(_ widgets: [WidgetInstance], arrangement: DesktopArrangement) -> Int {
        widgets.reduce(0) { $0 + (arrangement == .b ? $1.size.cells : 1) }
    }

    /// 桌面上现在的成员：小组件 + 缩起来的工具
    static func items(_ layout: IPadPanelLayout) -> [DesktopItem] {
        DashboardManager.shared.widgets.map(DesktopItem.widget) + layout.minimized.map(DesktopItem.tool)
    }

    /// 某个工具如果现在缩成组件会落在哪一格（给飞行动画当目的地）
    static func landingFrame(forTool toolId: String, layout: IPadPanelLayout, grid: GridFrame) -> CGRect? {
        let all = place(items(layout) + [.tool(toolId)], grid: grid, arrangement: layout.arrangement, store: DesktopGridStore.shared)
        return all.first { $0.id == "t.\(toolId)" }?.frame
    }
}

/// 拖放落格规则（纯函数）：越界不落 / 全空落 / 恰好压住一块且它整个搬得进原位就对换 / 其余飞回
enum DesktopDropRules {
    static func occupant(at side: GridFrame.Side, col: Int, row: Int, all: [DesktopPlaced]) -> DesktopPlaced? {
        all.first { $0.zone.side == side && col >= $0.col && col < $0.col + $0.colSpan && row >= $0.row && row < $0.row + $0.rowSpan }
    }

    /// 把 `p` 放到 `cell` 会压住的**其他**块（去重）
    static func covered(_ p: DesktopPlaced, at cell: DesktopCell, all: [DesktopPlaced]) -> [DesktopPlaced] {
        var seen = Set<String>(), out: [DesktopPlaced] = []
        for dc in 0..<p.colSpan { for dr in 0..<p.rowSpan {
            if let o = occupant(at: cell.side, col: cell.col + dc, row: cell.row + dr, all: all),
               o.id != p.id, seen.insert(o.id).inserted { out.append(o) }
        } }
        return out
    }

    /// 能不能落在 `cell`，落下去要不要跟谁对换。
    /// 规则：① 越界不落 ② 目标区全空 → 落 ③ 恰好压住一块，且那块**整个**搬得进 `p` 原来的位置
    /// （边界内、不压到除这两块之外的人）→ 对换 ④ 其余（压住两块以上 / 对方搬不回去）→ 飞回。
    /// 原来只允许 1×1 ↔ 1×1，排版 b 的长条（2×1）和大方（2×2）因此只能落全空格，基本拖不动。
    static func dropPlan(_ p: DesktopPlaced, at cell: DesktopCell, all: [DesktopPlaced], grid: GridFrame) -> (ok: Bool, swap: DesktopPlaced?) {
        guard let zone = grid.zone(cell.side), cell.col >= 0, cell.row >= 0,
              cell.col + p.colSpan <= zone.cols, cell.row + p.rowSpan <= grid.rows else { return (false, nil) }
        let others = covered(p, at: cell, all: all)
        if others.isEmpty { return (true, nil) }
        guard others.count == 1, let o = others.first,
              let home = grid.zone(p.zone.side),
              p.col + o.colSpan <= home.cols, p.row + o.rowSpan <= grid.rows else { return (false, nil) }
        for dc in 0..<o.colSpan { for dr in 0..<o.rowSpan {
            if let blocker = occupant(at: p.zone.side, col: p.col + dc, row: p.row + dr, all: all),
               blocker.id != p.id, blocker.id != o.id { return (false, nil) }
        } }
        return (true, o)
    }
}
