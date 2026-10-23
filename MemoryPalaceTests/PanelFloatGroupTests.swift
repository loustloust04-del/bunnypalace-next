import XCTest
@testable import 记忆花园

/// 多 tab 浮窗（plan-panel-ps 阶段 3）：并入 / 换位 / 拆出 / 换锚 / 整窗停回 / 关窗 / 缩恢复 / 浮窗模式不受影响 / 存档
@MainActor
final class PanelFloatGroupTests: XCTestCase {
    static let suiteName = "xctest-panel-float-group"
    var defaults: UserDefaults!
    var layout: IPadPanelLayout!
    let land = CGSize(width: 1600, height: 900)
    let roomy = CGSize(width: 1800, height: 834)
    typealias F = IPadPanelLayout.WindowFrame

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        layout = IPadPanelLayout(defaults: defaults)
        layout.gridSpecOverride = WidgetGridSpec(small: 136, medium: 300)
        layout.shellMetrics = MacShellMetrics(defaults: defaults)
        layout.open("a"); layout.open("b"); layout.open("c")
        layout.detach("a", in: land)
        layout.frames["a"] = F(x: 100, y: 100, w: 400, h: 300)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    /// 停靠的 tab 拖进浮窗：成了那扇窗的第二个 tab、选中它；窗口 id 仍只有锚
    func testMergeDockedTabIntoWindow() {
        layout.merge("b", into: "a")
        XCTAssertEqual(layout.floatMembers(of: "a"), ["a", "b"])
        XCTAssertEqual(layout.floatSelection(in: "a"), "b")
        XCTAssertEqual(layout.windowIds, ["a"])
        XCTAssertEqual(layout.tabs, ["c"])
        XCTAssertEqual(layout.detached, ["a", "b"])
        XCTAssertEqual(layout.windowId(of: "b"), "a")
    }

    /// 两扇窗合并：被拖的那扇窗的 tab 进目标窗
    func testMergeWindowIntoWindow() {
        layout.detach("b", in: land)
        layout.merge("b", into: "a")
        XCTAssertEqual(layout.windowIds, ["a"])
        XCTAssertEqual(layout.floatMembers(of: "a"), ["a", "b"])
    }

    /// 带槽位并入 = 在窗里换位（仍只置换 openTools 里成员的槽）
    func testMergeAtSlotReorders() {
        layout.merge("b", into: "a")
        layout.merge("c", into: "a", at: 0)
        XCTAssertEqual(layout.floatMembers(of: "a"), ["c", "a", "b"])
        layout.merge("b", into: "a", at: 0)
        XCTAssertEqual(layout.floatMembers(of: "a"), ["b", "c", "a"])
    }

    /// 拖成员出来落在工作区：自己一扇窗，尺寸跟原窗一样
    func testTearMemberOut() {
        layout.merge("b", into: "a")
        layout.detach("b", at: CGPoint(x: 800, y: 400), in: land)
        XCTAssertNil(layout.floatGroupOf["b"])
        XCTAssertEqual(Set(layout.windowIds), ["a", "b"])
        XCTAssertEqual(layout.frames["b"]?.w, 400)
        XCTAssertEqual(layout.frames["b"]?.x, 600)
    }

    /// 拖锚出来：窗（框、层级位置）交给下一个成员，锚自己成新窗
    func testTearAnchorOutReanchors() {
        layout.merge("b", into: "a")
        layout.merge("c", into: "a")
        layout.detach("a", at: CGPoint(x: 800, y: 400), in: land)
        XCTAssertEqual(layout.floatMembers(of: "b"), ["b", "c"])
        XCTAssertEqual(layout.frames["b"], F(x: 100, y: 100, w: 400, h: 300))
        XCTAssertEqual(Set(layout.windowIds), ["a", "b"])
        XCTAssertEqual(layout.zOrder.last, "a")
    }

    /// 关掉锚（dock 点 / tab ×）：其余成员留在窗里，窗换锚
    func testCloseAnchorKeepsWindow() {
        layout.merge("b", into: "a")
        layout.close("a")
        XCTAssertEqual(layout.windowIds, ["b"])
        XCTAssertEqual(layout.frames["b"], F(x: 100, y: 100, w: 400, h: 300))
        XCTAssertTrue(layout.floatGroupOf.isEmpty)
    }

    func testCloseWindowClosesAllMembers() {
        layout.merge("b", into: "a")
        layout.closeWindow("a")
        XCTAssertEqual(layout.openTools, ["c"])
        XCTAssertTrue(layout.windowIds.isEmpty)
    }

    /// 停回整窗：成员一起成右列末尾的新组
    func testAttachWindowBecomesRightGroup() {
        layout.merge("b", into: "a")
        layout.attachWindow("a")
        let right = layout.columnGroups[.right]!
        XCTAssertEqual(right.count, 2)
        XCTAssertEqual(layout.tabs(in: right[1]), ["a", "b"])
        XCTAssertEqual(layout.currentTab, "b", "窗里选中的那个仍是焦点")
        XCTAssertTrue(layout.detached.isEmpty)
        XCTAssertTrue(layout.floatGroupOf.isEmpty)
    }

    /// 单 tab 窗停回 = 今天的停回（回原组）
    func testAttachSingleWindowUnchanged() {
        layout.attachWindow("a")
        XCTAssertEqual(layout.tabs, ["a", "b", "c"])
        XCTAssertEqual(layout.columnGroups[.right], [IPadPanelLayout.mainGroup])
    }

    /// 成员缩起 → 恢复回原窗并选中
    func testMinimizeMemberRestoresIntoWindow() {
        layout.merge("b", into: "a")
        XCTAssertTrue(layout.minimize("b", in: roomy, widgetCells: 0))
        XCTAssertEqual(layout.floatMembers(of: "a"), ["a"])
        layout.restore("b")
        XCTAssertEqual(layout.floatMembers(of: "a"), ["a", "b"])
        XCTAssertEqual(layout.floatSelection(in: "a"), "b")
        XCTAssertEqual(layout.windowIds, ["a"])
    }

    /// 锚缩起 → 窗交给成员；恢复时回那扇窗
    func testMinimizeAnchorHandsWindowOver() {
        layout.merge("b", into: "a")
        XCTAssertTrue(layout.minimize("a", in: roomy, widgetCells: 0))
        XCTAssertEqual(layout.windowIds, ["b"])
        XCTAssertEqual(layout.frames["b"], F(x: 100, y: 100, w: 400, h: 300))
        layout.restore("a")
        XCTAssertEqual(layout.floatMembers(of: "b"), ["a", "b"])
        XCTAssertEqual(layout.windowIds, ["b"])
    }

    /// 原窗没了（锚被关）→ 恢复成自己一扇窗
    func testRestoreWhenWindowGone() {
        layout.merge("b", into: "a")
        XCTAssertTrue(layout.minimize("b", in: roomy, widgetCells: 0))
        layout.close("a")
        layout.restore("b")
        XCTAssertNil(layout.floatGroupOf["b"])
        XCTAssertEqual(layout.windowIds, ["b"])
        XCTAssertEqual(layout.frames["b"], F(x: 100, y: 100, w: 400, h: 300), "框用原窗的")
    }

    /// 停回单个成员：回它原来的停靠组
    func testAttachMemberLeavesWindow() {
        layout.merge("b", into: "a")
        layout.attach("b")
        XCTAssertEqual(layout.floatMembers(of: "a"), ["a"])
        XCTAssertEqual(layout.tabs, ["b", "c"])
    }

    /// 浮窗模式（④ 不动）：每个工具还是自己一扇窗，窗口 id 是整个 zOrder
    func testFloatingModeIgnoresMerges() {
        layout.merge("b", into: "a")
        layout.mode = .floating
        XCTAssertEqual(Set(layout.windowIds), ["a", "b", "c"])
        layout.mode = .docked
        XCTAssertEqual(layout.windowIds, ["a"])
    }

    /// dock 点成员：选中它并把那扇窗提前
    func testDockTapMemberSelectsInWindow() {
        layout.merge("b", into: "a")
        layout.detach("c", in: land)
        XCTAssertEqual(layout.windowIds.last, "c")
        layout.dockTap("a")
        XCTAssertEqual(layout.floatSelection(in: "a"), "a")
        XCTAssertEqual(layout.windowIds.last, "a")
    }

    func testRoundTripAndNormalize() {
        layout.merge("b", into: "a")
        let again = IPadPanelLayout(defaults: defaults)
        XCTAssertEqual(again.floatGroupOf, ["b": "a"])
        XCTAssertEqual(again.floatSelection(in: "a"), "b")
        // 坏档：成员没浮着 / 锚链两层 / 锚缩着
        let json = """
        {"mode":"docked","leftShown":false,"dockShown":true,"leftWidth":320,"rightWidth":300,
         "openTools":["a","b","c","d"],"detached":["a","b","d"],"minimized":["d"],
         "floatGroupOf":{"c":"a","b":"x","a":"d"},"floatSelected":{"a":"c"}}
        """
        defaults.set(Data(json.utf8), forKey: "ipad.panel.layout.v2")
        let l = IPadPanelLayout(defaults: defaults)
        XCTAssertTrue(l.floatGroupOf.isEmpty, "c 没浮着、x 不存在、d 缩着")
        XCTAssertTrue(l.floatSelected.isEmpty)
    }
}
