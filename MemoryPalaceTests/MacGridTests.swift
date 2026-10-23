import XCTest
@testable import 记忆花园

/// mac 桌面格子（plan-mac-shape A3 / astra F7）：mac 令牌 164/16、按窗宽算列、0 列保身份、缩窗滞回、tab 组宽随列数。
@MainActor
final class MacGridTests: XCTestCase {
    static let suiteName = "xctest-mac-grid"
    var defaults: UserDefaults!
    let mac = WidgetGridSpec.mac
    typealias Cols = MacGridBudget.Columns

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func target(_ w: CGFloat, _ a: DesktopArrangement) -> Cols {
        MacGridBudget.target(width: w, spec: mac, arrangement: a, dockInset: 0, reserveToolsSide: true)
    }
    private func chat(_ w: CGFloat, _ a: DesktopArrangement, _ c: Cols) -> CGFloat {
        MacGridBudget.chatWidth(width: w, cols: c, spec: mac, arrangement: a, dockInset: 0)
    }

    /// 令牌派生：缝 = 边距 = 16；停靠工具道 = 16 + (2×164+16) + 16 + 52 = 428；对话侧一列 = 16 + 164 + 16 = 196
    func testMacTokensAndLanes() {
        XCTAssertEqual(mac.gutter, 16)
        XCTAssertEqual(mac.margin, 16)
        XCTAssertEqual(MacGridBudget.toolsLane(cols: 2, spec: mac, dockInset: 0), 428)
        XCTAssertEqual(MacGridBudget.convLane(cols: 1, spec: mac), 196)
        XCTAssertEqual(MacGridBudget.convLane(cols: 0, spec: mac), 16)
    }

    /// plan A3 四档表（排版 a：对话侧 / 工具侧 · 聊天）
    func testBudgetTableArrangementA() {
        XCTAssertEqual(target(980, .a), Cols(conv: 0, tools: 2))
        XCTAssertEqual(chat(980, .a, target(980, .a)), 536)
        XCTAssertEqual(target(1200, .a), Cols(conv: 1, tools: 2))
        XCTAssertEqual(chat(1200, .a, target(1200, .a)), 576)
        XCTAssertEqual(target(1440, .a), Cols(conv: 1, tools: 2))
        XCTAssertEqual(chat(1440, .a, target(1440, .a)), 816)
        XCTAssertEqual(target(1710, .a), Cols(conv: 2, tools: 3))
        XCTAssertEqual(chat(1710, .a, target(1710, .a)), 726)
    }

    /// 排版 b 只加工具侧，封顶 4 列
    func testBudgetTableArrangementB() {
        XCTAssertEqual(target(980, .b), Cols(conv: 0, tools: 2))
        XCTAssertEqual(chat(980, .b, target(980, .b)), 552)
        XCTAssertEqual(target(1200, .b), Cols(conv: 0, tools: 2))
        XCTAssertEqual(target(1440, .b), Cols(conv: 0, tools: 3))
        XCTAssertEqual(chat(1440, .b, target(1440, .b)), 832)
        XCTAssertEqual(target(1710, .b), Cols(conv: 0, tools: 4), "封顶 4，不是 5")
        XCTAssertEqual(chat(1710, .b, target(1710, .b)), 922)
        XCTAssertEqual(target(4000, .b), Cols(conv: 0, tools: 4), "再宽也不加，循环要停")
        XCTAssertEqual(target(4000, .a), Cols(conv: 4, tools: 4))
    }

    /// 缩窗滞回：只在减列方向加 24pt 带；加列不加带
    func testShrinkHysteresis() {
        func cols(_ w: CGFloat, previous: Cols?) -> Cols {
            MacGridBudget.columns(width: w, spec: mac, arrangement: .a, dockInset: 0, reserveToolsSide: true, previous: previous)
        }
        // 对话侧 1 列的临界宽：196 + 428 + 480 = 1104
        XCTAssertEqual(cols(1104, previous: nil), Cols(conv: 1, tools: 2))
        XCTAssertEqual(cols(1100, previous: nil), Cols(conv: 0, tools: 2), "首次直接取目标")
        XCTAssertEqual(cols(1100, previous: Cols(conv: 1, tools: 2)), Cols(conv: 1, tools: 2), "带内保住上一次")
        XCTAssertEqual(cols(1070, previous: Cols(conv: 1, tools: 2)), Cols(conv: 0, tools: 2), "再宽 24 也保不住 → 减")
        XCTAssertEqual(cols(1104, previous: Cols(conv: 0, tools: 2)), Cols(conv: 1, tools: 2), "加列无带")
    }

    /// 0 列的对话侧 zone 保留身份：存在那侧的组件「放不下先不显示」，不会被当成换边搬到工具侧
    func testZeroColumnZoneKeepsIdentity() {
        let g = GridFrame.compute(width: 980, height: 600, spec: mac, arrangement: .a, dockSide: .right,
                                  dockInset: 0, reserveToolsSide: true, convCols: 0, toolsCols: 2)
        XCTAssertTrue(g.fits)
        XCTAssertEqual(g.zone(.left)?.cols, 0)
        XCTAssertEqual(g.leftLane, 16)
        XCTAssertEqual(g.rightLane, 428)
        let store = DesktopGridStore(defaults: defaults)
        store.merge(["w.pet": .init(side: .left, col: 0, row: 0)], in: .a)
        let items: [DesktopItem] = [.widget(WidgetInstance(kind: .pet, size: .small)), .widget(WidgetInstance(kind: .todo, size: .small))]
        let out = DesktopGridPlacer.place(items, grid: g, arrangement: .a, store: store)
        XCTAssertNil(out.first { $0.id == "w.pet" }, "存在左侧的不显示")
        XCTAssertEqual(store.placement(of: "w.pet", in: .a), .init(side: .left, col: 0, row: 0), "存档不动")
        XCTAssertEqual(out.first { $0.id == "w.todo" }?.zone.side, .right, "没存过的填工具侧")
    }

    /// 总列数 0 就不算格子
    func testFitsRequiresAtLeastOneColumn() {
        let g = GridFrame.compute(width: 2000, height: 800, spec: mac, arrangement: .a, dockSide: .right,
                                  dockInset: 0, reserveToolsSide: true, convCols: 0, toolsCols: 0)
        XCTAssertFalse(g.fits)
    }

    /// tab 组宽随工具侧列数：k 列 = kS + kG
    func testToolPanelWidthFollowsColumns() {
        let two = GridFrame.compute(width: 1200, height: 800, spec: mac, arrangement: .a, dockSide: .right,
                                    dockInset: 0, reserveToolsSide: true, convCols: 1, toolsCols: 2)
        let three = GridFrame.compute(width: 1710, height: 800, spec: mac, arrangement: .a, dockSide: .right,
                                      dockInset: 0, reserveToolsSide: true, convCols: 2, toolsCols: 3)
        XCTAssertEqual(two.toolPanelWidth, 360)
        XCTAssertEqual(three.toolPanelWidth, 540)
        XCTAssertEqual(three.zone(.right)?.cols, 3)
        XCTAssertEqual(three.zone(.left)?.cols, 2)
        XCTAssertEqual(three.chatWidth, 726)
    }

    /// `IPadPanelLayout` 走 mac 路径：不设 override 时 gridSpec 是 mac 令牌；commitMacColumns 提交的列数被格子用上。
    ///
    /// **09-17 v2 重写**（plan-mac-fullscreen-shell-v2）：停靠壳的列数改按**空地**算（`MacShellFrame`），
    /// 不再是「聊天道减卡占用」。默认状态 leftShown=false、dockShown=true、tabs 空 ⇒ 两侧都是空地，
    /// 1710 档：free = 1710 − 52 − 780 = 878 → 左 1(196) / 右 1(392) / 左 2(572) / 右 2(752) / 左 3(932 ✗) → (2,2)。
    /// 期望是按公式手算再跑出来核的；上面直接调 `MacGridBudget.target` 的浮窗口径档位一个没动。
    func testLayoutUsesMacTokensAndCommittedColumns() {
        let layout = IPadPanelLayout(defaults: defaults)
        // 参数注自己的，不读 shared——否则断言跟她真机上调过的卡边距耦合（R4b）
        layout.shellMetrics = MacShellMetrics(defaults: defaults)
        // Historical 60pt card-edge fixture: keep testing persisted/custom spacing and hysteresis.
        layout.shellMetrics[.cardGapX] = 10
        layout.shellMetrics[.cardPadX] = 20
        XCTAssertEqual(layout.gridSpec, .mac)
        let wide = CGSize(width: 1710, height: 900)
        layout.commitMacColumns(width: wide.width)
        XCTAssertEqual(layout.macColumns, Cols(conv: 0, tools: 0))
        XCTAssertNil(layout.desktopGrid(in: wide))
        XCTAssertEqual(layout.macShellFrame(in: wide).card, 1710 - 52)
        for width: CGFloat in [1580, 1550, 1200] {
            layout.commitMacColumns(width: width)
            XCTAssertEqual(layout.macColumns, Cols(conv: 0, tools: 0))
        }
        // 浮窗模式走老口径（一行不动）：1200 宽 (1,1)
        layout.mode = .floating
        layout.macColumns = nil
        layout.commitMacColumns(width: 1200)
        XCTAssertEqual(layout.macColumns, Cols(conv: 1, tools: 1))
    }

    /// 停靠壳里 dock 条是壳的一部分：`dockShown` 关掉只收工具面板，dock 那 52 还在、卡宽不变
    /// （09-17 她：「打开左栏或右栏 dock 居然会收起来」——那颗钮原来把 dock 一起收）。浮窗模式不受影响
    func testDockedShellKeepsDockStripWhenDockShownIsOff() {
        let layout = IPadPanelLayout(defaults: defaults)
        layout.shellMetrics = MacShellMetrics(defaults: defaults)
        let size = CGSize(width: 1200, height: 900)
        layout.open("a")
        layout.commitMacColumns(width: size.width)
        let on = layout.macShellFrame(in: size)
        XCTAssertEqual(on.dock, 52)
        XCTAssertNotNil(on.tool)
        layout.dockShown = false
        layout.commitMacColumns(width: size.width)
        let off = layout.macShellFrame(in: size)
        XCTAssertEqual(off.dock, 52, "dock 条不跟工具面板走")
        XCTAssertNil(off.tool, "工具面板收起")
        XCTAssertFalse(layout.macToolShown)
        XCTAssertEqual(off.dock + (off.conv ?? off.leftLane) + off.card + (off.tool ?? off.rightLane), size.width)
        XCTAssertEqual(layout.macClampedConvWidth(320, in: size), 320)
    }
}
