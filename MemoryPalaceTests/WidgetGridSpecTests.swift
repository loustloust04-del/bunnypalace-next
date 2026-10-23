import XCTest
@testable import 记忆花园

/// iPad 桌面格子（plan-ipad-desktop-grid §1.1–1.2）：令牌查档 + 横向链纯函数。
final class WidgetGridSpecTests: XCTestCase {

    private let pro11 = CGSize(width: 1194, height: 834)

    func testPro11TokensFromHIG() {
        let s = WidgetGridSpec.forScreen(CGSize(width: 834, height: 1194))
        XCTAssertEqual(s.small, 136)
        XCTAssertEqual(s.gutter, 28)
        XCTAssertEqual(s.margin, 28)
        // 横着喂也认
        XCTAssertEqual(WidgetGridSpec.forScreen(pro11), s)
        // 没见过的屏走兜底
        XCTAssertEqual(WidgetGridSpec.forScreen(CGSize(width: 500, height: 900)), .fallback)
    }

    func testArrangementChatWidths() {
        let spec = WidgetGridSpec.forScreen(pro11)
        let a = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .a, dockSide: .right)
        let b = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .b, dockSide: .right)
        // a：两侧各 M+S+G，右侧再加 dock；b：没格子的那一侧聊天贴屏边，比 a 宽一道边距
        XCTAssertEqual(a.chatWidth, 730)
        XCTAssertEqual(b.chatWidth, 758)
        XCTAssertEqual(b.leftLane, 0)
        XCTAssertEqual(a.rows, 4)
        XCTAssertTrue(a.fits)
        XCTAssertEqual(a.zones.map(\.cols), [1, 1])
        XCTAssertEqual(b.zones.map(\.cols), [2])
    }

    func testPro13() {
        let spec = WidgetGridSpec.forScreen(CGSize(width: 1032, height: 1376))
        XCTAssertEqual(spec.small, 160)
        XCTAssertEqual(spec.gutter, 36)
        let g = GridFrame.compute(width: 1376, height: 1032, spec: spec, arrangement: .a, dockSide: .right)
        XCTAssertEqual(g.chatWidth, 824)
    }

    func testSplitTwoThirdsDoesNotFit() {
        let spec = WidgetGridSpec.forScreen(pro11)
        let g = GridFrame.compute(width: 796, height: 834, spec: spec, arrangement: .a, dockSide: .right)
        XCTAssertEqual(g.chatWidth, 332)
        XCTAssertFalse(g.fits)
    }

    /// 浮窗模式 dock 挪到左：数值跟解耦前**碰巧一样**（排版 a 两侧都是一列，对称），
    /// 但语义换了——左边那道现在是**对话侧**，右边那道是工具侧（09-16 解耦）
    func testDockLeftLanes() {
        let spec = WidgetGridSpec.forScreen(pro11)
        let g = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .a, dockSide: .left)
        XCTAssertEqual(g.dockX, 28)
        XCTAssertEqual(g.leftLane, 28 + 52 + 28 + 136 + 28)
        XCTAssertEqual(g.rightLane, 28 + 136 + 28)
        XCTAssertEqual(g.zone(.left)?.x, 28 + 52 + 28)
        XCTAssertEqual(g.zone(.right)?.x, 1194 - 28 - 136)
        // 解耦的实质：dock 在左时工具区**不再跟着去左边**
        XCTAssertEqual(g.zone(.right)?.cols, 1)
        XCTAssertEqual(g.zones.map(\.side), [.left, .right])
    }

    /// 全屏模式：工具侧固定两列给 tab 组盖（丙右），tab 组宽 = 2S + 2G 正好盖住两列 + 到 dock 的缝
    func testDockedReservesTwoColsOnToolsSide() {
        let spec = WidgetGridSpec.forScreen(pro11)
        let right = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .a, dockSide: .right,
                                      dockInset: 0, reserveToolsSide: true)
        XCTAssertEqual(right.zones.map(\.cols), [1, 2])
        XCTAssertEqual(right.rightLane, 28 + 300 + 28 + 52)
        XCTAssertEqual(right.chatWidth, 1194 - 192 - 408)
        XCTAssertEqual(right.toolPanelWidth, 328)
        // tab 组贴着 dock 往左 328，左边缘正好落在两列区的左边缘
        XCTAssertEqual(1194 - 52 - right.toolPanelWidth, right.zone(.right)!.x)
        // 09-16 解耦：dock 换到左边，**工具那两列仍在右**（左边换成对话侧那一列）
        let left = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .a, dockSide: .left,
                                     dockInset: 0, reserveToolsSide: true)
        XCTAssertEqual(left.zones.map(\.cols), [1, 2], "左 = 对话一列，右 = 工具两列")
        XCTAssertEqual(left.leftLane, 52 + 28 + 136 + 28, "dock 顶替外边距 + 对话一列")
        XCTAssertEqual(left.rightLane, 28 + 300 + 28, "工具两列，后面没有 dock")
        XCTAssertEqual(left.chatWidth, right.chatWidth, "聊天宽度与 dock 在哪无关")
    }

    func testDockFlushInDockedMode() {
        let spec = WidgetGridSpec.forScreen(pro11)
        let g = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .a, dockSide: .right, dockInset: 0)
        XCTAssertEqual(g.dockX, 1194 - 52)
        XCTAssertEqual(g.rightLane, 28 + 136 + 28 + 52)
        XCTAssertEqual(g.zone(.right)?.x, 1194 - 52 - 28 - 136)
    }

    func testCellFrameWalksTheGrid() {
        let spec = WidgetGridSpec.forScreen(pro11)
        let g = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .b, dockSide: .right)
        let z = g.zone(.right)!
        let c00 = g.cellFrame(zone: z, col: 0, row: 0)
        let c11 = g.cellFrame(zone: z, col: 1, row: 1)
        XCTAssertEqual(c00.origin, CGPoint(x: z.x, y: 64))
        XCTAssertEqual(c00.size, CGSize(width: 136, height: 136))
        XCTAssertEqual(c11.origin, CGPoint(x: z.x + 164, y: 64 + 164))
        let wide = g.cellFrame(zone: z, col: 0, row: 0, colSpan: 2, rowSpan: 2)
        XCTAssertEqual(wide.size, CGSize(width: 300, height: 300))
    }
}
