import XCTest

/// O1 打开对话 / P1 翻页 / V1 竖滚不被抢 / E2 左缘右滑（plan-perf-watch §1.1）
@MainActor
final class RegressionNavigationUITests: RegressionTestCase {
    private func launchSeeded() {
        launch(["--ui-regression-seed"])
        waitFor(field, "输入框")
        expectPage(1, "启动落在聊天页")
        if !until(15, { [self] in anchor("RGTAIL") != nil }) {
            snap("setup-no-tail"); XCTFail("[setup] 回归种子对话没打开")
        }
    }

    private var openRow: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "[RG] 打开对话目标")).firstMatch
    }

    func testO1OpenConversation() {
        launchSeeded()
        swipeToPrev()
        expectPage(0, "翻到列表")
        waitFor(openRow, "列表里的「[RG] 打开对话目标」")
        openRow.tap()
        expectPage(1, "点对话自动翻到聊天页")
        XCTAssertTrue(until(10) { [self] in anchor("RGOPEN") != nil && anchor("RGTAIL") == nil }, "[product] O1：打开的不是目标对话")
        guard let s = settle({ [self] in [field.frame, anchor("RGOPEN")?.frame ?? .zero] }) else {
            snap("O1-unstable"); return XCTFail("[product] O1：打开后几何不收敛")
        }
        let gap = s[0].minY - s[1].maxY
        record("O1-geometry", ["F": s[0], "tail": s[1], "tailGap": gap])
        XCTAssertTrue(RegressionKeyboardUITests.atBottomGapBand.contains(gap), "[product] O1：没落到底（尾条底到输入框顶 \(gap)pt）")
        field.tap()
        waitKeyboardUp()
        field.typeText("rg")
        XCTAssertEqual(field.value as? String, "rg", "[product] O1：输入框打不进字")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
        XCTAssertNotEqual(field.value as? String, "rg")
    }

    func testP1PagingRoundTrip() {
        launchSeeded()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.40))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.64, dy: 0.40)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        expectPage(1, "短拖取消")
        let steps: [(String, () -> Void, Int)] = [
            ("1→0", { self.swipeToPrev() }, 0), ("0→1", { self.swipeToNext() }, 1),
            ("1→2", { self.swipeToNext() }, 2), ("2→1", { self.swipeToPrev() }, 1),
            ("1→0", { self.swipeToPrev() }, 0), ("0→1", { self.swipeToNext() }, 1),
        ]
        for (name, action, page) in steps {
            action()
            expectPage(page, name)
            switch page {
            case 0: XCTAssertTrue(openRow.waitForExistence(timeout: 5) && openRow.isHittable, "[product] P1 \(name)：列表页内容不可点")
            case 1: XCTAssertTrue(field.isHittable, "[product] P1 \(name)：输入框不可点")
            default:
                // page2.free-home 是容器，中心被小组件盖住时 isHittable 恒 false；改看桌面上一个应用图标可点
                let screen = app.frame
                let ok = until(5) { [self] in
                    app.buttons.matching(identifier: "page2.app.calendar").allElementsBoundByIndex
                        .contains { screen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) && $0.isHittable }
                }
                XCTAssertTrue(ok, "[product] P1 \(name)：page2 桌面上的应用图标不可点")
            }
        }
    }

    func testV1VerticalScrollNotStolen() {
        launchSeeded()
        let historyText = "回归填充消息 25"
        guard let before = anchor(historyText)?.frame else { return XCTFail("[setup] V1：找不到历史锚") }
        // 先短拖一次量历史锚位移（锚还在视口内才有方向证据；astra R2 M05），再长拖离底
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)))
        expectPage(1, "竖拖 1")
        guard let after = settle({ [self] in [anchor(historyText)?.frame ?? .zero] }) else {
            return XCTFail("[anchor] V1：短拖后历史锚不在视口")
        }
        let moved = after[0].minY - before.minY
        record("V1-scroll", ["before": before, "after": after[0], "moved": moved])
        XCTAssertGreaterThan(moved, 50, "[product] V1：竖拖没滚动列表（历史锚只动了 \(moved)pt）")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        expectPage(1, "竖拖 2")
        let tail = anchor("RGTAIL")?.frame
        XCTAssertTrue(tail == nil || tail!.minY >= field.frame.minY - 1, "[product] V1：竖拖后尾条还在原位")
        // 回底按钮在 AX 里 isHittable 恒 false（SwiftUI overlay），改为：按钮在屏上 → 点它 → 真的回到底
        let button = app.descendants(matching: .any)["scroll-to-bottom"].firstMatch
        XCTAssertTrue(until(5) { [self] in button.exists && window.contains(CGPoint(x: button.frame.midX, y: button.frame.midY)) }, "[product] V1：离底后回底按钮没出现")
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(until(5) { [self] in
            guard let t = anchor("RGTAIL")?.frame else { return false }
            return RegressionKeyboardUITests.atBottomGapBand.contains(field.frame.minY - t.maxY)
        }, "[product] V1：点回底按钮没回到底")
        for dx in [CGFloat(40), -40] {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 300)))
            expectPage(1, "斜拖 dx=\(dx)")
        }
    }

    func testE2LeftEdgeSwipe() {
        launchSeeded()
        let y = window.height * 0.4
        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 4, dy: y))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 30, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.4)
        expectPage(1, "左缘小拖放回")
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: window.width * 0.75, dy: 0)), withVelocity: .default, thenHoldForDuration: 0)
        expectPage(0, "左缘右滑")
        XCTAssertTrue(openRow.waitForExistence(timeout: 5) && openRow.isHittable, "[product] E2：翻到列表后不可点")
    }
}
