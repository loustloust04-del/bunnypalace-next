import XCTest
@testable import 记忆花园

/// **回归网**：mac 全屏（停靠）模式外观参数（plan-mac-fullscreen-shell T0；v2 换树后只剩参数这一半，
/// 几何那一半在 `MacShellFrameTests`，浮窗数在它的 `testFloatingLanesUnchanged`）。
///
/// ⚠️ 测试不许读 `MacShellMetrics.shared`（= `UserDefaults.standard`，粟粟真机上调过的值），
/// 要断数的走纯函数 + 显式传 `defaultCardEdges`。
@MainActor
final class MacShellRegressionTests: XCTestCase {

    /// 默认密度来自薄荷工作台；额外输入内缩仍从零开始。
    /// （`composerGap` / `composerInset` 是「在现状之上再加」，默认必须是 0；
    /// `dockItem` / `dockGap` 必须等于桌面默认的 36 / 2。）
    func testMintWorkspaceDefaults() {
        XCTAssertEqual(MacShellMetrics.Knob.composerInset.def, 0)
        XCTAssertEqual(MacShellMetrics.Knob.composerGap.def, 0)
        XCTAssertEqual(MacShellMetrics.Knob.dockItem.def, Double(ShellStyle.dockHit))
        XCTAssertEqual(MacShellMetrics.Knob.dockGap.def, 2)
        XCTAssertEqual(MacShellMetrics.defaultCardEdges, 8, "2×(4+0)：正文内距由 ChatMetrics 单独负责")
    }

    func testDockingFallbackUsesVisiblePaneBounds() {
        let name = "xctest-mac-mint-docking"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let layout = IPadPanelLayout(defaults: defaults)
        layout.shellMetrics = MacShellMetrics(defaults: defaults)
        layout.mode = .docked
        layout.leftShown = true
        layout.leftWidth = 320
        layout.toolWidth = 360
        layout.dockSide = .right
        layout.open("memory")
        // At 980pt, the right tool slot is 280pt; its visible pane excludes 4pt each side.
        XCTAssertEqual(layout.macDockingFrame(in: CGSize(width: 980, height: 600)),
                       CGRect(x: 652, y: 0, width: 272, height: 40))
        layout.dockSide = .left
        XCTAssertEqual(layout.macDockingFrame(in: CGSize(width: 980, height: 600)),
                       CGRect(x: 704, y: 0, width: 272, height: 40))
    }

    /// 每根旋钮的默认值都要落在它自己的范围里（参数台拖不到默认值 = 低级错）
    func testEveryKnobDefaultIsInsideItsRange() {
        for k in MacShellMetrics.Knob.allCases {
            XCTAssertTrue(k.range.contains(k.def), "\(k.rawValue) 的默认值 \(k.def) 不在 \(k.range) 里")
        }
    }

    /// 参数落盘走独立 suite，不碰 `.standard`；`reset()` 要能把键清干净
    func testPersistenceAndReset() {
        let name = "xctest-mac-shell-metrics"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let m = MacShellMetrics(defaults: defaults)
        m[.cardGapX] = 33
        XCTAssertEqual(m.cardGapX, 33)
        XCTAssertEqual(defaults.object(forKey: "mac.shell.cardGapX") as? Double, 33)

        // 重新建一个，值要读回来
        XCTAssertEqual(MacShellMetrics(defaults: defaults).cardGapX, 33)

        m.reset()
        XCTAssertEqual(m.cardGapX, CGFloat(MacShellMetrics.Knob.cardGapX.def))
        XCTAssertNil(defaults.object(forKey: "mac.shell.cardGapX"), "reset 要把键删掉，不是写回默认值")
        defaults.removePersistentDomain(forName: name)
    }

    /// `toolWidth` 进存档：旧档没这个键 → 360；写了再读回来
    func testToolWidthPersists() {
        let name = "xctest-mac-shell-toolwidth"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let layout = IPadPanelLayout(defaults: defaults)
        XCTAssertEqual(layout.toolWidth, 360)
        layout.toolWidth = 300
        XCTAssertEqual(IPadPanelLayout(defaults: defaults).toolWidth, 300)
        defaults.removePersistentDomain(forName: name)
    }
    func testConsoleValuesAreBoundedAndSharedAcrossReadingMetrics() {
        let name = "xctest-mac-console-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let metrics = MacShellMetrics(defaults: defaults)
        metrics[.contentWidth] = 900
        metrics[.contentPadX] = 32
        XCTAssertEqual(MacShellMetrics(defaults: defaults)[.contentWidth], 900)
        XCTAssertEqual(metrics.chatMetrics.listInsetH, 32)
        XCTAssertEqual(metrics.chatMetrics.composerInsetH, 32)
        metrics[.contentWidth] = -1
        XCTAssertEqual(metrics[.contentWidth], 480)
        metrics[.contentWidth] = .infinity
        XCTAssertEqual(metrics[.contentWidth], 480)
        metrics.reset()
        XCTAssertEqual(metrics[.contentWidth], 720)
    }

    func testTitleBarContainsSquareButtonAndInsetsAtSmallRequestedHeight() {
        let name = "xctest-titlebar-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let metrics = MacShellMetrics(defaults: defaults)
        metrics[.titleBarHeight] = 26
        metrics[.iconButtonWidth] = 26
        XCTAssertEqual(metrics.titleBarHeight, 26)
        XCTAssertEqual(metrics.titleButtonSide, 18) // 26 - 2 × 4.
        XCTAssertEqual(metrics.titleControlInset, 4)
        metrics[.iconButtonWidth] = 40
        XCTAssertEqual(metrics.titleBarHeight, 26)
        XCTAssertEqual(metrics.titleButtonSide, 18)
        metrics[.titleBarHeight] = 60
        XCTAssertEqual(metrics.titleBarHeight, 60)
    }

    func testTitlebarFollowsMeasuredTrafficLightCenterByDefault() {
        let name = "xctest-native-title-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let metrics = MacShellMetrics(defaults: defaults, alignedTitlebarHeight: { 32 })
        XCTAssertTrue(metrics.followsTrafficLights)
        XCTAssertEqual(metrics.titleBarHeight / 2, 16)
        XCTAssertEqual(metrics.titleButtonSide, 24)
        XCTAssertEqual(metrics.titleControlInset, 4)
        metrics[.titleBarHeight] = 30
        XCTAssertFalse(metrics.followsTrafficLights)
        XCTAssertEqual(metrics.titleBarHeight, 30)
        metrics.followsTrafficLights = true
        XCTAssertEqual(metrics.titleBarHeight, 32)
    }

}
