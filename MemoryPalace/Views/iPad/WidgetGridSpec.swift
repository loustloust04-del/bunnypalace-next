import SwiftUI

extension EnvironmentValues {
    /// 组件钉在横屏桌面格子上时为 true：卡底换成半透明跟壁纸调色（macOS 桌面组件那种），页 2 里仍是实底
    @Entry var pinnedOnDesktop = false
}

/// iPad 桌面格子的令牌 —— Apple HIG › Widgets › Specifications 里 iPad 的 **Device** 尺寸
/// （主屏上实际显示的大小；Canvas 是渲染画布，不是这个）。
/// 小方 `small` 直接取表；缝 `gutter` = 长条 − 2×小方（长条就是两个小方并排加一道缝，特大 = 两条长条加一道缝，两式一致）；
/// 外边距 HIG 没给主屏格子的数，取 `margin = gutter`（格到屏边和格到格一个节奏）。
/// 设计稿：docs/design-ipad-grid-system.html
struct WidgetGridSpec: Equatable {
    let small: CGFloat
    let medium: CGFloat

    var gutter: CGFloat { medium - 2 * small }
    var margin: CGFloat { gutter }

    /// 顶栏悬浮条底下起格
    static let top: CGFloat = 64
    static let dockWidth: CGFloat = 52
    /// 聊天窄过这个就不摆格子（设置里聊天栏宽滑块的下限）
    static let minChatWidth: CGFloat = 480

    static let fallback = WidgetGridSpec(small: 136, medium: 300)

    /// mac 桌面小组件令牌（plan-mac-shape ⧫8）：HIG 没有 macOS 尺寸表，09-08 在粟粟 Air 上实测系统小组件
    /// 窗口 180×180、可见面 164、相邻面缝 16（`CGWindowListCopyWindowInfo` + `screencapture -l`）；
    /// medium 桌面上没有，按 2S+G = 344 推（PLAUSIBLE，装一个 medium 再核）。派生 gutter = margin = 16
    static let mac = WidgetGridSpec(small: 164, medium: 344)

    /// 按**屏幕**尺寸查档（横竖都行，取短边 × 长边）。Split View / Stage Manager 缩窗不换档，格子跟机器走。
    /// 只给 iPad 用；mac 走 `.mac` + 按窗宽算列（`MacGridBudget`）
    static func forScreen(_ size: CGSize) -> WidgetGridSpec {
        let w = min(size.width, size.height).rounded(), h = max(size.width, size.height).rounded()
        switch (w, h) {
        case (834, 1194), (820, 1180): return WidgetGridSpec(small: 136, medium: 300)   // Pro 11" M4 · iPad 10 · Air 11"
        case (1024, 1366), (1032, 1376): return WidgetGridSpec(small: 160, medium: 356) // Pro 12.9" · 13"（HIG 未单列按 12.9）
        case (834, 1112): return WidgetGridSpec(small: 132, medium: 288)               // Pro 11" 2018–20
        case (810, 1080): return WidgetGridSpec(small: 124, medium: 272)               // HIG「Air 11"」
        case (744, 1133), (768, 1024): return WidgetGridSpec(small: 120, medium: 260)  // mini · iPad 7
        default: return fallback
        }
    }
}

/// 桌面排版：a 两侧各一列 / b **工具侧（右）**两列（长条、大方放得下）。两种扣掉的宽度一样，聊天同宽
enum DesktopArrangement: String, Codable, CaseIterable {
    case a, b

    var label: String {
        switch self {
        case .a: return "两侧各一列"
        case .b: return "一侧两列"
        }
    }
}

/// 竖 dock 图标条贴哪边。09-16 解耦后**只管这条图标条**——工具面板与排版 b 的两列恒在右、对话列表恒在左
enum DockSide: String, Codable, CaseIterable {
    case left, right

    var label: String {
        switch self {
        case .left:  return "左"
        case .right: return "右"
        }
    }
}

/// 一次横屏布局的算好的格线：聊天两侧让位、各区的位置列数、dock 的 x、行数。纯值，`compute` 是纯函数。
///
/// 横向链（排版 a，dock 右）：`[M][1 列][G][ 聊天 ][G][1 列][G][dock][M]`
/// 排版 b（dock 右）：`[M][ 聊天 ][G][2 列][G][dock][M]`
/// dock 左（09-16 解耦后**不再是镜像**）：`[dock][G][1 列][G][ 聊天 ][G][工具列][M]`——工具恒右、对话恒左
struct GridFrame: Equatable {
    enum Side: String, Codable, Hashable { case left, right }

    struct Zone: Equatable {
        let side: Side
        let x: CGFloat
        let cols: Int
    }

    let spec: WidgetGridSpec
    let width: CGFloat
    let height: CGFloat
    /// 聊天左右要让出的宽（含边距和缝）
    let leftLane: CGFloat
    let rightLane: CGFloat
    let zones: [Zone]
    let dockX: CGFloat
    let rows: Int

    var chatWidth: CGFloat { width - leftLane - rightLane }
    /// 聊天不窄过下限、至少能放一行、至少有一列才算摆得下（mac 降列后可能出现 0 列的 zone，只保身份不算格子）
    var fits: Bool { chatWidth >= WidgetGridSpec.minChatWidth && rows >= 1 && zones.reduce(0) { $0 + $1.cols } >= 1 }

    func zone(_ side: Side) -> Zone? { zones.first { $0.side == side } }

    /// 某区第 col 列第 row 行（0 起）那格的位置；跨列跨行时把中间的缝也算进去
    func cellFrame(zone: Zone, col: Int, row: Int, colSpan: Int = 1, rowSpan: Int = 1) -> CGRect {
        let s = spec.small, g = spec.gutter
        return CGRect(x: zone.x + CGFloat(col) * (s + g),
                      y: top + CGFloat(row) * (s + g),
                      width: CGFloat(colSpan) * s + CGFloat(colSpan - 1) * g,
                      height: CGFloat(rowSpan) * s + CGFloat(rowSpan - 1) * g)
    }

    /// 全屏模式 tab 组的宽：正好盖住工具侧的列区 + 到 dock 的那道缝（k 列 = kS + kG；iPad 两列 = 2S + 2G），开关 tab 聊天不动
    var toolPanelWidth: CGFloat {
        let k = CGFloat(toolsCols)
        return k * spec.small + k * spec.gutter
    }
    /// 工具侧（恒右）的列数
    let toolsCols: Int
    /// 第一行格子从哪起。默认 64 = 悬浮胶囊底下（浮窗 / iPad）；mac 停靠壳没有胶囊，`MacShellFrame` 给 m
    var top: CGFloat = WidgetGridSpec.top

    /// `dockInset`：dock 离屏边多远。浮窗模式 = M（玻璃条悬在格线上）；全屏模式贴边满高 = 0。
    /// `reserveToolsSide`：全屏模式给工具侧（恒右）固定留两列——tab 组正好盖在上面，开关不推聊天
    /// （plan-ipad-desktop-grid 丙右 + 乙左；排版 a 的工具侧因此从一列变两列）。
    /// `convCols` / `toolsCols` 显式给列数时（mac 按窗宽算，`MacGridBudget`）覆盖上面的默认；
    /// 对话侧 0 列仍保留 zone（x 在边距处、cols 0）——存档那一侧「还在只是放不下」，不会被当成换边搬走
    static func compute(width: CGFloat, height: CGFloat, spec: WidgetGridSpec,
                        arrangement: DesktopArrangement, dockSide: DockSide,
                        dockInset: CGFloat? = nil, reserveToolsSide: Bool = false,
                        convCols: Int? = nil, toolsCols toolsColsOverride: Int? = nil) -> GridFrame {
        let s = spec.small, g = spec.gutter, m = spec.margin, d = WidgetGridSpec.dockWidth
        let di = dockInset ?? m
        // 排版 b 的定义就是「一侧两列」，不看预留；排版 a 的工具侧只在预留（停靠）时两列
        let toolsCols = toolsColsOverride ?? (arrangement == .b ? 2 : (reserveToolsSide ? 2 : 1))
        let convColsA = convCols ?? 1
        let toolsZoneW = CGFloat(toolsCols) * s + CGFloat(max(0, toolsCols - 1)) * g
        let convZoneW = CGFloat(convColsA) * s + CGFloat(max(0, convColsA - 1)) * g
        // 09-16 解耦：**工具区恒在右、对话区恒在左**，`dockSide` 只决定那条竖 dock 贴哪边
        // （她「工具页面永远放右边，列表永远从左边出来」）。三条泳道各自算，不再 switch 四个 case。
        // 三个既有口径一个都不能丢（R-LD #1 阻断，回归网 LaneDecoupleRegressionTests 锁着）：
        //   ① dock **顶替**所在侧的外边距 m，不是叠加
        //   ② 排版 b 的空侧连 m 都不留 = 0（跟 mac 降列的「0 列留 m」不是一个口径）
        //   ③ mac 降列 convCols == 0 时只留 m
        // 由此得到的不变量：两侧总让位与 dockSide 无关 ⇒ 聊天宽度不随 dock 换边而变
        //   ⇒ `MacGridBudget` 的滞回不用动（R-LD #5）。排版 b + dock 左因此**不留缝**（plan §5-3）。
        let dockOnLeft = dockSide == .left
        let hasConvZone = arrangement == .a
        let leftLane: CGFloat
        if dockOnLeft {
            // dock 顶替 m；对话区在它右边（排版 b 没有对话区，dock 后面也不留缝——保住上面那条不变量）
            leftLane = di + d + (hasConvZone && convColsA > 0 ? g + convZoneW + g : 0)
        } else {
            leftLane = hasConvZone ? (convColsA == 0 ? m : m + convZoneW + g) : 0
        }
        // 工具区恒在右：dock 在右时它后面还有 dock，dock 在左时贴屏边（全屏 tab 组自己含到边的缝）
        let rightLane = g + toolsZoneW + g + (dockOnLeft ? 0 : d + di)
        let dockX = dockOnLeft ? di : width - di - d
        var zones: [Zone] = []
        // 排版 b **只发一道 zone**：换侧搬迁靠 `zones.count == 1`（DesktopGridRules），多发一道 0 列的会把她的组件锁死（R-LD #2 阻断）
        if hasConvZone {
            zones.append(Zone(side: .left, x: dockOnLeft ? di + d + g : m, cols: convColsA))
        }
        zones.append(Zone(side: .right, x: dockOnLeft ? width - m - toolsZoneW : dockX - g - toolsZoneW,
                          cols: toolsCols))
        let rows = max(0, Int(((height - WidgetGridSpec.top - m + g) / (s + g)).rounded(.down)))
        return GridFrame(spec: spec, width: width, height: height,
                         leftLane: leftLane, rightLane: rightLane, zones: zones, dockX: dockX, rows: rows,
                         toolsCols: toolsCols)
    }
}
