import XCTest
@testable import 记忆花园

#if os(macOS)
/// 底列 / 列折叠 / fly-out（plan-panel-ps 阶段 4）
@MainActor
final class PanelBottomFlyoutTests: XCTestCase {
    static let suiteName = "xctest-panel-bottom-flyout"
    var defaults: UserDefaults!
    var layout: IPadPanelLayout!
    let land = CGSize(width: 1600, height: 900)
    let main = IPadPanelLayout.mainGroup

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        layout = IPadPanelLayout(defaults: defaults)
        layout.shellMetrics = MacShellMetrics(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    // MARK: 几何

    /// y 恒等：卡高 + 底列 == 工作区高；全部非负；H 扫描含极矮
    func testBottomIdentitySweep() {
        for h in [0, 100, 139, 140, 300, 420, 536, 568, 900] as [CGFloat] {
            for stored in [0, 140, 220, 500, 10_000, -5, .infinity] as [CGFloat] {
                let f = MacShellFrame.compute(width: 1400, height: h, spec: .mac, arrangement: .a, dockSide: .right,
                                              dockShown: true, leftShown: true, leftWidth: 300, toolShown: true, toolWidth: 360,
                                              cardEdges: 8, bottomShown: true, bottomHeight: stored)
                if h == 0 { XCTAssertNil(f.bottom); continue }
                let b = f.bottom ?? -1
                XCTAssertGreaterThanOrEqual(b, 0)
                XCTAssertGreaterThanOrEqual(f.cardHeight, 0)
                XCTAssertEqual(f.cardHeight + b, h, accuracy: 0.001, "h=\(h) stored=\(stored)")
                XCTAssertLessThanOrEqual(b, h)
            }
        }
    }

    /// 最小窗高 600 − 标题行 32 = 568：底列 [140, 288]，卡 ≥ 280（A I7 的算术）
    func testBottomClampAtMinimumWindow() {
        XCTAssertEqual(MacShellFrame.bottomHeight(stored: 10, height: 568), 140)
        XCTAssertEqual(MacShellFrame.bottomHeight(stored: 1000, height: 568), 288)
        XCTAssertEqual(MacShellFrame.bottomHeight(stored: 220, height: 568), 220)
        XCTAssertEqual(MacShellFrame.bottomHeight(stored: 1000, height: 900), 540, "高窗按 0.6 封顶")
        XCTAssertEqual(MacShellFrame.bottomHeight(stored: 220, height: 100), 100, "比下限还矮：整个给底列，卡为 0，不为负")
    }

    /// 底列不碰横向：四槽恒等式与左右格子照旧
    func testBottomDoesNotTouchSlots() {
        let a = MacShellFrame.compute(width: 1500, height: 800, spec: .mac, arrangement: .a, dockSide: .right,
                                      dockShown: true, leftShown: false, leftWidth: 300, toolShown: false, toolWidth: 360,
                                      cardEdges: 8)
        let b = MacShellFrame.compute(width: 1500, height: 800, spec: .mac, arrangement: .a, dockSide: .right,
                                      dockShown: true, leftShown: false, leftWidth: 300, toolShown: false, toolWidth: 360,
                                      cardEdges: 8, bottomShown: true, bottomHeight: 260)
        XCTAssertEqual(a.card, b.card)
        XCTAssertEqual(a.grid, b.grid)
        XCTAssertEqual(b.bottom, 260)
        XCTAssertNil(a.bottom)
    }

    /// 布局里：底列有 tab 且没折叠才出现在几何里；折叠 ⌘⌥B 收起
    func testLayoutBottomVisibility() throws {
        layout.open("a"); layout.open("b")
        XCTAssertNil(layout.macShellFrame(in: land).bottom)
        layout.moveMacPanel("b", toColumn: .bottom, in: land)
        XCTAssertTrue(layout.bottomColumnVisible)
        XCTAssertEqual(layout.macShellFrame(in: land).bottom, 220)
        layout.toggleColumnCollapsed(.bottom)
        XCTAssertFalse(layout.bottomColumnVisible)
        XCTAssertNil(layout.macShellFrame(in: land).bottom)
        XCTAssertEqual(layout.tabs, ["a", "b"], "折叠不关工具，iPad 投影照样看得到")
    }

    // MARK: 折叠

    func testToggleRightIsDockShown() {
        XCTAssertTrue(layout.dockShown)
        layout.toggleColumnCollapsed(.right)
        XCTAssertFalse(layout.dockShown)
        XCTAssertTrue(layout.isColumnHidden(.right))
    }

    /// ⌘⌥S 打开对话列表时顺手展开折着的左列（conv 能找回来）
    func testShowingConversationListExpandsLeftColumn() {
        layout.toggleColumnCollapsed(.left)
        layout.leftShown = true
        XCTAssertFalse(layout.collapsedColumns.contains(.left))
        XCTAssertTrue(layout.leftColumnVisible)
    }

    /// 读档不触发这条副作用（折叠状态原样读回）
    func testLoadKeepsLeftCollapsed() {
        layout.leftShown = true
        layout.toggleColumnCollapsed(.left)
        let again = IPadPanelLayout(defaults: defaults)
        XCTAssertTrue(again.collapsedColumns.contains(.left))
    }

    // MARK: fly-out（A I3 状态表）

    /// 列看得见：dock 点照旧三段式，不弹
    func testVisibleColumnKeepsThreePhase() {
        layout.open("a"); layout.open("b")
        layout.dockTap("a")
        XCTAssertNil(layout.macFlyout)
        XCTAssertEqual(layout.currentTab, "a")
        layout.dockTap("a")
        XCTAssertFalse(layout.isOpen("a"))
    }

    /// 右列收着：点停靠的 → 弹出它的组并选中；再点同一个 → 收；换一个同组的 → 只切 tab
    func testHiddenRightColumnFlyout() {
        layout.open("a"); layout.open("b")
        layout.dockShown = false
        layout.dockTap("a")
        XCTAssertEqual(layout.macFlyout, "a")
        XCTAssertEqual(layout.macFlyoutGroup, main)
        XCTAssertEqual(layout.currentTab, "a")
        XCTAssertTrue(layout.isOpen("a"), "不再是「关」")
        layout.dockTap("b")
        XCTAssertEqual(layout.macFlyout, "b")
        XCTAssertEqual(layout.currentTab, "b")
        layout.dockTap("b")
        XCTAssertNil(layout.macFlyout)
        XCTAssertTrue(layout.isOpen("b"))
    }

    /// 右列收着时开一个新工具：进主组并弹出来给她看
    func testOpenNewWhileRightHidden() {
        layout.dockShown = false
        layout.dockTap("x")
        XCTAssertTrue(layout.isOpen("x"))
        XCTAssertEqual(layout.macFlyout, "x")
    }

    /// 左列折叠：左列里的工具弹出；浮着的照旧置顶不弹
    func testCollapsedLeftAndFloatingUnchanged() throws {
        layout.open("a"); layout.open("b"); layout.open("c")
        _ = try XCTUnwrap(layout.insertGroup(with: "a", edge: .left, at: 1))
        layout.detach("c", in: land)
        layout.toggleColumnCollapsed(.left)
        layout.dockTap("a")
        XCTAssertEqual(layout.macFlyoutGroup, layout.group(of: "a"))
        layout.dockTap("c")
        XCTAssertEqual(layout.windowIds.last, "c")
        XCTAssertEqual(layout.macFlyout, "a", "点浮窗不动 fly-out")
    }

    /// 列展开后 fly-out 自动失效；切模式 / 取消展示清掉
    func testFlyoutClears() {
        layout.open("a")
        layout.dockShown = false
        layout.dockTap("a")
        XCTAssertNotNil(layout.macFlyoutGroup)
        layout.dockShown = true
        XCTAssertNil(layout.macFlyoutGroup, "列看得见就不画")
        layout.dockShown = false
        XCTAssertNotNil(layout.macFlyoutGroup)
        layout.cancelMacPresentation()
        XCTAssertNil(layout.macFlyout)
        layout.dockTap("a")
        layout.endMacTabDrag()
        XCTAssertNil(layout.macFlyout, "拖放结束收掉")
    }

    /// 浮窗模式（④）：dock 点仍是开 ⇄ 关
    func testFloatingModeDockTapUnchanged() {
        layout.mode = .floating
        layout.dockShown = false
        layout.dockTap("a")
        XCTAssertTrue(layout.isOpen("a"))
        XCTAssertNil(layout.macFlyout)
        layout.dockTap("a")
        XCTAssertFalse(layout.isOpen("a"))
    }
}
#endif
