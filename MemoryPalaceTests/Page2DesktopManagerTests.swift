import XCTest
@testable import 记忆花园

/// Page2DesktopManager：dock/桌面双独立列表——懒播种快照、增删排、禁用过滤、持久化。
@MainActor
final class Page2DesktopManagerTests: XCTestCase {
    static let suiteName = "xctest-page2-desktop"

    var defaults: UserDefaults!
    var tm: RightPanelToolManager!
    var mgr: Page2DesktopManager!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        tm = RightPanelToolManager()
        tm.tools = [
            RightPanelTool(id: "a", name: "A", icon: "a.circle", order: 0),
            RightPanelTool(id: "b", name: "B", icon: "b.circle", order: 1),
            RightPanelTool(id: "c", name: "C", icon: "c.circle", order: 2),
            RightPanelTool(id: "d", name: "D", icon: "d.circle", isEnabled: false, order: 3),
        ]
        mgr = Page2DesktopManager(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    // 未播种：两个读取口都跟随 pinnedTools 现状（保持旧行为，画面不突变）
    func testUnseededFollowsPinnedTools() {
        XCTAssertEqual(mgr.desktopTools(tm).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(mgr.dockTools(tm).map(\.id), ["a", "b", "c"])
        XCTAssertNil(mgr.desktopAppIds)
        XCTAssertNil(mgr.dockToolIds)
        // 未播种期间全局 reorder 仍然双侧联动（现状行为）
        tm.tools[0].order = 9
        XCTAssertEqual(mgr.desktopTools(tm).map(\.id), ["b", "c", "a"])
        XCTAssertEqual(mgr.dockTools(tm).map(\.id), ["b", "c", "a"])
    }

    // 首次编辑 = 快照播种，此后与全局 order 脱钩
    func testFirstEditSeedsSnapshot() {
        mgr.removeFromDesktop("b", tm: tm)
        XCTAssertEqual(mgr.desktopAppIds, ["a", "c"])
        // 全局 order 再变，桌面不跟了
        tm.tools[0].order = 9
        XCTAssertEqual(mgr.desktopTools(tm).map(\.id), ["a", "c"])
        // dock 没编辑过，仍跟随
        XCTAssertEqual(mgr.dockTools(tm).map(\.id), ["b", "c", "a"])
    }

    func testDesktopAddRemoveMove() {
        mgr.removeFromDesktop("a", tm: tm)
        XCTAssertEqual(mgr.desktopTools(tm).map(\.id), ["b", "c"])
        mgr.addToDesktop("a", tm: tm)
        XCTAssertEqual(mgr.desktopTools(tm).map(\.id), ["b", "c", "a"])
        mgr.addToDesktop("a", tm: tm) // 去重
        XCTAssertEqual(mgr.desktopTools(tm).map(\.id), ["b", "c", "a"])
        mgr.moveDesktopApp("a", before: "b", tm: tm)
        XCTAssertEqual(mgr.desktopTools(tm).map(\.id), ["a", "b", "c"])
        mgr.moveDesktopApp("a", before: "ghost", tm: tm) // 目标不存在 → 挪到末尾
        XCTAssertEqual(mgr.desktopTools(tm).map(\.id), ["b", "c", "a"])
    }

    func testDockAddRemoveMove() {
        mgr.removeFromDock("c", tm: tm)
        XCTAssertEqual(mgr.dockTools(tm).map(\.id), ["a", "b"])
        mgr.addToDock("c", tm: tm)
        mgr.moveDock("c", before: "a", tm: tm)
        XCTAssertEqual(mgr.dockTools(tm).map(\.id), ["c", "a", "b"])
    }

    // 两列表互不相干：mac 逻辑本体
    func testDesktopAndDockIndependent() {
        mgr.removeFromDock("a", tm: tm)
        XCTAssertEqual(mgr.desktopTools(tm).map(\.id), ["a", "b", "c"], "dock 删了桌面还在")
        mgr.removeFromDesktop("b", tm: tm)
        XCTAssertEqual(mgr.dockTools(tm).map(\.id), ["b", "c"], "桌面删了 dock 还在")
    }

    // 设置页禁用 → 隐身不除名；重开 → 原位回来
    func testDisabledToolHiddenNotRemoved() {
        mgr.moveDesktopApp("c", before: "a", tm: tm) // 播种 ["c","a","b"]
        tm.tools[1].isEnabled = false // 禁 b
        XCTAssertEqual(mgr.desktopTools(tm).map(\.id), ["c", "a"])
        XCTAssertEqual(mgr.desktopAppIds, ["c", "a", "b"], "id 保留")
        tm.tools[1].isEnabled = true
        XCTAssertEqual(mgr.desktopTools(tm).map(\.id), ["c", "a", "b"])
    }

    // 持久化：新实例同 suite 回读
    func testPersistenceRoundtrip() {
        mgr.removeFromDesktop("a", tm: tm)
        mgr.addToDock("d", tm: tm)
        let reloaded = Page2DesktopManager(defaults: defaults)
        XCTAssertEqual(reloaded.desktopAppIds, ["b", "c"])
        XCTAssertEqual(reloaded.dockToolIds, ["a", "b", "c", "d"])
    }

    // 存档里的未知 id（工具下架）渲染时静默吞掉
    func testUnknownIdsFiltered() {
        defaults.set(["a", "ghost", "c"], forKey: "page2DesktopApps_v1")
        let m = Page2DesktopManager(defaults: defaults)
        XCTAssertEqual(m.desktopTools(tm).map(\.id), ["a", "c"])
    }

    // 钉禁用工具进 dock：id 记下，渲染过滤，启用后出现
    func testIsInDockAndPinDisabled() {
        XCTAssertTrue(mgr.isInDock("a", tm: tm))
        XCTAssertFalse(mgr.isInDock("d", tm: tm))
        mgr.addToDock("d", tm: tm)
        XCTAssertEqual(mgr.dockTools(tm).map(\.id), ["a", "b", "c"], "禁用中不显示")
        tm.tools[3].isEnabled = true
        XCTAssertEqual(mgr.dockTools(tm).map(\.id), ["a", "b", "c", "d"])
    }
}
