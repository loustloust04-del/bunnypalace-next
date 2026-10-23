import XCTest

/// F1 / F2 分页壳结构计数（plan-paging-decouple §4.2 C-2）：翻页窗口内分页壳主动发出的入口
/// （updatePages、页 rootView 赋值、page2 隐藏应用 rootView 赋值、页容器 UIView 几何 setter）必须为 0。
/// 读 paging-scroll 的 a11y value 里 flipWindows / flipViolations / flipViolationEntrance（PagingFlip.axFields）。
/// 只比「结构事件有没有发生」，不比次数和真机是否相等（R1 s23）。
@MainActor
final class RegressionPagingStructureUITests: RegressionTestCase {
    private func launchSeeded(env: [String: String] = [:]) {
        launch(["--ui-regression-seed"], env: env)
        waitFor(field, "输入框")
        expectPage(1, "启动落在聊天页")
        if !until(15, { [self] in anchor("RGTAIL") != nil }) {
            snap("setup-no-tail"); XCTFail("[setup] 回归种子对话没打开")
        }
    }

    private struct Flip { var windows: Int; var violations: Int; var entrance: String }

    private func flip() -> Flip? {
        let s = launchState()
        guard let w = s["flipWindows"].flatMap(Int.init), let v = s["flipViolations"].flatMap(Int.init) else { return nil }
        return Flip(windows: w, violations: v, entrance: s["flipViolationEntrance"] ?? "")
    }

    /// 等第 n 个窗口开过、并且所有已开的窗口都收完（落定后第 2 帧才收，收尾段的入口也要算进去，R2-06）
    @discardableResult
    private func waitWindows(atLeast n: Int, _ why: String) -> Flip? {
        let closedAll: () -> Bool = { [self] in
            let s = launchState()
            guard let w = s["flipWindows"].flatMap(Int.init), let c = s["flipClosed"].flatMap(Int.init) else { return false }
            return w >= n && c == w
        }
        if !until(5, closedAll) { XCTFail("[product] \(why)：翻页窗口没收完（\(launchState())，期望开过 ≥ \(n) 个且全部关闭）") }
        return flip()
    }

    private func button(_ names: [String]) -> XCUIElement {
        let p = NSPredicate(format: "identifier IN %@ OR label IN %@", names, names)
        return app.buttons.matching(p).allElementsBoundByIndex.first { $0.isHittable } ?? app.buttons.matching(p).firstMatch
    }

    private func row(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    func testF1FlipEntrancesZero() {
        // 顺带自证 C-4：打开 #032 哨兵，每个翻页窗口都要交一条 paging 记录（落盘内容由 host 侧读模拟器容器核）
        launchSeeded(env: ["MP_STALL_SENTINEL": "1"])
        guard let start = flip() else { return XCTFail("[setup] F1：paging-scroll 没有 flipWindows / flipViolations 字段") }
        var expected = start.windows
        // 手指：0↔1、1↔2 各 3 个来回
        for round in 1...3 {
            for (name, action, page) in [("1→0", { self.swipeToPrev() }, 0), ("0→1", { self.swipeToNext() }, 1),
                                         ("1→2", { self.swipeToNext() }, 2), ("2→1", { self.swipeToPrev() }, 1)] as [(String, () -> Void, Int)] {
                action()
                expectPage(page, "第 \(round) 轮 \(name)")
                expected += 1
                waitWindows(atLeast: expected, "第 \(round) 轮 \(name)")
            }
        }
        // 程序化：顶栏箭头 → 列表、点对话 → 聊天、顶栏箭头 → page2（各 3 次）
        let titles = ["[RG] 打开对话目标", "[RG] 键盘"]
        for round in 1...3 {
            let back = button(["chevron.left", "Back", "返回"])
            guard back.exists else { snap("F1-no-back"); return XCTFail("[setup] F1：聊天页顶栏找不到左箭头") }
            back.tap()
            expectPage(0, "第 \(round) 轮 箭头→列表")
            expected += 1
            waitWindows(atLeast: expected, "第 \(round) 轮 箭头→列表")
            let target = row(titles[(round - 1) % 2])
            waitFor(target, "列表里的 \(titles[(round - 1) % 2])")
            target.tap()
            expectPage(1, "第 \(round) 轮 点对话→聊天")
            expected += 1
            waitWindows(atLeast: expected, "第 \(round) 轮 点对话→聊天")
            let forward = button(["chevron.right", "Forward", "前进"])
            guard forward.exists else { snap("F1-no-forward"); return XCTFail("[setup] F1：聊天页顶栏找不到右箭头") }
            forward.tap()
            expectPage(2, "第 \(round) 轮 箭头→page2")
            expected += 1
            waitWindows(atLeast: expected, "第 \(round) 轮 箭头→page2")
            swipeToPrev()
            expectPage(1, "第 \(round) 轮 2→1")
            expected += 1
            waitWindows(atLeast: expected, "第 \(round) 轮 2→1")
        }
        // 最后一个窗口收完（记录已交）之后再读计数断言
        waitWindows(atLeast: expected, "收尾")
        XCTAssertTrue(until(5) { [self] in launchState()["sentinelPaging"] == launchState()["flipClosed"] },
                      "[product] F1：哨兵 paging 记录数和已关窗口数对不上：\(launchState())")
        guard let end = flip() else { return XCTFail("[setup] F1：读不到计数") }
        record("F1-flip", ["windowsStart": start.windows, "windowsEnd": end.windows, "violationsStart": start.violations,
                           "violationsEnd": end.violations, "entrance": end.entrance, "AUT": launchState()])
        XCTAssertEqual(end.violations, start.violations,
                       "[product] F1：翻页窗口里分页壳发了入口调用（第一处 \(end.entrance)），翻页又牵动页面了")
    }

    /// page2 隐藏宿主（B-6）：开着一个应用（桌面 home 宿主此时不可见）来回翻 2↔1，隐藏宿主在翻页窗口里不该被重交 rootView
    func testF3HiddenPage2HostNotReassigned() {
        launch(["-page2HomePresentation_v1", "free", "-settings.proMode", "NO", "page2-ui-test"],
               env: ["PAGE2_UI_LAYOUT_CASE": UUID().uuidString])
        waitFor(app.otherElements["page2.free-home"], "page2 桌面")
        expectPage(2, "page2-ui-test 起在 page2")
        let screen = app.frame
        guard let calendar = app.buttons.matching(identifier: "page2.app.calendar").allElementsBoundByIndex
            .first(where: { $0.frame.width >= 40 && screen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }) else {
            snap("F3-no-app"); return XCTFail("[setup] F3：桌面上找不到日历图标")
        }
        calendar.tap()
        XCTAssertTrue(until(8) { [self] in !app.otherElements["page2.free-home"].isHittable }, "[setup] F3：日历没打开（桌面还在前台）")
        guard let start = launchState()["flipHiddenAssigns"].flatMap(Int.init), let w0 = flip()?.windows else {
            return XCTFail("[setup] F3：paging-scroll 没有 flipHiddenAssigns 字段")
        }
        var expected = w0
        for round in 1...3 {
            swipe(fromX: 0.08, toX: 0.85, y: 0.5)
            expectPage(1, "第 \(round) 轮 2→1")
            expected += 1
            waitWindows(atLeast: expected, "第 \(round) 轮 2→1")
            let forward = button(["chevron.right", "Forward", "前进"])
            guard forward.exists else { snap("F3-no-forward"); return XCTFail("[setup] F3：聊天页顶栏找不到右箭头") }
            forward.tap()
            expectPage(2, "第 \(round) 轮 箭头→page2")
            expected += 1
            waitWindows(atLeast: expected, "第 \(round) 轮 箭头→page2")
        }
        waitWindows(atLeast: expected, "收尾")
        let end = launchState()["flipHiddenAssigns"].flatMap(Int.init) ?? -1
        record("F3-hidden", ["start": start, "end": end, "AUT": launchState()])
        XCTAssertEqual(end, start, "[product] F3：翻页窗口里 page2 隐藏宿主被重交了 rootView（\(end - start) 次）")
    }

    /// 反例自证：开关全关（原 binding 链 + 原停靠几何）时同样的翻页必须计到违规——否则计数本身是瞎的
    func testF2CounterexampleWithSwitchesOff() {
        launchSeeded(env: ["MP_PAGING_PAGESYNC": "0", "MP_PAGING_DECK": "0"])
        guard let start = flip() else { return XCTFail("[setup] F2：paging-scroll 没有 flipWindows / flipViolations 字段") }
        var expected = start.windows
        for (name, action, page) in [("1→0", { self.swipeToPrev() }, 0), ("0→1", { self.swipeToNext() }, 1),
                                     ("1→2", { self.swipeToNext() }, 2), ("2→1", { self.swipeToPrev() }, 1)] as [(String, () -> Void, Int)] {
            action()
            expectPage(page, name)
            expected += 1
            waitWindows(atLeast: expected, name)
        }
        guard let end = flip() else { return XCTFail("[setup] F2：读不到计数") }
        record("F2-flip", ["violationsStart": start.violations, "violationsEnd": end.violations, "entrance": end.entrance])
        XCTAssertGreaterThan(end.violations, start.violations, "[product] F2：开关全关时翻页没计到任何入口违规，结构计数失灵")
    }
}
