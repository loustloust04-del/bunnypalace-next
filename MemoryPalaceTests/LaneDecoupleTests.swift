import XCTest
@testable import 记忆花园

/// 泳道解耦（09-16）：工具恒右 / 列表恒左 / `dockSide` 只管图标条。
/// 回归网在 `LaneDecoupleRegressionTests`（dock 在右逐值不变）；这里验**新行为**和**不变量**。
@MainActor
final class LaneDecoupleTests: XCTestCase {

    private let pro11 = CGSize(width: 1194, height: 834)
    private var spec: WidgetGridSpec { WidgetGridSpec.forScreen(pro11) }

    private func frame(_ arrangement: DesktopArrangement, _ side: DockSide) -> GridFrame {
        GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: arrangement, dockSide: side,
                          dockInset: 0, reserveToolsSide: true)
    }

    /// **不变量**：聊天宽度与 dock 在哪无关。
    /// 这是「`MacGridBudget` 的滞回一行都不用改」的地基（plan-lane-decouple §2.4 / R-LD #5），
    /// 也是排版 b + dock 左「不留缝」那个取舍的理由——留缝会把这条打破。
    func testChatWidthIsIndependentOfDockSide() {
        XCTAssertEqual(frame(.a, .left).chatWidth, frame(.a, .right).chatWidth)
        XCTAssertEqual(frame(.b, .left).chatWidth, frame(.b, .right).chatWidth)
    }

    /// 工具那一侧恒在右：dock 挪到左边，工具的列还在右边
    func testToolsZoneStaysRightWhenDockGoesLeft() {
        let left = frame(.a, .left)
        XCTAssertEqual(left.zone(.right)?.cols, 2, "工具两列恒在右")
        XCTAssertEqual(left.zone(.left)?.cols, 1, "对话一列恒在左")
        XCTAssertEqual(left.dockX, 0, "dock 贴左边（全屏 inset 0）")
        XCTAssertEqual(left.leftLane, 244)
        XCTAssertEqual(left.rightLane, 356)
    }

    /// 排版 b 任何时候都**只发一道 zone**——`DesktopGridRules` 的换侧搬迁写死了 `zones.count == 1`，
    /// 多发一道 0 列的会让存档对不上的组件整片锁死（R-LD #2 阻断）
    func testArrangementBAlwaysSingleZone() {
        for side in DockSide.allCases {
            let g = frame(.b, side)
            XCTAssertEqual(g.zones.count, 1, "b / dock \(side.rawValue) 应只有一道 zone")
            XCTAssertEqual(g.zones.first?.side, .right, "b 的两列恒在右（她 09-16：固定右）")
        }
    }

    /// dock 在左时右边没有 dock，不该再给它留位置
    func testNoPhantomDockGutterOnTheEmptySide() {
        XCTAssertEqual(frame(.a, .left).rightLane, frame(.a, .right).rightLane - WidgetGridSpec.dockWidth)
    }

    // MARK: - 存档迁移

    /// 旧 `dockSide == .left` 的人：排版 a 的组件按侧翻一次（工具侧的去右、对话侧的来左）。
    /// 不翻的话两侧新旧都在 → `DesktopGridRules` 一次都不搬 → 组件留在原地被面板盖住（R-LD #3）
    func testMigrationFlipsArrangementAWhenDockWasLeft() {
        let suite = "xctest-lane-migrate-left"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = DesktopGridStore(defaults: defaults)
        store.merge(["w.pet": .init(side: .left, col: 0, row: 1)], in: .a)
        store.merge(["w.clock": .init(side: .right, col: 1, row: 0)], in: .a)
        store.merge(["w.note": .init(side: .left, col: 0, row: 0)], in: .b)

        store.migrateForLaneDecouple(oldDockSide: .left)
        XCTAssertEqual(store.placement(of: "w.pet", in: .a)?.side, .right, "原来在工具侧（左）→ 去右")
        XCTAssertEqual(store.placement(of: "w.pet", in: .a)?.row, 1, "行列不动")
        XCTAssertEqual(store.placement(of: "w.clock", in: .a)?.side, .left)
        XCTAssertEqual(store.placement(of: "w.note", in: .b)?.side, .left, "排版 b 不碰——单 zone 搬迁会自己走")

        // 只跑一次
        store.migrateForLaneDecouple(oldDockSide: .left)
        XCTAssertEqual(store.placement(of: "w.pet", in: .a)?.side, .right, "第二次调用不该再翻回去")
        defaults.removePersistentDomain(forName: suite)
    }

    /// 旧 `dockSide == .right` 的人本来就是目标形状，一个都不许动
    func testMigrationNoOpWhenDockWasRight() {
        let suite = "xctest-lane-migrate-right"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = DesktopGridStore(defaults: defaults)
        store.merge(["w.pet": .init(side: .left, col: 0, row: 0)], in: .a)
        store.migrateForLaneDecouple(oldDockSide: .right)
        XCTAssertEqual(store.placement(of: "w.pet", in: .a)?.side, .left)
        defaults.removePersistentDomain(forName: suite)
    }
}
