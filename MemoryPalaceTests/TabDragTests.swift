import XCTest
@testable import 记忆花园

/// plan-mac-shape A2a：tab 拖放的代数（半槽 → 槽位 / 换位 / 浮窗停回插槽 / 落点浮出）与 tab 组折叠的存档语义。
@MainActor
final class TabDragTests: XCTestCase {
    static let suiteName = "xctest-tab-drag"
    var defaults: UserDefaults!
    var layout: IPadPanelLayout!
    let land = CGSize(width: 1194, height: 834)
    /// 缩成小组件要空地上有格子（mac 停靠壳，plan-mac-fullscreen-shell-v2）：1800 宽左空地 3 列，同 `PanelLayoutTests.roomy`
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

    // MARK: 半槽

    /// 左半 = 插到这个 tab 前面（槽 i），右半 = 后面（槽 i+1）
    func testHalfSlot() {
        XCTAssertEqual(TabInsertion.slot(tabIndex: 1, x: 10, width: 60), 1)
        XCTAssertEqual(TabInsertion.slot(tabIndex: 1, x: 40, width: 60), 2)
        XCTAssertEqual(TabInsertion.slot(tabIndex: 0, x: 29, width: 60), 0)
        XCTAssertEqual(TabInsertion.slot(tabIndex: 0, x: 30, width: 60), 1)
    }

    // MARK: 换位

    func testMoveTabToEndAndFront() {
        layout.open("a"); layout.open("b"); layout.open("c")
        layout.moveTab("a", to: 3)
        XCTAssertEqual(layout.tabs, ["b", "c", "a"])
        layout.moveTab("c", to: 0)
        XCTAssertEqual(layout.tabs, ["c", "b", "a"])
        layout.moveTab("b", to: 3)
        XCTAssertEqual(layout.tabs, ["c", "a", "b"])
    }

    /// 落回自己的左右两个半槽 = 原位不动（也不写档触发 didSet 之外的事）
    func testMoveTabOntoItselfIsNoop() {
        layout.open("a"); layout.open("b"); layout.open("c")
        layout.moveTab("b", to: 1)
        XCTAssertEqual(layout.tabs, ["a", "b", "c"])
        layout.moveTab("b", to: 2)
        XCTAssertEqual(layout.tabs, ["a", "b", "c"])
    }

    /// 浮出 / 缩起的成员在 `openTools` 里原位不动，只有 tab 之间换序（顶掉先后不乱）
    func testMoveTabKeepsDetachedInPlace() {
        layout.open("a"); layout.open("b"); layout.open("c")
        layout.detach("b", in: land)
        XCTAssertEqual(layout.tabs, ["a", "c"])
        layout.moveTab("c", to: 0)
        XCTAssertEqual(layout.tabs, ["c", "a"])
        XCTAssertEqual(layout.openTools, ["c", "b", "a"])
    }

    func testMoveTabIgnoresNonTab() {
        layout.open("a"); layout.open("b")
        layout.detach("b", in: land)
        layout.moveTab("b", to: 0)
        XCTAssertEqual(layout.tabs, ["a"])
        XCTAssertEqual(layout.detached, ["b"])
    }

    // MARK: 浮窗标题拖进 tab 栏

    /// 浮窗停回并插到悬停时看到的那一槽（那时它不在栏里，槽不扣自己）
    func testAttachAtSlotFromDetached() {
        layout.open("a"); layout.open("b"); layout.open("c")
        layout.detach("c", in: land)
        layout.attach("c", at: 0)
        XCTAssertEqual(layout.tabs, ["c", "a", "b"])
        XCTAssertTrue(layout.detached.isEmpty)
        XCTAssertEqual(layout.currentTab, "c")
        layout.detach("a", in: land)
        layout.attach("a", at: 1)
        XCTAssertEqual(layout.tabs, ["c", "a", "b"])
    }

    /// 来源本来就是 tab → 等价 moveTab
    func testAttachAtSlotForTabMoves() {
        layout.open("a"); layout.open("b"); layout.open("c")
        layout.attach("a", at: 3)
        XCTAssertEqual(layout.tabs, ["b", "c", "a"])
    }

    // MARK: 落点浮出

    /// 丢到工作区某点：标题栏中点落在指针下（x 居中、y 上 20），并钳在可用区里
    func testDetachAtPoint() {
        layout.open("a"); layout.open("b")
        layout.detach("a", at: CGPoint(x: 500, y: 300), in: land)
        XCTAssertEqual(layout.detached, ["a"])
        let f = layout.frames["a"]!
        XCTAssertEqual(f.x, 500 - f.w / 2)
        XCTAssertEqual(f.y, 280)
        XCTAssertEqual(layout.tabs, ["b"])
        XCTAssertEqual(layout.zOrder.last, "a")
    }

    /// 已浮出的再丢到别处 = 只搬位置，尺寸不变
    func testDetachAtPointMovesExistingWindow() {
        layout.open("a"); layout.open("b")
        layout.detach("a", in: land)
        layout.frames["a"] = .init(x: 10, y: 10, w: 400, h: 300)
        layout.detach("a", at: CGPoint(x: 600, y: 400), in: land)
        let f = layout.frames["a"]!
        XCTAssertEqual(f.w, 400); XCTAssertEqual(f.h, 300)
        XCTAssertEqual(f.x, 400); XCTAssertEqual(f.y, 380)
    }

    func testDetachAtPointIgnoresClosed() {
        layout.detach("zzz", at: CGPoint(x: 100, y: 100), in: land)
        XCTAssertTrue(layout.detached.isEmpty)
        XCTAssertNil(layout.frames["zzz"])
    }

    // MARK: 折叠

    /// 缺 key 的旧档 → 展开（astra F10）
    func testCollapsedDefaultsFalseWhenKeyMissing() throws {
        layout.open("a")
        layout.tabGroupCollapsed = true
        let data = try XCTUnwrap(defaults.data(forKey: "ipad.panel.layout.v2"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["tabGroupCollapsed"] as? Bool, true)
        json["tabGroupCollapsed"] = nil
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "ipad.panel.layout.v2")
        let reloaded = IPadPanelLayout(defaults: defaults)
        XCTAssertFalse(reloaded.tabGroupCollapsed)
        XCTAssertEqual(reloaded.tabs, ["a"])
    }

    func testCollapsedRoundTrip() {
        layout.open("a")
        layout.tabGroupCollapsed = true
        XCTAssertTrue(IPadPanelLayout(defaults: defaults).tabGroupCollapsed)
        layout.tabGroupCollapsed = false
        XCTAssertFalse(IPadPanelLayout(defaults: defaults).tabGroupCollapsed)
    }

    /// 生命周期：开新工具 / 选中 / 停回 都展开；关掉最后一个 tab 清掉
    func testCollapsedLifecycle() {
        layout.open("a"); layout.open("b")
        layout.tabGroupCollapsed = true
        layout.open("c")
        XCTAssertFalse(layout.tabGroupCollapsed)

        layout.tabGroupCollapsed = true
        layout.dockTap("a")
        XCTAssertFalse(layout.tabGroupCollapsed)
        XCTAssertEqual(layout.currentTab, "a")

        // 折着时点当前选中的 dock 图标 = 展开，不是关
        layout.tabGroupCollapsed = true
        layout.dockTap("a")
        XCTAssertFalse(layout.tabGroupCollapsed)
        XCTAssertTrue(layout.isOpen("a"))

        layout.detach("a", in: land)
        layout.tabGroupCollapsed = true
        layout.attach("a")
        XCTAssertFalse(layout.tabGroupCollapsed)

        layout.tabGroupCollapsed = true
        layout.close("a"); layout.close("b")
        XCTAssertTrue(layout.tabGroupCollapsed, "还有 tab 就留着")
        layout.close("c")
        XCTAssertTrue(layout.tabs.isEmpty)
        XCTAssertFalse(layout.tabGroupCollapsed)
    }

    /// 最后一个 tab 浮出 / 缩起也清掉折叠（组没了）
    func testCollapsedClearsWhenLastTabLeaves() {
        layout.open("a")
        layout.tabGroupCollapsed = true
        layout.detach("a", in: land)
        XCTAssertFalse(layout.tabGroupCollapsed)

        layout.attach("a")
        layout.tabGroupCollapsed = true
        XCTAssertTrue(layout.minimize("a", in: roomy, widgetCells: 0))
        XCTAssertFalse(layout.tabGroupCollapsed)
    }
}
