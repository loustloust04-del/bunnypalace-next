import XCTest
@testable import 记忆花园

/// 正文让位：有格子看格子道（面板开关不动它）；没格子退回「面板占多宽让多宽」；对话面板宽度钳制。
@MainActor
final class PanelInsetTests: XCTestCase {
    static let suiteName = "xctest-panel-inset"
    var defaults: UserDefaults!
    var layout: IPadPanelLayout!
    let land = CGSize(width: 1194, height: 834)
    /// 聊天窄过 480 → 没格子（Split View 一类）
    let narrow = CGSize(width: 700, height: 500)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        layout = IPadPanelLayout(defaults: defaults)
        layout.gridSpecOverride = WidgetGridSpec(small: 136, medium: 300)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    /// 停靠排版 a、dock 右：左道 28+136+28，右道 28+(2×136+28)+28+52（工具侧预留两列，dock 贴边）
    func testDockedInsetsFollowGridLanes() {
        XCTAssertNotNil(layout.grid(in: land))
        XCTAssertEqual(layout.leftInset(in: land), 192)
        XCTAssertEqual(layout.rightInset(in: land), 408)
        // 面板开关不改让位量（她：布局跟设置走不跟窗口走）
        layout.leftShown = true
        layout.open("a")
        XCTAssertEqual(layout.leftInset(in: land), 192)
        XCTAssertEqual(layout.rightInset(in: land), 408)
    }

    /// 09-16 解耦后 dock 换边**不再是镜像**：工具恒右、对话恒左，dock 只是从右挪到左。
    /// 左道 = dock 顶替外边距 + 对话一列；右道 = 工具列（后面没有 dock 了）。
    /// **聊天宽度不变**——这是「budget 不用动」的地基（plan-lane-decouple §2.4）
    func testDockLeftKeepsToolsOnRight() {
        let before = land.width - layout.leftInset(in: land) - layout.rightInset(in: land)
        layout.dockSide = .left
        XCTAssertEqual(layout.leftInset(in: land), 244)
        XCTAssertEqual(layout.rightInset(in: land), 356)
        XCTAssertEqual(land.width - 244 - 356, before, "聊天宽度与 dock 在哪无关")
    }

    /// 排版 b：对话侧不留道，工具侧两列
    func testArrangementBLanes() {
        layout.arrangement = .b
        XCTAssertEqual(layout.leftInset(in: land), 0)
        XCTAssertEqual(layout.rightInset(in: land), 408)
    }

    /// 没格子 → 面板占多宽让多宽：对话侧 = 钳过的面板宽（开着才算），工具侧 = dock + tab 组（有 tab 才算）
    func testNoGridFallsBackToPanelWidths() {
        XCTAssertNil(layout.grid(in: narrow))
        XCTAssertEqual(layout.leftInset(in: narrow), 0)
        XCTAssertEqual(layout.rightInset(in: narrow), 52, "dock 开着但没 tab")
        layout.leftShown = true
        XCTAssertEqual(layout.leftInset(in: narrow), layout.dockedConvWidth(in: narrow))
        XCTAssertEqual(layout.leftInset(in: narrow), min(320, max(240, 700 - 52 - IPadPanelLayout.minBodyWidth)))
        layout.open("a")
        XCTAssertEqual(layout.rightInset(in: narrow), 52 + 328)
        // 工具道一开，700 宽放不下 320 的面板：让位量跟着面板一起钳到下限，不再溢出
        XCTAssertEqual(layout.leftInset(in: narrow), 240)
        layout.dockShown = false
        XCTAssertEqual(layout.rightInset(in: narrow), 0)
    }

    /// 停靠面板渲染宽 = 存档按窗口钳过；宽窗不动存的值，窄窗先让到下限，存档本身不变
    func testDockedConvWidthClampsRenderOnly() {
        layout.leftShown = true
        layout.open("a")
        XCTAssertEqual(layout.dockedConvWidth(in: land), 320)
        XCTAssertEqual(layout.dockedConvWidth(in: narrow), 240)
        XCTAssertEqual(layout.leftWidth, 320, "只钳渲染值，不写档")
    }

    /// 浮窗模式没格子：窗盖在正文上，正文不让位
    func testFloatingModeWithoutGridDoesNotInset() {
        layout.mode = .floating
        layout.leftShown = true
        layout.open("a")
        XCTAssertEqual(layout.leftInset(in: narrow), 0)
        XCTAssertEqual(layout.rightInset(in: narrow), 0)
    }

    /// 停靠 tab 组宽 = 工具侧两列 + 两道缝 = 2×136 + 2×28（有格子按格子列数；没格子也是预留两列）
    func testDockedToolPanelWidth() {
        XCTAssertEqual(layout.dockedToolPanelWidth(in: land), 328)
        XCTAssertEqual(layout.dockedToolPanelWidth(in: narrow), 328)
    }

    /// 对话面板宽钳制：停靠模式上限 = min(460, 宽 − 工具侧让位 − 正文下限)；下限 240；浮窗模式只有 240…460。
    /// 正文下限按平台（mac 320 / iPad 400），测试跑在 mac
    func testClampedConvWidth() {
        XCTAssertEqual(layout.clampedConvWidth(500, availableSize: land),
                       min(460, 1194 - 408 - IPadPanelLayout.minBodyWidth))
        XCTAssertEqual(layout.clampedConvWidth(100, availableSize: land), 240)
        XCTAssertEqual(layout.clampedConvWidth(300, availableSize: land), 300)
        layout.mode = .floating
        XCTAssertEqual(layout.clampedConvWidth(500, availableSize: land), 460)
    }

    /// 停靠模式窄窗：上限低于下限时下限赢（这就是 mac 最小窗要 ≥ 240+工具道+正文 的原因，plan §2）
    func testClampedConvWidthFloorWinsWhenTooNarrow() {
        layout.open("a")
        XCTAssertEqual(layout.clampedConvWidth(300, availableSize: narrow), 240)
    }

    /// mac 最小窗 980 双面板都开：对话侧降到 0 列（zone 身份保留）、工具侧 2 列，正文 ≥ 平台下限，不溢出
    func testMacMinWindowFitsWithBothPanels() {
        let minWindow = CGSize(width: 980, height: 600)
        layout.leftShown = true
        layout.open("a")
        let g = layout.grid(in: minWindow)
        XCTAssertNotNil(g, "mac 路径按窗宽算列：对话侧让到 0 列后聊天 ≥ 480，格子还在")
        XCTAssertEqual(g?.zone(.left)?.cols, 0, "对话侧 0 列但 zone 保留（存档不搬）")
        XCTAssertEqual(g?.zone(.right)?.cols, 2)
        let body = 980 - layout.leftInset(in: minWindow) - layout.rightInset(in: minWindow)
        XCTAssertGreaterThanOrEqual(body, IPadPanelLayout.minBodyWidth)
    }
}
