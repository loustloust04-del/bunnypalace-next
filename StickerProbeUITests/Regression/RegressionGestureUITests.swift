import XCTest

/// W1 page2 小组件调尺寸不误翻页 / S1 贴纸编辑禁横滑（plan-perf-watch §1.1）
@MainActor
final class RegressionGestureUITests: RegressionTestCase {
    func testW1WidgetResizeDoesNotFlip() {
        launch(["-page2HomePresentation_v1", "free", "-settings.proMode", "NO", "page2-ui-test"],
               env: ["PAGE2_UI_LAYOUT_CASE": UUID().uuidString])
        let home = app.otherElements["page2.free-home"]
        waitFor(home, "page2 桌面")
        expectPage(2, "page2-ui-test 起在 page2")
        let screen = app.frame
        let calendar = app.buttons.matching(identifier: "page2.app.calendar").allElementsBoundByIndex
            .first { $0.frame.width >= 40 && screen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        guard let calendar else { snap("W1-no-app"); return XCTFail("[setup] W1：桌面上找不到日历图标") }
        calendar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 3.4)
        let handle = app.otherElements["page2.resize.todo"].firstMatch
        let widget = app.otherElements["page2.widget.todo"].firstMatch
        waitFor(handle, "调尺寸手柄", timeout: 5)
        waitFor(widget, "待办小组件", timeout: 5)
        let before = widget.frame
        expectPage(2, "进编辑后")
        guard let s0 = pagerState(), let m0 = s0.moved, let d0 = s0.drags else {
            return XCTFail("[setup] W1：pager a11y 没有 moved / drags 字段（F1b 未落地）")
        }

        // 判据：拖手柄前后翻页 pan 的累计拖动次数不变、落到当前页以来的最大位移（pt）不变（astra R2 M04）
        let source = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        source.press(forDuration: 0.05, thenDragTo: source.withOffset(CGVector(dx: 201, dy: 0)), withVelocity: 160, thenHoldForDuration: 0.3)
        XCTAssertTrue(until(4) { widget.frame.width > before.width + 100 }, "[product] W1：横拖手柄没把小组件拉宽（手势被抢？）")
        expectPage(2, "横拖手柄后")
        let s1 = pagerState()
        source.press(forDuration: 0.05, thenDragTo: source.withOffset(CGVector(dx: 0, dy: 217)), withVelocity: 160, thenHoldForDuration: 0.3)
        XCTAssertTrue(until(4) { widget.frame.height > before.height + 100 }, "[product] W1：竖拖手柄没把小组件拉高")
        expectPage(2, "竖拖手柄后")
        let s2 = pagerState()
        record("W1-resize", ["before": before, "after": widget.frame, "moved0": m0, "drags0": d0,
                             "movedH": s1?.moved as Any, "dragsH": s1?.drags as Any, "movedV": s2?.moved as Any, "dragsV": s2?.drags as Any])
        XCTAssertEqual(s1?.drags, d0, "[product] W1：横拖手柄触发了翻页拖动")
        XCTAssertEqual(s1?.moved ?? -1, m0, accuracy: 0.5, "[product] W1：横拖手柄期间翻页容器动过")
        XCTAssertEqual(s2?.drags, d0, "[product] W1：竖拖手柄触发了翻页拖动")
        XCTAssertEqual(s2?.moved ?? -1, m0, accuracy: 0.5, "[product] W1：竖拖手柄期间翻页容器动过")

        app.buttons["完成"].firstMatch.tap()
        swipeToPrev()
        expectPage(1, "退出编辑后横滑应能翻页（对照组）")
    }

    func testS1StickerEditBlocksHorizontalSwipe() {
        launch(["--sticker-probe-seed"])
        let done = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "完成")).firstMatch
        waitFor(done, "贴纸编辑「完成」按钮", timeout: 20)
        XCTAssertTrue(anchor("PROBE") != nil, "[setup] S1：贴纸不在")
        expectPage(1, "贴纸对话在聊天页")
        swipe(fromX: 0.82, toX: 0.18, y: 0.62)
        expectPage(1, "编辑中左滑")
        swipe(fromX: 0.18, toX: 0.82, y: 0.62)
        expectPage(1, "编辑中右滑")
        XCTAssertTrue(done.exists, "[setup] S1：横滑把编辑模式退出了")
        done.tap()
        XCTAssertTrue(until(5) { !done.exists }, "[setup] S1：点完成没退出编辑")
        swipe(fromX: 0.82, toX: 0.18, y: 0.62)
        expectPage(2, "退出编辑后左滑（对照组）")
        swipe(fromX: 0.18, toX: 0.82, y: 0.62)
        expectPage(1, "回聊天页")
        swipe(fromX: 0.18, toX: 0.82, y: 0.62)
        expectPage(0, "退出编辑后右滑（对照组）")
    }
}
