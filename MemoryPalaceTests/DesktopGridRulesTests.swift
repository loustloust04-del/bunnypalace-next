import XCTest
@testable import 记忆花园

/// 桌面格子纯规则：排位（存档优先 / 那侧没了搬过去 / 放不下不动档 / 排版 a 降 small）
/// 与拖放落格（越界 / 全空 / 对换 / 压两块 / 对方搬不回去）。
@MainActor
final class DesktopGridRulesTests: XCTestCase {
    static let suiteName = "xctest-desktop-grid-rules"
    var defaults: UserDefaults!
    var store: DesktopGridStore!
    let spec = WidgetGridSpec(small: 136, medium: 300)
    let pet = WidgetInstance(kind: .pet, size: .medium)
    let todo = WidgetInstance(kind: .todo, size: .small)
    var items: [DesktopItem] { [.widget(pet), .widget(todo), .tool("memory")] }

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        store = DesktopGridStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    /// 1194×834 停靠：a = 左 1 列 + 右 2 列（工具侧预留）；b = 右 2 列；都是 4 行
    private var gridA: GridFrame {
        GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .a, dockSide: .right,
                          dockInset: 0, reserveToolsSide: true)
    }
    private var gridB: GridFrame {
        GridFrame.compute(width: 1194, height: 834, spec: spec, arrangement: .b, dockSide: .right,
                          dockInset: 0, reserveToolsSide: true)
    }

    private func find(_ all: [DesktopPlaced], _ id: String) -> DesktopPlaced? { all.first { $0.id == id } }
    private func cell(_ p: DesktopPlaced) -> DesktopCell { .init(side: p.zone.side, col: p.col, row: p.row) }

    func testGridShape() {
        let a = gridA
        XCTAssertEqual(a.zone(.left)?.cols, 1)
        XCTAssertEqual(a.zone(.right)?.cols, 2)
        XCTAssertEqual(a.rows, 4)
        let b = gridB
        XCTAssertNil(b.zone(.left))
        XCTAssertEqual(b.zone(.right)?.cols, 2)
    }

    // MARK: 排位

    /// 没存过 → 按顺序填第一个区、从上到下
    func testFreshItemsFillFirstZoneTopDown() {
        let out = DesktopGridPlacer.place(items, grid: gridA, arrangement: .a, store: store)
        XCTAssertEqual(find(out, "w.pet").map(cell), DesktopCell(side: .left, col: 0, row: 0))
        XCTAssertEqual(find(out, "w.todo").map(cell), DesktopCell(side: .left, col: 0, row: 1))
        XCTAssertEqual(find(out, "t.memory").map(cell), DesktopCell(side: .left, col: 0, row: 2))
    }

    /// 排版 a 长条降成小方（1×1）
    func testArrangementADemotesToSmall() {
        let out = DesktopGridPlacer.place(items, grid: gridA, arrangement: .a, store: store)
        let p = find(out, "w.pet")!
        XCTAssertEqual(p.colSpan, 1)
        XCTAssertEqual(p.size, .small)
    }

    /// 排版 b 两列放得下长条：2×1，后来的填它下面那一行
    func testArrangementBKeepsMedium() {
        let out = DesktopGridPlacer.place(items, grid: gridB, arrangement: .b, store: store)
        let p = find(out, "w.pet")!
        XCTAssertEqual(p.colSpan, 2)
        XCTAssertEqual(p.size, .medium)
        XCTAssertEqual(cell(p), .init(side: .right, col: 0, row: 0))
        XCTAssertEqual(find(out, "w.todo").map(cell), DesktopCell(side: .right, col: 0, row: 1))
        XCTAssertEqual(find(out, "t.memory").map(cell), DesktopCell(side: .right, col: 1, row: 1))
    }

    /// 存过位置的照存的放，别人填空格
    func testStoredPlacementWins() {
        store.merge(["w.pet": .init(side: .right, col: 1, row: 3)], in: .a)
        let out = DesktopGridPlacer.place(items, grid: gridA, arrangement: .a, store: store)
        XCTAssertEqual(find(out, "w.pet").map(cell), DesktopCell(side: .right, col: 1, row: 3))
        XCTAssertEqual(find(out, "w.todo").map(cell), DesktopCell(side: .left, col: 0, row: 0))
    }

    /// 存的那一侧没了、只剩一道 → 按存的行列搬过去（否则组件整片消失）
    func testStoredSideGoneMovesToSoleZone() {
        store.merge(["w.pet": .init(side: .left, col: 0, row: 1)], in: .b)
        let out = DesktopGridPlacer.place(items, grid: gridB, arrangement: .b, store: store)
        XCTAssertEqual(find(out, "w.pet").map(cell), DesktopCell(side: .right, col: 0, row: 1))
    }

    /// 存的那一侧还在、只是这会儿放不下 → 先不显示，存档不动
    func testStoredSideExistsButDoesNotFitHidesItem() {
        store.merge(["w.todo": .init(side: .left, col: 0, row: 9)], in: .a)
        let out = DesktopGridPlacer.place(items, grid: gridA, arrangement: .a, store: store)
        XCTAssertNil(find(out, "w.todo"))
        XCTAssertEqual(store.placement(of: "w.todo", in: .a), DesktopGridStore.Placement(side: .left, col: 0, row: 9))
        XCTAssertNotNil(find(out, "w.pet"))
    }

    /// 排版各存一份：a 的存档不影响 b
    func testPlacementsArePerArrangement() {
        store.merge(["w.pet": .init(side: .right, col: 1, row: 3)], in: .a)
        XCTAssertNil(store.placement(of: "w.pet", in: .b))
    }

    /// merge 只写给的项、内容没变不落盘
    func testMergeIsAdditive() {
        store.merge(["w.pet": .init(side: .left, col: 0, row: 0)], in: .a)
        store.merge(["w.todo": .init(side: .left, col: 0, row: 1)], in: .a)
        XCTAssertEqual(store.placement(of: "w.pet", in: .a), DesktopGridStore.Placement(side: .left, col: 0, row: 0))
        XCTAssertEqual(store.placement(of: "w.todo", in: .a), DesktopGridStore.Placement(side: .left, col: 0, row: 1))
        let again = DesktopGridStore(defaults: defaults)
        XCTAssertEqual(again.placement(of: "w.todo", in: .a), DesktopGridStore.Placement(side: .left, col: 0, row: 1))
    }

    func testWidgetCells() {
        XCTAssertEqual(DesktopGridPlacer.widgetCells([pet, todo], arrangement: .a), 2)
        XCTAssertEqual(DesktopGridPlacer.widgetCells([pet, todo], arrangement: .b), 3)
        XCTAssertEqual(DesktopGridPlacer.widgetCells([WidgetInstance(kind: .garden, size: .large)], arrangement: .b), 4)
    }

    // MARK: 落格（排版 b：pet 2×1 在 (0,0)，todo (0,1)，memory (1,1)）

    private func placedB() -> [DesktopPlaced] {
        DesktopGridPlacer.place(items, grid: gridB, arrangement: .b, store: store)
    }

    func testDropPlanOutOfBounds() {
        let all = placedB()
        let todo = find(all, "w.todo")!
        XCTAssertFalse(DesktopDropRules.dropPlan(todo, at: .init(side: .right, col: 2, row: 0), all: all, grid: gridB).ok)
        XCTAssertFalse(DesktopDropRules.dropPlan(todo, at: .init(side: .left, col: 0, row: 0), all: all, grid: gridB).ok, "b 没有左区")
        XCTAssertFalse(DesktopDropRules.dropPlan(todo, at: .init(side: .right, col: 0, row: 4), all: all, grid: gridB).ok)
    }

    func testDropPlanEmptyCellLands() {
        let all = placedB()
        let plan = DesktopDropRules.dropPlan(find(all, "w.todo")!, at: .init(side: .right, col: 0, row: 2), all: all, grid: gridB)
        XCTAssertTrue(plan.ok)
        XCTAssertNil(plan.swap)
    }

    /// 恰好压住一块、对方整个搬得进我原位 → 对换
    func testDropPlanSwapsSingleOccupant() {
        let all = placedB()
        let plan = DesktopDropRules.dropPlan(find(all, "w.todo")!, at: .init(side: .right, col: 1, row: 1), all: all, grid: gridB)
        XCTAssertTrue(plan.ok)
        XCTAssertEqual(plan.swap?.id, "t.memory")
    }

    /// 长条压住两块 → 飞回
    func testDropPlanRefusesCoveringTwo() {
        let all = placedB()
        let plan = DesktopDropRules.dropPlan(find(all, "w.pet")!, at: .init(side: .right, col: 0, row: 1), all: all, grid: gridB)
        XCTAssertFalse(plan.ok)
    }

    /// 压住长条一块，但长条搬到我原位会压到第三块 → 飞回
    func testDropPlanRefusesWhenSwapTargetBlocked() {
        let all = placedB()
        let plan = DesktopDropRules.dropPlan(find(all, "w.todo")!, at: .init(side: .right, col: 0, row: 0), all: all, grid: gridB)
        XCTAssertFalse(plan.ok)
    }

    /// 覆盖计算去重、不含自己
    func testCoveredDedupsAndExcludesSelf() {
        let all = placedB()
        let pet = find(all, "w.pet")!
        XCTAssertTrue(DesktopDropRules.covered(pet, at: .init(side: .right, col: 0, row: 0), all: all).isEmpty)
        XCTAssertEqual(Set(DesktopDropRules.covered(pet, at: .init(side: .right, col: 0, row: 1), all: all).map(\.id)),
                       ["w.todo", "t.memory"])
    }
}
