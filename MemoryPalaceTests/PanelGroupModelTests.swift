import XCTest
@testable import 记忆花园

/// 多组模型（plan-panel-ps 阶段 2a）：新字段全空 = 单组；跨组搬 / 新建组 / 回收 / 同组交棒 / 按组折叠 /
/// 停回回原组 / 缩起恢复回原组 / normalize 幂等 / 存档往返 / 模式往返
@MainActor
final class PanelGroupModelTests: XCTestCase {
    static let suiteName = "xctest-panel-group-model"
    var defaults: UserDefaults!
    var layout: IPadPanelLayout!
    let main = IPadPanelLayout.mainGroup
    let conv = IPadPanelLayout.convWindowId
    let land = CGSize(width: 1600, height: 900)
    /// 左空地够摆格子（见 PanelLayoutTests.roomy）
    let roomy = CGSize(width: 1800, height: 834)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        layout = IPadPanelLayout(defaults: defaults)
        layout.gridSpecOverride = WidgetGridSpec(small: 136, medium: 300)
        layout.shellMetrics = MacShellMetrics(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func reload() -> IPadPanelLayout {
        let l = IPadPanelLayout(defaults: defaults)
        l.gridSpecOverride = layout.gridSpecOverride
        l.shellMetrics = layout.shellMetrics
        return l
    }

    // MARK: 单组等价

    /// 没有任何分组操作：投影 = 主组 = 今天的 tabs，存档里没有新字段
    func testEmptyMappingIsSingleGroup() throws {
        layout.open("a"); layout.open("b"); layout.open("c")
        layout.detach("b", in: land)
        XCTAssertEqual(layout.tabs, ["a", "c"])
        XCTAssertEqual(layout.tabs(in: main), ["a", "c"])
        XCTAssertEqual(layout.columnGroups, IPadPanelLayout.defaultColumns)
        XCTAssertEqual(layout.selected(in: main), layout.currentTab)
        let snap = layout.snapshot()
        XCTAssertNil(snap.dockGroupOf)
        XCTAssertNil(snap.columns)
        XCTAssertNil(snap.groupSelected)
        XCTAssertNil(snap.bottomHeight)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(snap), encoding: .utf8))
        XCTAssertFalse(json.contains("columns"), "单组存档与旧格式同形")
    }

    // MARK: 新建组 / 跨组搬

    func testInsertGroupOnRight() throws {
        layout.open("a"); layout.open("b"); layout.open("c")
        let g = try XCTUnwrap(layout.insertGroup(with: "c", edge: .right, at: 1))
        XCTAssertEqual(layout.columnGroups[.right], [main, g])
        XCTAssertEqual(layout.tabs(in: main), ["a", "b"])
        XCTAssertEqual(layout.tabs(in: g), ["c"])
        XCTAssertEqual(layout.tabs, ["a", "b", "c"])
        XCTAssertEqual(layout.selected(in: g), "c")
        XCTAssertEqual(layout.currentTab, "c")
        XCTAssertEqual(layout.selected(in: main), "b", "主组失去焦点后兜底到它自己的末个")
    }

    /// 工具停左：左列可见（即使对话列表收着），投影 右 → 左
    func testInsertGroupOnLeft() throws {
        layout.open("a"); layout.open("b")
        XCTAssertFalse(layout.leftColumnVisible)
        let g = try XCTUnwrap(layout.insertGroup(with: "a", edge: .left, at: 1))
        XCTAssertEqual(layout.columnGroups[.left], [conv, g])
        XCTAssertTrue(layout.leftColumnVisible)
        XCTAssertEqual(layout.visibleGroups(.left), [g], "对话列表收着，哨兵不画")
        XCTAssertEqual(layout.tabs, ["b", "a"])
        layout.leftShown = true
        XCTAssertEqual(layout.visibleGroups(.left), [conv, g])
    }

    func testMoveAcrossGroups() throws {
        layout.open("a"); layout.open("b"); layout.open("c")
        let g = try XCTUnwrap(layout.insertGroup(with: "c", edge: .right, at: 1))
        layout.move("b", toGroup: g, at: 0)
        XCTAssertEqual(layout.tabs(in: g), ["b", "c"])
        XCTAssertEqual(layout.tabs(in: main), ["a"])
        XCTAssertEqual(layout.selected(in: g), "b")
        XCTAssertEqual(layout.selectedTool, "b")
        XCTAssertEqual(Set(layout.openTools), ["a", "b", "c"])
    }

    /// 最后一个成员搬走 → 组从列里摘掉、映射清空
    func testEmptiedGroupIsPruned() throws {
        layout.open("a"); layout.open("b"); layout.open("c")
        let g = try XCTUnwrap(layout.insertGroup(with: "c", edge: .right, at: 1))
        layout.move("c", toGroup: main, at: 0)
        XCTAssertEqual(layout.columnGroups[.right], [main])
        XCTAssertTrue(layout.dockGroupOf.isEmpty)
        XCTAssertEqual(layout.tabs(in: main), ["c", "a", "b"])
        XCTAssertNil(layout.groupSelected[g])
    }

    /// 主组空了也不回收
    func testMainGroupNeverPruned() throws {
        layout.open("a")
        _ = try XCTUnwrap(layout.insertGroup(with: "a", edge: .left, at: 1))
        XCTAssertTrue(layout.columnGroups[.right]!.contains(main))
        XCTAssertTrue(layout.tabs(in: main).isEmpty)
    }

    /// 同组换位只动同组成员在 openTools 里的槽
    func testMoveTabStaysInGroup() throws {
        layout.open("a"); layout.open("b"); layout.open("c"); layout.open("d")
        let g = try XCTUnwrap(layout.insertGroup(with: "b", edge: .right, at: 1))
        layout.move("d", toGroup: g, at: 1)
        XCTAssertEqual(layout.tabs(in: g), ["b", "d"])
        layout.moveTab("d", to: 0)
        XCTAssertEqual(layout.tabs(in: g), ["d", "b"])
        XCTAssertEqual(layout.tabs(in: main), ["a", "c"])
    }

    // MARK: 关闭 / 选中 / 折叠

    /// 关掉选中的：同组邻居接棒，不跳到别的组
    func testCloseHandsOverWithinGroup() throws {
        layout.open("a"); layout.open("b"); layout.open("c"); layout.open("d")
        let g = try XCTUnwrap(layout.insertGroup(with: "c", edge: .right, at: 1))
        layout.move("d", toGroup: g, at: 1)
        layout.select("c")
        layout.close("c")
        XCTAssertEqual(layout.selectedTool, "d")
        XCTAssertEqual(layout.tabs(in: g), ["d"])
    }

    func testCloseLastPrunesGroup() throws {
        layout.open("a"); layout.open("b")
        let g = try XCTUnwrap(layout.insertGroup(with: "b", edge: .bottom, at: 0))
        layout.close("b")
        XCTAssertEqual(layout.columnGroups[.bottom], [])
        XCTAssertNil(layout.edge(of: g))
        XCTAssertEqual(layout.currentTab, "a")
    }

    func testCollapsePerGroup() throws {
        layout.open("a"); layout.open("b")
        let g = try XCTUnwrap(layout.insertGroup(with: "b", edge: .right, at: 1))
        layout.setCollapsed(g, true)
        XCTAssertTrue(layout.isCollapsed(g))
        XCTAssertFalse(layout.isCollapsed(main))
        XCTAssertFalse(layout.tabGroupCollapsed)
        layout.setCollapsed(main, true)
        XCTAssertTrue(layout.tabGroupCollapsed)
        layout.select("b")
        XCTAssertFalse(layout.isCollapsed(g), "选中即展开它的组")
        XCTAssertTrue(layout.isCollapsed(main), "别的组不受牵连")
    }

    /// dock 点别组里的工具：先选中（焦点移过去），再点才关
    func testDockTapAcrossGroups() throws {
        layout.open("a"); layout.open("b")
        _ = try XCTUnwrap(layout.insertGroup(with: "b", edge: .right, at: 1))
        layout.select("a")
        layout.dockTap("b")
        XCTAssertEqual(layout.currentTab, "b")
        XCTAssertTrue(layout.isOpen("b"))
        layout.dockTap("b")
        XCTAssertFalse(layout.isOpen("b"))
    }

    // MARK: 几何消费者 / 移栏（2b）

    /// 左列只有工具组（对话列表收着）：停靠壳左槽照样让出列宽，四槽恒等
    func testLeftToolColumnTakesLeftLane() throws {
        layout.open("a"); layout.open("b")
        XCTAssertNil(layout.macShellFrame(in: land).conv)
        _ = try XCTUnwrap(layout.insertGroup(with: "a", edge: .left, at: 1))
        let f = layout.macShellFrame(in: land)
        XCTAssertNotNil(f.conv)
        XCTAssertEqual(f.dock + f.leftLane + f.card + f.rightLane, land.width, accuracy: 0.001)
        XCTAssertTrue(layout.macToolShown, "右列还有 b")
        layout.move("b", toGroup: layout.columnGroups[.left]![1], at: 1)
        XCTAssertFalse(layout.macToolShown, "右列空了、也没有浮着的 → 右槽收起")
    }

    /// 左列折成图标：左槽让出来
    func testCollapsedLeftColumnHidesLane() throws {
        layout.open("a")
        _ = try XCTUnwrap(layout.insertGroup(with: "a", edge: .left, at: 1))
        layout.collapsedColumns.insert(.left)
        XCTAssertFalse(layout.leftColumnVisible)
        XCTAssertNil(layout.macShellFrame(in: land).conv)
    }

    func testMoveToColumnMenu() {
        layout.open("a"); layout.open("b"); layout.open("c")
        layout.moveMacPanel("b", toColumn: .left, in: land)
        let left = layout.columnGroups[.left]!
        XCTAssertEqual(left.count, 2, "左列没有工具组 → 新开一个")
        XCTAssertEqual(layout.tabs(in: left[1]), ["b"])
        layout.moveMacPanel("c", toColumn: .left, in: land)
        XCTAssertEqual(layout.tabs(in: left[1]), ["b", "c"], "有工具组 → 进它的尾巴")
        layout.dockShown = false
        layout.moveMacPanel("b", toColumn: .right, in: land)
        XCTAssertEqual(layout.tabs(in: main), ["a", "b"])
        XCTAssertTrue(layout.dockShown, "移到右栏顺手把右栏打开")
    }

    // MARK: 浮出 / 停回 / 缩起

    /// 浮出后组还在（成员映射保留），停回回原组
    func testDetachAttachReturnsToOriginalGroup() throws {
        layout.open("a"); layout.open("b"); layout.open("c")
        let g = try XCTUnwrap(layout.insertGroup(with: "c", edge: .left, at: 1))
        layout.detach("c", in: land)
        XCTAssertEqual(layout.edge(of: g), .left, "浮着的成员还映射在组上，组不回收")
        XCTAssertTrue(layout.tabs(in: g).isEmpty)
        XCTAssertEqual(layout.windowIds, ["c"], "窗口 id 仍是工具 id")
        layout.attach("c")
        XCTAssertEqual(layout.tabs(in: g), ["c"])
        XCTAssertEqual(layout.currentTab, "c")
    }

    /// 原组被抹掉（映射指向不在列里的组）→ 停回主组
    func testAttachFallsBackToMain() {
        layout.open("a"); layout.open("b")
        layout.detach("b", in: land)
        layout.dockGroupOf["b"] = "g.gone"
        XCTAssertEqual(layout.group(of: "b"), main)
        layout.attach("b")
        XCTAssertEqual(layout.tabs(in: main), ["a", "b"])
        XCTAssertNil(layout.dockGroupOf["b"])
    }

    /// 浮着的停进指定组的指定槽
    func testAttachToGroupAtSlot() throws {
        layout.open("a"); layout.open("b"); layout.open("c")
        let g = try XCTUnwrap(layout.insertGroup(with: "c", edge: .right, at: 1))
        layout.detach("a", in: land)
        layout.attach("a", to: g, at: 0)
        XCTAssertEqual(layout.tabs(in: g), ["a", "c"])
        XCTAssertTrue(layout.detached.isEmpty)
        XCTAssertEqual(layout.tabs(in: main), ["b"])
    }

    func testMinimizeRestoreReturnsToGroup() throws {
        layout.open("a"); layout.open("b")
        let g = try XCTUnwrap(layout.insertGroup(with: "b", edge: .right, at: 1))
        XCTAssertTrue(layout.minimize("b", in: roomy, widgetCells: 0))
        XCTAssertEqual(layout.minimizedFrom["b"], "tab")
        XCTAssertEqual(layout.edge(of: g), .right)
        layout.restore("b")
        XCTAssertEqual(layout.tabs(in: g), ["b"])
    }

    // MARK: 存档

    func testRoundTrip() throws {
        layout.open("a"); layout.open("b"); layout.open("c")
        let g = try XCTUnwrap(layout.insertGroup(with: "c", edge: .left, at: 1))
        layout.setCollapsed(g, true)
        layout.groupWeights[g] = 2
        layout.bottomHeight = 300
        layout.collapsedColumns = [.bottom]
        let again = reload()
        XCTAssertEqual(again.columnGroups, layout.columnGroups)
        XCTAssertEqual(again.dockGroupOf, ["c": g])
        XCTAssertEqual(again.tabs(in: g), ["c"])
        XCTAssertTrue(again.isCollapsed(g))
        XCTAssertEqual(again.groupWeights[g], 2)
        XCTAssertEqual(again.bottomHeight, 300)
        XCTAssertEqual(again.collapsedColumns, [.bottom])
    }

    /// 坏档：重复 / 串列 / 未知组 / 哨兵错位 / 映射到主组 / 孤立选中 → 修成合法、且再修不变
    func testNormalizeRepairsAndIsIdempotent() {
        let json = """
        {"mode":"docked","leftShown":false,"dockShown":true,"leftWidth":320,"rightWidth":300,
         "openTools":["a","a","b","c"],"selectedTool":"a",
         "columns":{"left":["g.x","g.x"],"right":["g.x","conv"],"bottom":["g.y"],"top":["g.z"]},
         "dockGroupOf":{"a":"g.x","ghost":"g.x","b":"g.none","c":"g.main"},
         "groupSelected":{"g.x":"b","g.y":"q"},"groupCollapsed":["g.y"],
         "groupWeights":{"g.x":-1,"g.y":2}}
        """
        defaults.set(Data(json.utf8), forKey: "ipad.panel.layout.v2")
        let l = reload()
        XCTAssertEqual(l.openTools, ["a", "b", "c"])
        XCTAssertEqual(l.columnGroups[.left], [conv, "g.x"])
        XCTAssertEqual(l.columnGroups[.right], [main])
        XCTAssertEqual(l.columnGroups[.bottom], [])
        XCTAssertEqual(l.dockGroupOf, ["a": "g.x"])
        XCTAssertTrue(l.groupSelected.isEmpty, "选中不是该组成员")
        XCTAssertTrue(l.groupCollapsed.isEmpty)
        XCTAssertTrue(l.groupWeights.isEmpty)
        XCTAssertEqual(l.tabs, ["b", "c", "a"])
        l.flushPendingSave()
        let first = l.snapshot()
        let again = reload()
        XCTAssertEqual(again.snapshot(), first)
    }

    /// 旧档（没有任何新字段）→ 单组
    func testLegacyArchiveIsSingleGroup() {
        let json = """
        {"mode":"docked","leftShown":true,"dockShown":true,"leftWidth":320,"rightWidth":300,"openTools":["a","b"],"selectedTool":"b","detached":["a"]}
        """
        defaults.set(Data(json.utf8), forKey: "ipad.panel.layout.v2")
        let l = reload()
        XCTAssertEqual(l.columnGroups, IPadPanelLayout.defaultColumns)
        XCTAssertEqual(l.tabs, ["b"])
        XCTAssertEqual(l.detached, ["a"])
        XCTAssertNil(l.snapshot().columns)
    }

    // MARK: 模式往返

    /// 停靠 → 浮窗：浮窗模式照旧（每个工具一扇窗、层级是工具 id）；→ 停靠：分组原样
    func testModeRoundTripKeepsGroups() throws {
        layout.open("a"); layout.open("b"); layout.open("c")
        let g = try XCTUnwrap(layout.insertGroup(with: "c", edge: .left, at: 1))
        layout.mode = .floating
        XCTAssertEqual(Set(layout.windowIds), ["a", "b", "c"])
        layout.mode = .docked
        XCTAssertEqual(layout.tabs(in: g), ["c"])
        XCTAssertEqual(layout.tabs(in: main), ["a", "b"])
    }

    /// 出厂布局：分组全清、工具都回主组
    func testFactoryClearsGroups() throws {
        layout.open("a"); layout.open("b")
        _ = try XCTUnwrap(layout.insertGroup(with: "b", edge: .left, at: 1))
        layout.apply(layout.factorySnapshot())
        XCTAssertEqual(layout.columnGroups, IPadPanelLayout.defaultColumns)
        XCTAssertEqual(layout.tabs(in: main), ["a", "b"])
    }
}
