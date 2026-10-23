import XCTest

/// A-deck 叠牌回归（plan-paging-decouple §1.5 / §1.9）。D 系列：下层页不接触摸。I 系列：翻页中断后的完整终态（plan-paging-decouple §1.9 A-4）。手指从起始页慢拖、偏离超过阈值时 AUT 里的测试钩子
/// （MP_UITEST_PAGING_INTERRUPT=原因@阈值@起始页）触发一种中断，走产品里同一个处理函数；
/// 断言落到选定的页（回源页 / 就近页 / 命令目标页）、停稳，且五样终态核对（endStateChecks / endStateBad）没有不一致。
@MainActor
final class RegressionPagingDeckUITests: RegressionTestCase {
    private func launchSeeded(interrupt: String) {
        launch(["--ui-regression-seed"], env: ["MP_UITEST_PAGING_INTERRUPT": interrupt])
        waitFor(field, "输入框")
        expectPage(1, "启动落在聊天页")
        // 种子对话真的显示出来再拖（I2 首轮 drags=0：拖的时候页面还没就绪）；a11y 里的 splash 字段只在翻页时刷新，不能拿来等
        if !until(15, { [self] in anchor("RGTAIL") != nil }) { snap("setup-no-tail"); XCTFail("[setup] 回归种子对话没打开") }
    }

    private func endState() -> (checks: Int, bad: Int)? {
        let s = launchState()
        guard let c = s["endStateChecks"].flatMap(Int.init), let b = s["endStateBad"].flatMap(Int.init) else { return nil }
        return (c, b)
    }

    /// 慢拖到 toX 后按住（手指没抬起时中断已经发生）
    private func slowDragAndHold(fromX: CGFloat, toX: CGFloat) {
        app.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: 0.40))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: 0.40)),
                   withVelocity: .slow, thenHoldForDuration: 1.0)
    }

    private func run(_ name: String, reason: String, fromX: CGFloat, toX: CGFloat, expect page: Int, why: String) {
        guard let before = endState() else { return XCTFail("[setup] \(name)：paging-scroll 没有 endStateChecks / endStateBad 字段") }
        slowDragAndHold(fromX: fromX, toX: toX)
        expectPage(page, why)
        let ok = until(5) { [self] in (endState()?.checks ?? 0) > before.checks }
        let after = endState()
        record("\(name)-endState", ["before": "\(before)", "after": String(describing: after), "AUT": launchState()])
        // 页码第五样的 SwiftUI 侧：iOSPage（PageSync 记的）要跟上分页壳（回写在下一轮，R2-07）
        XCTAssertTrue(until(3) { [self] in launchState()["swiftUIPage"] == "\(page)" },
                      "[product] \(name)：SwiftUI 页码没跟上分页壳（\(launchState()["swiftUIPage"] ?? "?") ≠ \(page)）")
        XCTAssertEqual(launchState()["lastInterrupt"], reason, "[setup] \(name)：中断钩子没触发（走的是普通落定，结论不算数）")
        XCTAssertTrue(ok, "[product] \(name)：中断后没有做终态核对")
        XCTAssertEqual(after?.bad, before.bad, "[product] \(name)：中断后五样终态不一致：\(launchState()["endStateLastBad"] ?? "?")")
    }

    private var openRow: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "[RG] 打开对话目标")).firstMatch
    }

    /// D1 停聊天页点空白处：下层（列表 / page2）不响应——叠牌下三页都在 x=0，只有当前页开交互
    func testD1BlankOnChatDoesNotReachListBelow() {
        launch(["--ui-regression-seed"])
        waitFor(field, "输入框")
        expectPage(1, "启动落在聊天页")
        XCTAssertTrue(until(15) { [self] in anchor("RGTAIL") != nil }, "[setup] D1：回归种子对话没打开")
        swipeToPrev()
        expectPage(0, "翻到列表")
        waitFor(openRow, "列表里的「[RG] 打开对话目标」")
        let rowPoint = CGPoint(x: openRow.frame.midX, y: openRow.frame.midY)
        swipeToNext()
        expectPage(1, "翻回聊天页")
        // 在列表那一行的屏幕位置点聊天页（正文区空白或气泡，都不该落到下面的列表行上）
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rowPoint.x, dy: rowPoint.y)).tap()
        expectPage(1, "点完仍在聊天页")
        XCTAssertFalse(until(2) { [self] in anchor("RGOPEN") != nil }, "[product] D1：点聊天页穿透到了下层列表，打开了列表里的对话")
        XCTAssertNotNil(anchor("RGTAIL"), "[product] D1：聊天页内容被换掉了")
    }

    /// D2 停列表页点屏幕底部（聊天页输入条所在位置）：输入条随聊天页一起关交互，不弹键盘
    func testD2InputBarAreaOnListDoesNotFocus() {
        launch(["--ui-regression-seed"])
        waitFor(field, "输入框")
        expectPage(1, "启动落在聊天页")
        let fieldPoint = CGPoint(x: field.frame.midX, y: field.frame.midY)
        swipeToPrev()
        expectPage(0, "翻到列表")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: fieldPoint.x, dy: fieldPoint.y)).tap()
        XCTAssertFalse(until(2) { [self] in keyboard.exists && keyboard.frame.height > 100 }, "[product] D2：停在列表页点底部弹出了聊天输入框的键盘")
        XCTAssertNotEqual(launchState()["inputFocused"], "1", "[product] D2：聊天输入框拿到了焦点")
        expectPage(0, "仍在列表页")
    }

    /// 宿主尺寸变化（E1）：按 q 就近——从聊天页往右拖过半 → 落列表页
    func testI1SizeChangeMidDragGoesNearest() {
        launchSeeded(interrupt: "size@0.6@1")
        run("I1", reason: "size", fromX: 0.10, toX: 0.85, expect: 0, why: "尺寸变化：过半完成到目标页")
    }

    /// 禁滑（E3，贴纸编辑 / page2 拖动锁）：回源页
    func testI2ScrollDisabledMidDragReturnsToSource() {
        launchSeeded(interrupt: "scrollDisabled@0.6@1")
        run("I2", reason: "scrollDisabled", fromX: 0.10, toX: 0.85, expect: 1, why: "禁滑：回源页")
    }

    /// 进后台（E3）：回源页
    func testI3BackgroundMidDragReturnsToSource() {
        launchSeeded(interrupt: "background@0.6@1")
        run("I3", reason: "background", fromX: 0.10, toX: 0.85, expect: 1, why: "进后台：回源页")
    }

    /// 减弱动态 / VoiceOver 切换（E3）：就近页
    func testI4MotionPreferenceMidDragGoesNearest() {
        launchSeeded(interrupt: "a11y@0.6@1")
        run("I4", reason: "a11y", fromX: 0.10, toX: 0.85, expect: 0, why: "动效偏好切换：就近页")
    }

    /// 拖动中进宽屏（R2-01）：同一次更新里先禁滑（回源页）再归 page1——旧的延迟钉位不能把它拉回源页
    func testI6WideWhileDraggingFromList() {
        launchSeeded(interrupt: "wide@0.2@0")
        swipeToPrev()
        expectPage(0, "先翻到列表")
        run("I6", reason: "size", fromX: 0.80, toX: 0.45, expect: 1, why: "拖动中进宽屏：归聊天页")
        Thread.sleep(forTimeInterval: 1)
        expectPage(1, "1 秒后仍在聊天页（旧钉位没回拉）")
    }

    func testI7WideWhileDraggingFromPage2() {
        launchSeeded(interrupt: "wide@0.2@2")
        swipeToNext()
        expectPage(2, "先翻到 page2")
        run("I7", reason: "size", fromX: 0.20, toX: 0.55, expect: 1, why: "拖动中进宽屏：归聊天页")
        Thread.sleep(forTimeInterval: 1)
        expectPage(1, "1 秒后仍在聊天页（旧钉位没回拉）")
    }

    /// 程序化命令打断手势（E3）：完成到命令目标页——在列表页小拖（就近仍是列表），命令把它带到聊天页
    func testI5CommandMidDragCompletesToTarget() {
        launchSeeded(interrupt: "command@0.2@0")
        swipeToPrev()
        expectPage(0, "先翻到列表")
        run("I5", reason: "command", fromX: 0.80, toX: 0.45, expect: 1, why: "命令打断：完成到命令目标页")
    }
}
