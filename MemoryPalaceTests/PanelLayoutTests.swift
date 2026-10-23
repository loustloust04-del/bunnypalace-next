import XCTest
@testable import 记忆花园

/// `IPadPanelLayout` 的窗口代数：dock 三段 / 封顶顶掉 / 关闭接棒 / 浮出停回 / 缩起恢复 / 层级 / 存档。
/// A0 安全网（plan-mac-shape）：先把现役行为钉住，再动模型。存档走注入的 suite，不碰 .standard。
@MainActor
final class PanelLayoutTests: XCTestCase {
    static let suiteName = "xctest-panel-layout"
    var defaults: UserDefaults!
    var layout: IPadPanelLayout!
    /// iPad 11" 横屏：默认 screenSize 834×1194 → 令牌 136/300，停靠排版 a 有格子（(1+2) 列 × 4 行）
    let land = CGSize(width: 1194, height: 834)
    /// **缩成小组件**那几条用这个宽：测试跑在 mac 目标，停靠模式走 mac 停靠壳（plan-mac-fullscreen-shell-v2），
    /// 格子只在面板收起那一侧的空地上——1194 宽、工具面板开着（360）时两侧都没空地，缩不进去（设计如此）。
    /// 1800 宽：左空地 free = 1800 − 52 − 360 − 780 = 608 → 3 列（28 + 3×164 = 520）× 4 行 = **12 格**，跟原来的 12 恰好一致
    let roomy = CGSize(width: 1800, height: 834)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        layout = IPadPanelLayout(defaults: defaults)
        // 测试跑在 mac 目标，生产 gridSpec 是 mac 令牌；这里钉 iPad 11" 令牌，几何数字才是下面注释里的
        layout.gridSpecOverride = WidgetGridSpec(small: 136, medium: 300)
        // 卡边注自己的，不读 shared（她真机上调过的值），R4b
        layout.shellMetrics = MacShellMetrics(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    // MARK: dock

    /// 全屏模式点 dock 三段：没开 → 开成 tab 并选中；开着没选中 → 选中；已选中 → 关
    func testDockTapThreePhase() {
        XCTAssertEqual(layout.mode, .docked)
        layout.dockTap("memory")
        XCTAssertEqual(layout.openTools, ["memory"])
        XCTAssertEqual(layout.currentTab, "memory")
        layout.dockTap("vocab")
        XCTAssertEqual(layout.tabs, ["memory", "vocab"])
        XCTAssertEqual(layout.currentTab, "vocab")
        layout.dockTap("memory")
        XCTAssertEqual(layout.currentTab, "memory")
        XCTAssertEqual(layout.openTools.count, 2)
        layout.dockTap("memory")
        XCTAssertEqual(layout.openTools, ["vocab"])
        XCTAssertEqual(layout.currentTab, "vocab")
    }

    /// 浮窗模式点 dock = 开 ⇄ 关
    func testDockTapFloatingToggles() {
        layout.mode = .floating
        layout.dockTap("a")
        XCTAssertTrue(layout.isOpen("a"))
        layout.dockTap("a")
        XCTAssertFalse(layout.isOpen("a"))
    }

    /// 点一个浮出去的：提到最前，不关
    func testDockTapOnDetachedBringsToFront() {
        layout.open("a"); layout.open("b")
        layout.detach("a", in: land)
        layout.bringToFront("b")
        layout.dockTap("a")
        XCTAssertTrue(layout.isOpen("a"))
        XCTAssertEqual(layout.zOrder.last, "a")
    }

    // MARK: open / close

    /// 浮窗模式开到第 4 个顶掉最早的，且被顶的从层级 / 浮出名单里除名。
    /// （plan-panel-ps ②：上限 3 只管浮窗模式——有意变更，原来两模式共用）
    func testOpenEvictsOldest() {
        layout.open("a"); layout.open("b"); layout.open("c")
        layout.detach("a", in: land)
        layout.mode = .floating
        layout.open("d")
        XCTAssertEqual(layout.openTools, ["b", "c", "d"])
        XCTAssertFalse(layout.zOrder.contains("a"))
        XCTAssertFalse(layout.detached.contains("a"))
        XCTAssertEqual(layout.selectedTool, "d")
    }

    /// 停靠模式放宽到 12（她 09-24「PS 自己不卡」）：第 13 个才顶掉最早那个
    func testDockedModeOpensUpToTwelve() {
        for i in 0..<12 { layout.open("t\(i)") }
        XCTAssertEqual(layout.openTools.count, 12)
        XCTAssertEqual(layout.tabs.count, 12)
        layout.open("t12")
        XCTAssertEqual(layout.openTools.first, "t1")
        XCTAssertEqual(layout.openTools.count, 12)
    }

    /// 再开一个已开着的 tab：选中它，不重复
    func testOpenExistingSelects() {
        layout.open("a"); layout.open("b")
        layout.open("a")
        XCTAssertEqual(layout.openTools, ["a", "b"])
        XCTAssertEqual(layout.selectedTool, "a")
    }

    /// 关掉选中 tab：接棒优先右邻，没有右邻就左邻
    func testCloseHandsOverToNeighbor() {
        layout.open("a"); layout.open("b"); layout.open("c")
        layout.selectedTool = "b"
        layout.close("b")
        XCTAssertEqual(layout.currentTab, "c")
        layout.close("c")
        XCTAssertEqual(layout.currentTab, "a")
        layout.close("a")
        XCTAssertNil(layout.currentTab)
        XCTAssertTrue(layout.openTools.isEmpty)
    }

    func testCloseUnselectedKeepsSelection() {
        layout.open("a"); layout.open("b")
        layout.selectedTool = "a"
        layout.close("b")
        XCTAssertEqual(layout.currentTab, "a")
    }

    // MARK: 浮出 / 停回

    func testDetachAndAttach() {
        layout.open("a"); layout.open("b")
        layout.selectedTool = "a"
        layout.detach("a", in: land)
        XCTAssertEqual(layout.tabs, ["b"])
        XCTAssertTrue(layout.detached.contains("a"))
        XCTAssertNotNil(layout.frames["a"])
        XCTAssertEqual(layout.currentTab, "b")
        XCTAssertEqual(layout.zOrder.last, "a")
        XCTAssertEqual(layout.windowIds, ["a"], "全屏模式只把浮出去的画成窗")
        layout.attach("a")
        XCTAssertTrue(layout.detached.isEmpty)
        XCTAssertEqual(layout.selectedTool, "a")
        XCTAssertEqual(layout.tabs, ["a", "b"])
        XCTAssertTrue(layout.windowIds.isEmpty)
    }

    func testDetachIgnoresNonTab() {
        layout.detach("ghost", in: land)
        XCTAssertTrue(layout.detached.isEmpty)
    }

    /// 浮窗模式所有层级成员都是窗
    func testFloatingWindowIdsAreWholeZOrder() {
        layout.mode = .floating
        layout.open("a"); layout.open("b")
        layout.leftShown = true
        XCTAssertEqual(layout.windowIds, ["a", "b", IPadPanelLayout.convWindowId])
    }

    // MARK: 缩起 / 恢复

    /// 从 tab 缩：记 "tab"、出层级、tab 接棒、仍算开着；恢复回 tab 组并选中
    func testMinimizeFromTabRestoresAsTab() {
        layout.open("a"); layout.open("b")
        layout.selectedTool = "a"
        XCTAssertTrue(layout.minimize("a", in: roomy, widgetCells: 0))
        XCTAssertEqual(layout.minimized, ["a"])
        XCTAssertEqual(layout.minimizedFrom["a"], "tab")
        XCTAssertFalse(layout.zOrder.contains("a"))
        XCTAssertEqual(layout.tabs, ["b"])
        XCTAssertEqual(layout.currentTab, "b")
        XCTAssertTrue(layout.isOpen("a"))
        layout.restore("a")
        XCTAssertTrue(layout.minimized.isEmpty)
        XCTAssertNil(layout.minimizedFrom["a"])
        XCTAssertTrue(layout.detached.isEmpty)
        XCTAssertEqual(layout.currentTab, "a")
    }

    /// 从窗缩（浮窗模式）：记 "window"；恢复回最前
    func testMinimizeFromWindowRestoresToFront() {
        layout.mode = .floating
        layout.open("a"); layout.open("b")
        XCTAssertTrue(layout.minimize("a", in: land, widgetCells: 0))
        XCTAssertEqual(layout.minimizedFrom["a"], "window")
        XCTAssertEqual(layout.zOrder, ["b"])
        layout.restore("a")
        XCTAssertEqual(layout.zOrder.last, "a")
    }

    /// 格子满了不缩：1800×834 mac 停靠壳、工具面板开着 → 左空地 3 列 × 4 行 = 12 格（见 `roomy` 的注释）；
    /// 1194 宽两侧都没空地，容量 0，什么都缩不进去
    func testMinimizeRefusesWhenGridFull() {
        layout.open("a")
        XCTAssertFalse(layout.canMinimize("a", in: land, widgetCells: 0), "1194 双开：没空地就没格子")
        XCTAssertFalse(layout.canMinimize("a", in: roomy, widgetCells: 12))
        XCTAssertFalse(layout.minimize("a", in: roomy, widgetCells: 12))
        XCTAssertTrue(layout.minimized.isEmpty)
        XCTAssertTrue(layout.canMinimize("a", in: roomy, widgetCells: 11))
        XCTAssertTrue(layout.minimize("a", in: roomy, widgetCells: 11))
    }

    func testMinimizeRejectsClosedOrDuplicate() {
        XCTAssertFalse(layout.minimize("x", in: roomy, widgetCells: 0))
        layout.open("a")
        XCTAssertTrue(layout.minimize("a", in: roomy, widgetCells: 0))
        XCTAssertFalse(layout.minimize("a", in: roomy, widgetCells: 0))
        XCTAssertEqual(layout.minimized, ["a"])
    }

    /// 关掉一个缩起来的：从缩起名单里也除名
    func testCloseMinimizedForgetsIt() {
        layout.open("a")
        _ = layout.minimize("a", in: roomy, widgetCells: 0)
        layout.close("a")
        XCTAssertTrue(layout.minimized.isEmpty)
        XCTAssertNil(layout.minimizedFrom["a"])
    }

    // MARK: 层级

    /// 已在最前不动数组；否则挪到最后
    func testBringToFront() {
        layout.mode = .floating
        layout.open("a"); layout.open("b")
        layout.bringToFront("b")
        XCTAssertEqual(layout.zOrder, ["a", "b"])
        layout.bringToFront("a")
        XCTAssertEqual(layout.zOrder, ["b", "a"])
    }

    /// 对话窗进出层级跟 leftShown 走
    func testLeftShownDrivesConvWindowInZOrder() {
        layout.leftShown = true
        XCTAssertEqual(layout.zOrder.last, IPadPanelLayout.convWindowId)
        layout.leftShown = false
        XCTAssertFalse(layout.zOrder.contains(IPadPanelLayout.convWindowId))
    }

    // MARK: 存档

    /// 同一个 suite 起第二个实例读回全部字段
    func testSnapshotRoundTrip() {
        layout.mode = .floating
        layout.leftShown = true
        layout.leftWidth = 350
        layout.rightWidth = 280
        layout.open("a"); layout.open("b")
        layout.selectedTool = "a"
        layout.snapToEdges = false
        layout.arrangement = .b
        layout.dockSide = .left
        layout.frames["a"] = .init(x: 10, y: 20, w: 300, h: 200)
        let again = IPadPanelLayout(defaults: defaults)
        XCTAssertEqual(again.mode, .floating)
        XCTAssertTrue(again.leftShown)
        XCTAssertEqual(again.leftWidth, 350)
        XCTAssertEqual(again.rightWidth, 280)
        XCTAssertEqual(again.openTools, ["a", "b"])
        XCTAssertEqual(again.selectedTool, "a")
        XCTAssertFalse(again.snapToEdges)
        XCTAssertEqual(again.arrangement, .b)
        XCTAssertEqual(again.dockSide, .left)
        XCTAssertEqual(again.frames["a"], .init(x: 10, y: 20, w: 300, h: 200))
        XCTAssertEqual(again.zOrder.last, IPadPanelLayout.convWindowId)
    }

    /// 缩起来的存档回来仍是缩着的、不在层级里
    func testSnapshotKeepsMinimized() {
        layout.open("a"); layout.open("b")
        _ = layout.minimize("a", in: roomy, widgetCells: 0)
        let again = IPadPanelLayout(defaults: defaults)
        XCTAssertEqual(again.minimized, ["a"])
        XCTAssertEqual(again.minimizedFrom["a"], "tab")
        XCTAssertFalse(again.zOrder.contains("a"))
        XCTAssertEqual(again.tabs, ["b"])
    }

    /// 旧档 mode "magnetic"（已删的档）落回 .floating，整份存档不作废
    func testLegacyMagneticModeDecodes() {
        let json = """
        {"mode":"magnetic","leftShown":false,"dockShown":true,"leftWidth":320,"rightWidth":300,"openTools":["a"],"selectedTool":"a"}
        """
        defaults.set(Data(json.utf8), forKey: "ipad.panel.layout.v2")
        let again = IPadPanelLayout(defaults: defaults)
        XCTAssertEqual(again.mode, .floating)
        XCTAssertEqual(again.openTools, ["a"])
        XCTAssertTrue(again.snapToEdges, "旧档没这个字段 → 默认开")
    }

    /// 旧档里 detached / minimized 引用已不在 openTools 的工具要被过滤掉
    func testSnapshotFiltersStaleReferences() {
        let json = """
        {"mode":"docked","leftShown":false,"dockShown":true,"leftWidth":320,"rightWidth":300,"openTools":["a"],"selectedTool":"a","detached":["zombie"],"minimized":["a","ghost"],"minimizedFrom":{"a":"tab","ghost":"window"}}
        """
        defaults.set(Data(json.utf8), forKey: "ipad.panel.layout.v2")
        let again = IPadPanelLayout(defaults: defaults)
        XCTAssertEqual(again.detached, [])
        XCTAssertEqual(again.minimized, ["a"])
        XCTAssertEqual(again.minimizedFrom, ["a": "tab"])
    }

    /// 坏档解不出来 → 全部默认值，不崩
    func testCorruptSnapshotFallsBackToDefaults() {
        defaults.set(Data("not json".utf8), forKey: "ipad.panel.layout.v2")
        let again = IPadPanelLayout(defaults: defaults)
        XCTAssertEqual(again.mode, .docked)
        XCTAssertTrue(again.openTools.isEmpty)
        XCTAssertEqual(again.leftWidth, 320)
    }
    func testDockedDesktopSpaceExistsOnlyWhileToolsAreMinimized() {
        layout.open("a"); layout.open("b")
        let before = layout.macShellFrame(in: roomy)
        XCTAssertNil(before.grid)
        XCTAssertEqual(before.leftLane, 0)
        XCTAssertTrue(layout.minimize("a", in: roomy, widgetCells: 0))
        XCTAssertNotNil(layout.macShellFrame(in: roomy).grid)
        layout.restore("a")
        XCTAssertNil(layout.macShellFrame(in: roomy).grid)
        XCTAssertEqual(layout.macShellFrame(in: roomy).card, before.card)
    }

}
