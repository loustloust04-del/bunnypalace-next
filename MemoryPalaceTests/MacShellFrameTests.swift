import XCTest
@testable import 记忆花园

/// mac 停靠布局：可见面板占位，关闭侧归还正文；浮窗布局保留。
/// 样张来自小样 `docs/design-mac-fullscreen-otty.html` 的 `layout()`（09-17 无头跑过七档），
/// 这里的期望是**按公式手算 + 跑出来核过**的数，不是抄的。
@MainActor
final class MacShellFrameTests: XCTestCase {
    typealias Cols = MacGridBudget.Columns
    let mac = WidgetGridSpec.mac
    let edges: CGFloat = 60   // 固定历史样张；新默认值另测，仍覆盖用户保留的旧参数。

    private func frame(_ w: CGFloat, h: CGFloat = 800, left: Bool = true, leftWidth: CGFloat = 240,
                       tool: Bool = true, toolWidth: CGFloat = 360, dock: Bool = true, side: DockSide = .right,
                       arrangement: DesktopArrangement = .a, cols: Cols? = nil) -> MacShellFrame {
        MacShellFrame.compute(width: w, height: h, spec: mac, arrangement: arrangement, dockSide: side,
                              dockShown: dock, leftShown: left, leftWidth: leftWidth,
                              toolShown: tool, toolWidth: toolWidth, cardEdges: edges, cols: cols)
    }

    // MARK: - 小样样张

    func testHistoricalSpacingGeometry() {
        XCTAssertEqual(edges, 60)
        XCTAssertEqual(MacShellFrame.cardMin(cardEdges: edges), 380)
        XCTAssertEqual(MacShellFrame.toolDefaultWidth, 360, "= 今天两列 2×164 + 2×16")
    }

    func testMintDefaultFitsMinimumWindowWithoutLosingSlots() {
        let frame = MacShellFrame.compute(width: 980, height: 600, spec: mac,
            arrangement: .a, dockSide: .left, dockShown: true,
            leftShown: true, leftWidth: 320, toolShown: true, toolWidth: 360,
            cardEdges: MacShellMetrics.defaultCardEdges, cols: nil)
        // 980 = 52 dock + 320 sidebar + 328 chat + 280 tools.
        XCTAssertEqual(frame.dock, 52)
        XCTAssertEqual(frame.conv, 320)
        XCTAssertEqual(frame.card, 328)
        XCTAssertEqual(frame.tool, 280)
        XCTAssertEqual(frame.card - MacShellMetrics.defaultCardEdges, 320)
    }

    func testSampleTable() {
        let a = frame(1280)
        XCTAssertEqual(a.card, 628); XCTAssertEqual(a.conv, 240); XCTAssertEqual(a.tool, 360)
        XCTAssertEqual(a.cols, Cols(conv: 0, tools: 0)); XCTAssertNil(a.grid, "两侧都开着就没有格子")

        let b = frame(980)
        XCTAssertEqual(b.tool, 308, "工具面板先让：360 → 308"); XCTAssertEqual(b.conv, 240); XCTAssertEqual(b.card, 380)

        let d = frame(960)
        XCTAssertEqual(d.tool, 288); XCTAssertEqual(d.card, 380)

        let c = frame(1600, left: false)
        XCTAssertEqual(c.cols, Cols(conv: 0, tools: 0)); XCTAssertEqual(c.leftLane, 0); XCTAssertEqual(c.card, 1188)
        XCTAssertNil(c.grid)

        let e = frame(1440, left: false, tool: false)
        XCTAssertEqual(e.cols, Cols(conv: 0, tools: 0)); XCTAssertEqual(e.card, 1388)
    }

    /// 让位顺序：卡 → 工具（到 280）→ 列表（到 240）。列表存 320 才看得出来（她存档是 240，两边不可分）
    func testToolYieldsBeforeList() {
        let f1100 = frame(1100, leftWidth: 320)
        XCTAssertEqual(f1100.conv, 320, "列表还没让"); XCTAssertEqual(f1100.tool, 348, "工具在让"); XCTAssertEqual(f1100.card, 380)
        let f1032 = frame(1032, leftWidth: 320)
        XCTAssertEqual(f1032.tool, 280, "工具到底"); XCTAssertEqual(f1032.conv, 320)
        let f1000 = frame(1000, leftWidth: 320)
        XCTAssertEqual(f1000.tool, 280); XCTAssertEqual(f1000.conv, 288, "工具到底之后列表才让")
        let f952 = frame(952, leftWidth: 320)
        XCTAssertEqual(f952.conv, 240); XCTAssertEqual(f952.tool, 280); XCTAssertEqual(f952.card, 380, "最小窗")
    }

    // MARK: - 不重叠的机器证明

    /// 任何宽度、任何开关组合：dock + 左槽 + 卡 + 右槽 == 窗宽；宽 ≥ 该配置最小窗时卡 ≥ 380
    func testFourSlotsAlwaysAddUpToWidth() {
        for w in stride(from: 900.0, through: 2200.0, by: 10.0) {
            for left in [false, true] { for tool in [false, true] { for dock in [false, true] {
                for side in [DockSide.left, .right] { for arr in [DesktopArrangement.a, .b] {
                    let f = frame(w, left: left, leftWidth: 320, tool: tool, dock: dock, side: side, arrangement: arr)
                    XCTAssertEqual(f.dock + f.leftLane + f.card + f.rightLane, w, accuracy: 0.001,
                                   "w=\(w) left=\(left) tool=\(tool) dock=\(dock) \(side) \(arr)")
                    let minWindow: CGFloat = (dock ? 52 : 0) + (left ? 240 : 0) + 380 + (tool ? 280 : 0)
                    if w >= minWindow {
                        XCTAssertGreaterThanOrEqual(f.card, 380, "w=\(w) left=\(left) tool=\(tool) dock=\(dock)")
                    }
                    if left { XCTAssertEqual(f.cols.conv, 0, "列表开着那一侧不能有列") }
                    if tool { XCTAssertEqual(f.cols.tools, 0, "工具面板开着那一侧不能有列") }
                    if arr == .b { XCTAssertEqual(f.cols.conv, 0, "排版 b 对话侧没有 zone") }
                }}
            }}}
        }
    }

    /// 卡边旋钮全档（默认 8 / 历史 60 / 极值 192，A I2）× 各开关：四槽恒等式始终成立；
    /// 正文下限只在「窗 ≥ 该配置最小窗」时保证——952 是 E=60 的几何下限，不是恒定最小窗
    func testSlotIdentityAcrossCardEdges() {
        for e in [8, 60, 192] as [CGFloat] {
            for w in stride(from: 980.0, through: 1800.0, by: 20.0) {
                for left in [false, true] { for tool in [false, true] {
                    let f = MacShellFrame.compute(width: w, height: 800, spec: mac, arrangement: .a, dockSide: .right,
                                                  dockShown: true, leftShown: left, leftWidth: 320,
                                                  toolShown: tool, toolWidth: 360, cardEdges: e)
                    XCTAssertEqual(f.dock + f.leftLane + f.card + f.rightLane, w, accuracy: 0.001, "e=\(e) w=\(w)")
                    let minWindow = 52 + (left ? 240 : 0) + MacShellFrame.cardMin(cardEdges: e) + (tool ? 280 : 0)
                    if w >= minWindow { XCTAssertGreaterThanOrEqual(f.card, MacShellFrame.cardMin(cardEdges: e) - 0.001) }
                }}
            }
        }
    }

    func testMinWindowFitsAppMinimum() {
        let minWindow: CGFloat = 52 + 240 + MacShellFrame.cardMin(cardEdges: edges) + MacShellFrame.toolMinWidth
        XCTAssertEqual(minWindow, 952)
        XCTAssertLessThanOrEqual(minWindow, 980, "MemoryPalaceApp .frame(minWidth: 980) 不用动")
    }

    // MARK: - 格子

    func testCollapsedPanelsNeverReserveSpaceEvenWithOldColumns() {
        for side in [DockSide.left, .right] {
            for arrangement in [DesktopArrangement.a, .b] {
                let f = frame(2200, left: false, tool: false, side: side,
                              arrangement: arrangement, cols: Cols(conv: 4, tools: 4))
                XCTAssertEqual(f.leftLane, 0)
                XCTAssertEqual(f.rightLane, 0)
                XCTAssertEqual(f.card, 2148) // 2200 - 52 dock, no panel-width cap.
                XCTAssertEqual(f.cardX, side == .left ? 52 : 0)
                XCTAssertNil(f.grid)
            }
        }
    }

    func testZeroSizeIsAllZeros() {
        let f = frame(0)
        XCTAssertEqual(f.card, 0); XCTAssertNil(f.grid); XCTAssertNil(f.conv); XCTAssertNil(f.tool)
    }

    // MARK: - 列数与滞回

    private func cols(_ w: CGFloat, left: Bool = false, tool: Bool = false, previous: Cols?) -> Cols {
        MacShellFrame.columns(width: w, spec: mac, arrangement: .a, dockShown: true,
                              leftShown: left, leftWidth: 240, toolShown: tool, toolWidth: 360,
                              cardEdges: edges, previous: previous)
    }

    func testOldDesktopColumnBudgetDoesNotConstrainReadingPanel() {
        XCTAssertEqual(cols(1440, previous: nil), Cols(conv: 0, tools: 0))
        XCTAssertEqual(cols(2200, previous: Cols(conv: 4, tools: 4)), Cols(conv: 0, tools: 0))
    }

    func testPreviousColumnsDropWhenPanelOpens() {
        XCTAssertEqual(cols(1440, left: true, previous: Cols(conv: 2, tools: 1)).conv, 0, "列表刚开：那一侧的旧列数作废")
        let f = frame(1440, left: true, tool: false, cols: Cols(conv: 2, tools: 1))
        XCTAssertEqual(f.leftLane, 240, "提交过的列数落在开着的面板那侧 → 槽宽是面板宽")
        XCTAssertEqual(f.cols.conv, 0)
    }

    // MARK: - 浮窗模式一行不动（从 MacShellRegressionTests 搬来）

    /// 浮窗的让位与聊天宽：与解耦刀锁的值逐值相同（`LaneDecoupleRegressionTests:49-59`）
    func testFloatingLanesUnchanged() {
        let spec = WidgetGridSpec.forScreen(CGSize(width: 1194, height: 834))
        let a = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .a, dockSide: .right)
        XCTAssertEqual(a.leftLane, 192); XCTAssertEqual(a.rightLane, 272); XCTAssertEqual(a.chatWidth, 730)
        XCTAssertEqual(a.top, 64, "浮窗 / iPad 的格子仍从胶囊底下起")
        let b = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .b, dockSide: .right)
        XCTAssertEqual(b.leftLane, 0); XCTAssertEqual(b.rightLane, 436); XCTAssertEqual(b.chatWidth, 758)
    }
}
