import XCTest
@testable import 记忆花园

/// **回归网**：dock / 工具侧 / 列表侧解耦这一刀的安全绳（plan-lane-decouple T0）。
///
/// 口径：工具面板改成恒在右之后，**`dockSide == .right` 这一档的每个数值都必须跟解耦前一模一样**
/// ——那一档本来工具就在右，形状没理由变。这份文件在动实现之前先写，数值取自解耦前的实际输出。
///
/// 两条破口是特意点名的（R-LD #1：我的第一版公式草稿正好从这两个网眼漏过去）：
/// - 排版 b 的空侧 `leftLane == 0`（连外边距都不留，跟 mac 降列的 0 列不是一个口径）
/// - mac 降列 `convCols == 0` 时 `leftLane == m`（只留外边距，不是 m + g）
///
/// **这份文件里的断言改一个都算实现错了**，不许为了让测试绿改期望。
final class LaneDecoupleRegressionTests: XCTestCase {

    private let pro11 = CGSize(width: 1194, height: 834)
    private var spec: WidgetGridSpec { WidgetGridSpec.forScreen(pro11) }

    // MARK: - 全屏（停靠）模式：dockInset 0，工具侧预留两列

    func testDockedRightArrangementA() {
        let g = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .a, dockSide: .right,
                                  dockInset: 0, reserveToolsSide: true)
        XCTAssertEqual(g.leftLane, 192)          // m + 1 列 + g
        XCTAssertEqual(g.rightLane, 408)         // g + 2 列 + g + dock52
        XCTAssertEqual(g.dockX, 1142)
        XCTAssertEqual(g.chatWidth, 594)
        XCTAssertEqual(g.zone(.left)?.x, 28)
        XCTAssertEqual(g.zone(.left)?.cols, 1)
        XCTAssertEqual(g.zone(.right)?.x, 814)
        XCTAssertEqual(g.zone(.right)?.cols, 2)
    }

    /// **破口一**：排版 b 的空侧是 0，不是 m、更不是 m+g
    func testDockedRightArrangementB_emptySideIsZero() {
        let g = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .b, dockSide: .right,
                                  dockInset: 0, reserveToolsSide: true)
        XCTAssertEqual(g.leftLane, 0, "排版 b 没格子的那一侧聊天贴屏边，连外边距都不留")
        XCTAssertEqual(g.rightLane, 408)
        XCTAssertEqual(g.dockX, 1142)
        XCTAssertEqual(g.chatWidth, 786)
        XCTAssertEqual(g.zones.count, 1, "b 只发一道 zone——换侧搬迁靠这个（DesktopGridRules 写死 zones.count == 1）")
        XCTAssertEqual(g.zone(.right)?.x, 814)
        XCTAssertEqual(g.zone(.right)?.cols, 2)
    }

    // MARK: - 浮窗模式：dockInset = m，工具侧不预留

    func testFloatingRightBothArrangements() {
        let a = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .a, dockSide: .right)
        XCTAssertEqual(a.leftLane, 192)
        XCTAssertEqual(a.rightLane, 272)
        XCTAssertEqual(a.dockX, 1114)
        XCTAssertEqual(a.chatWidth, 730)

        let b = GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .b, dockSide: .right)
        XCTAssertEqual(b.leftLane, 0)
        XCTAssertEqual(b.rightLane, 436)
        XCTAssertEqual(b.chatWidth, 758)
    }

    // MARK: - mac 降列

    /// **破口二**：对话侧降到 0 列时只留外边距（16），那一侧的 zone 仍在（cols 0 = 「还在只是放不下」）
    func testMacZeroConvColsKeepsOnlyMargin() {
        let g = GridFrame.compute(width: 980, height: 600, spec: .mac, arrangement: .a, dockSide: .right,
                                  dockInset: 0, reserveToolsSide: true, convCols: 0, toolsCols: 2)
        XCTAssertTrue(g.fits)
        XCTAssertEqual(g.leftLane, 16, "0 列只留 m，不是 m + g")
        XCTAssertEqual(g.rightLane, 428)
        XCTAssertEqual(g.zone(.left)?.cols, 0)
    }
}
